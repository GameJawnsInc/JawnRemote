import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A tiny stand-in for the PC server: speaks the newline-delimited JSON
/// protocol on a loopback port and lets each test script the replies.
class FakePc {
  FakePc._(this._server);

  final ServerSocket _server;
  final List<Socket> sockets = [];
  final List<Map<String, dynamic>> received = [];
  int connections = 0;

  /// Called for every frame from the phone; return a reply (or null).
  Map<String, dynamic>? Function(Map<String, dynamic> msg, Socket s)? onMsg;

  int get port => _server.port;

  static Future<FakePc> start() async {
    final pc = FakePc._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    pc._server.listen(pc._accept);
    return pc;
  }

  void _accept(Socket s) {
    connections++;
    sockets.add(s);
    final buf = StringBuffer();
    s.listen((data) {
      buf.write(utf8.decode(data));
      while (true) {
        final all = buf.toString();
        final i = all.indexOf('\n');
        if (i < 0) break;
        buf
          ..clear()
          ..write(all.substring(i + 1));
        final msg = jsonDecode(all.substring(0, i)) as Map<String, dynamic>;
        received.add(msg);
        final reply = onMsg?.call(msg, s);
        if (reply != null) send(s, reply);
      }
    }, onError: (_) {}, onDone: () => s.destroy());
  }

  void send(Socket s, Map<String, dynamic> m) {
    try {
      s.add(utf8.encode('${jsonEncode(m)}\n'));
    } catch (_) {}
  }

  int count(String t) => received.where((m) => m['t'] == t).length;

  Future<void> close() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

/// Polls [cond] until it holds or [timeout] passes; returns whether it held.
Future<bool> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future.delayed(const Duration(milliseconds: 20));
  }
  return true;
}
