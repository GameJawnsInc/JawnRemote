import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

enum ConnState { disconnected, connecting, connected, authFailed, error }

/// TCP client speaking the newline-delimited JSON protocol to the PC server.
/// Auto-reconnects with backoff while [_wantConnected] is true.
class RemoteClient extends ChangeNotifier {
  Socket? _sock;
  ConnState state = ConnState.disconnected;
  String serverName = '';
  String lastError = '';

  String _host = '';
  int _port = 8770;
  String _pin = '';
  String deviceName = 'Phone';

  bool _wantConnected = false;
  int _retry = 0;
  Timer? _reconnectTimer;
  final StringBuffer _buf = StringBuffer();

  bool get isConnected => state == ConnState.connected;

  Future<void> connect(String host, int port, String pin) async {
    _host = host;
    _port = port;
    _pin = pin;
    _wantConnected = true;
    _retry = 0;
    await _open();
  }

  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _setState(ConnState.disconnected);
  }

  Future<void> _open() async {
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _setState(ConnState.connecting);
    try {
      final s = await Socket.connect(_host, _port,
          timeout: const Duration(seconds: 6));
      s.setOption(SocketOption.tcpNoDelay, true);
      _sock = s;
      _buf.clear();
      s.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
      _sendRaw({'t': 'hello', 'pin': _pin, 'name': deviceName});
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
          _retry = 0;
          _setState(ConnState.connected);
        } else {
          _wantConnected = false;
          _setState(ConnState.authFailed);
          _cleanupSocket();
        }
        break;
    }
  }

  void _onError(Object e) {
    lastError = _friendly(e);
    _cleanupSocket();
    if (_wantConnected && state != ConnState.authFailed) {
      _scheduleReconnect();
    } else {
      _setState(ConnState.error);
    }
  }

  void _onDone() {
    _cleanupSocket();
    if (_wantConnected && state != ConnState.authFailed) {
      _scheduleReconnect();
    } else {
      _setState(ConnState.disconnected);
    }
  }

  void _scheduleReconnect() {
    _setState(ConnState.connecting);
    _retry = (_retry + 1).clamp(1, 6);
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(Duration(milliseconds: 400 * _retry), () {
      if (_wantConnected) _open();
    });
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
    if (s.contains('refused')) return 'Connection refused — is the server running?';
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
  void ping() => _sendRaw({'t': 'ping'});

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
