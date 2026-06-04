import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';

enum ConnState { disconnected, connecting, connected, authFailed, error }

/// TCP client speaking the newline-delimited JSON protocol to the PC server.
///
/// Reliability ("rock-solid reconnect"): while [_wantConnected] is true it
/// auto-reconnects with a fast backoff; a ping/pong heartbeat detects silently
/// dropped ("half-open") links that never send a FIN; a handshake watchdog
/// covers a server that accepts the socket but never replies; and it reconnects
/// the moment the app returns to the foreground (where the OS often kills idle
/// sockets out from under us).
class RemoteClient extends ChangeNotifier with WidgetsBindingObserver {
  Socket? _sock;
  ConnState state = ConnState.disconnected;
  String serverName = '';
  String serverMac = '';
  String lastError = '';

  /// Quick-launch apps configured on the PC (empty for older servers, which
  /// makes the Apps screen fall back to its built-in defaults).
  List<Map<String, dynamic>> serverApps = [];

  /// Last clipboard text received from the PC (clipboard sync).
  String pcClipboard = '';

  /// Set by [FileTransfer]; receives the file-transfer frames (file*). Kept off
  /// [notifyListeners] so a chunked transfer doesn't churn the whole UI tree.
  void Function(Map<String, dynamic> msg)? onFileFrame;

  String _host = '';
  int _port = 8770;
  String _pin = '';
  String deviceName = 'Phone';

  bool _wantConnected = false;
  bool _everConnected = false;
  int _retry = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _probeTimer; // handshake watchdog / app-resume probe
  DateTime _lastInbound = DateTime.fromMillisecondsSinceEpoch(0);
  final StringBuffer _buf = StringBuffer();

  /// In-flight Quick View screenshot request (one-shot request/response).
  Completer<Uint8List>? _shotPending;

  // Reconnect backoff (ms) by attempt — the first retry is near-instant.
  static const List<int> _backoffMs = [200, 500, 1000, 2000, 3000, 5000];
  // Heartbeat: ping this often; declare the link dead after this much silence.
  static const Duration _pingEvery = Duration(seconds: 4);
  static const Duration _deadAfter = Duration(seconds: 9);

  RemoteClient() {
    WidgetsBinding.instance.addObserver(this);
  }

  bool get isConnected => state == ConnState.connected;

  /// True while re-establishing a link that was previously live — lets the UI
  /// show a "Reconnecting…" hint over the controls instead of the first-time
  /// connecting screen.
  bool get isReconnecting =>
      _everConnected && state == ConnState.connecting && _wantConnected;

  Future<void> connect(String host, int port, String pin) async {
    _host = host;
    _port = port;
    _pin = pin;
    _wantConnected = true;
    _everConnected = false;
    _retry = 0;
    await _open();
  }

  void disconnect() {
    _wantConnected = false;
    _everConnected = false;
    _reconnectTimer?.cancel();
    _stopTimers();
    _cleanupSocket();
    _setState(ConnState.disconnected);
  }

  Future<void> _open() async {
    _reconnectTimer?.cancel();
    _stopTimers();
    _cleanupSocket();
    _setState(ConnState.connecting);
    try {
      final s = await Socket.connect(_host, _port,
          timeout: const Duration(seconds: 6));
      s.setOption(SocketOption.tcpNoDelay, true);
      _sock = s;
      _buf.clear();
      _lastInbound = DateTime.now();
      s.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
      _sendRaw({'t': 'hello', 'pin': _pin, 'name': deviceName});
      // Handshake watchdog: if no "welcome" arrives, drop and retry.
      _probeTimer?.cancel();
      _probeTimer = Timer(const Duration(seconds: 7), () {
        if (state == ConnState.connecting) _onDead();
      });
    } catch (e) {
      lastError = _friendly(e);
      _cleanupSocket();
      if (_wantConnected) {
        _scheduleReconnect();
      } else {
        _setState(ConnState.error);
      }
    }
  }

  void _onData(List<int> data) {
    _lastInbound = DateTime.now(); // any byte proves the link is alive
    _buf.write(utf8.decode(data, allowMalformed: true));
    while (true) {
      final s = _buf.toString();
      final i = s.indexOf('\n');
      if (i < 0) break;
      final line = s.substring(0, i).trim();
      _buf
        ..clear()
        ..write(s.substring(i + 1));
      if (line.isEmpty) continue;
      try {
        _handle(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  void _handle(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'welcome':
        if (msg['ok'] == true) {
          serverName = (msg['server'] ?? _host).toString();
          serverMac = (msg['mac'] ?? '').toString();
          _retry = 0;
          _everConnected = true;
          _probeTimer?.cancel(); // handshake succeeded
          _setState(ConnState.connected);
          _startHeartbeat();
        } else {
          _wantConnected = false;
          _setState(ConnState.authFailed);
          _cleanupSocket();
        }
        break;
      case 'apps':
        final list = msg['apps'];
        if (list is List) {
          serverApps = list.whereType<Map<String, dynamic>>().toList();
          notifyListeners();
        }
        break;
      case 'clip':
        pcClipboard = (msg['s'] ?? '').toString();
        notifyListeners();
        break;
      case 'shot':
        final c = _shotPending;
        _shotPending = null;
        if (c != null && !c.isCompleted) {
          if (msg['err'] == true) {
            c.completeError('The PC could not capture the screen.');
          } else {
            try {
              c.complete(base64Decode((msg['img'] ?? '').toString()));
            } catch (e) {
              c.completeError(e);
            }
          }
        }
        break;
      case 'fileack':
      case 'filedone':
      case 'filebeg':
      case 'filedat':
      case 'fileend':
      case 'fileabort':
        onFileFrame?.call(msg);
        break;
    }
  }

  // ---- heartbeat ----
  void _startHeartbeat() {
    _lastInbound = DateTime.now();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_pingEvery, (_) {
      if (state != ConnState.connected) return;
      if (DateTime.now().difference(_lastInbound) > _deadAfter) {
        _onDead();
      } else {
        ping();
      }
    });
  }

  void _stopTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  /// The link went silent (half-open, or never completed the handshake). Drop
  /// it and reconnect on the fastest backoff step.
  void _onDead() {
    if (!_wantConnected) return;
    lastError = 'Connection lost — reconnecting…';
    _stopTimers();
    _cleanupSocket();
    _retry = 0;
    _scheduleReconnect();
  }

  void _onError(Object e) {
    lastError = _friendly(e);
    _stopTimers();
    _cleanupSocket();
    if (_wantConnected && state != ConnState.authFailed) {
      _scheduleReconnect();
    } else {
      _setState(ConnState.error);
    }
  }

  void _onDone() {
    _stopTimers();
    _cleanupSocket();
    if (_wantConnected && state != ConnState.authFailed) {
      _scheduleReconnect();
    } else {
      _setState(ConnState.disconnected);
    }
  }

  void _scheduleReconnect() {
    _stopTimers();
    if (_reconnectTimer?.isActive ?? false) return; // already pending
    _setState(ConnState.connecting);
    final delay = _backoffMs[_retry.clamp(0, _backoffMs.length - 1)];
    _retry = (_retry + 1).clamp(0, _backoffMs.length - 1);
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (_wantConnected) _open();
    });
  }

  // ---- app lifecycle: reconnect fast when returning to the foreground ----
  @override
  // ignore: avoid_renaming_method_parameters  (would shadow our `state` field)
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed || !_wantConnected) return;
    if (state == ConnState.connected) {
      // The socket may have died while we were backgrounded. Ping now; if
      // nothing comes back shortly, treat it as dead and reconnect.
      final pingedAt = DateTime.now();
      ping();
      _probeTimer?.cancel();
      _probeTimer = Timer(const Duration(seconds: 3), () {
        if (state == ConnState.connected && _lastInbound.isBefore(pingedAt)) {
          _onDead();
        }
      });
    } else {
      // Mid-reconnect or dropped — retry now instead of waiting out the backoff.
      _retry = 0;
      _reconnectTimer?.cancel();
      _open();
    }
  }

  void _cleanupSocket() {
    try {
      _sock?.destroy();
    } catch (_) {}
    _sock = null;
  }

  void _setState(ConnState s) {
    state = s;
    notifyListeners();
  }

  void _sendRaw(Map<String, dynamic> m) {
    final s = _sock;
    if (s == null) return;
    try {
      s.add(utf8.encode('${jsonEncode(m)}\n'));
    } catch (e) {
      _onError(e);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('refused')) {
      return 'Connection refused — is the server running?';
    }
    if (s.contains('timed out') || s.contains('timeout')) {
      return 'Timed out — check the IP and that the firewall allows port $_port.';
    }
    if (s.contains('Network is unreachable')) return 'Network unreachable.';
    return s;
  }

  // ---- input API ----
  void move(int dx, int dy) => _sendRaw({'t': 'm', 'x': dx, 'y': dy});
  void click([String b = 'left']) => _sendRaw({'t': 'click', 'b': b});
  void mouseDown([String b = 'left']) => _sendRaw({'t': 'down', 'b': b});
  void mouseUp([String b = 'left']) => _sendRaw({'t': 'up', 'b': b});
  void scroll(int dy, [int dx = 0]) => _sendRaw({'t': 'scroll', 'y': dy, 'x': dx});
  void text(String s) => _sendRaw({'t': 'text', 's': s});
  void key(String k, [List<String> mods = const []]) =>
      _sendRaw({'t': 'key', 'k': k, 'm': mods});
  void power(String action) => _sendRaw({'t': 'power', 'action': action});
  void launch(String target) => _sendRaw({'t': 'launch', 'target': target});
  void requestApps() => _sendRaw({'t': 'getapps'});
  void sendClipboard(String text) => _sendRaw({'t': 'clipset', 's': text});
  void requestClipboard() => _sendRaw({'t': 'clipget'});
  void ping() => _sendRaw({'t': 'ping'});

  /// Ask the PC for a one-off screenshot. Resolves with PNG bytes, or errors on
  /// timeout / capture failure. Nothing is stored or written to disk.
  Future<Uint8List> requestShot() {
    final prev = _shotPending;
    if (prev != null && !prev.isCompleted) return prev.future; // coalesce
    final c = Completer<Uint8List>();
    _shotPending = c;
    _sendRaw({'t': 'shot'});
    Future.delayed(const Duration(seconds: 15), () {
      if (!c.isCompleted) {
        if (identical(_shotPending, c)) _shotPending = null;
        c.completeError('Timed out waiting for the screenshot.');
      }
    });
    return c.future;
  }

  // ---- file transfer (chunked; driven by FileTransfer) ----
  void fileBegin(String id, String name, int size) =>
      _sendRaw({'t': 'filebeg', 'id': id, 'name': name, 'size': size});
  void fileData(String id, int i, String b64) =>
      _sendRaw({'t': 'filedat', 'id': id, 'i': i, 'b': b64});
  void fileEnd(String id, String sha) =>
      _sendRaw({'t': 'fileend', 'id': id, 'sha': sha});
  void fileAbort(String id) => _sendRaw({'t': 'fileabort', 'id': id});
  void fileAck(String id, int i) => _sendRaw({'t': 'fileack', 'id': id, 'i': i});
  void fileDone(String id, bool ok, {String? path, String? err}) => _sendRaw({
        't': 'filedone',
        'id': id,
        'ok': ok,
        'path': ?path,
        'err': ?err,
      });

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disconnect();
    super.dispose();
  }
}
