import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredServer {
  final String name;
  final String ip;
  final int port;
  DiscoveredServer(this.name, this.ip, this.port);
  String get key => '$ip:$port';
}

/// Broadcasts UDP discovery probes and collects server replies.
/// (Needs a UDP firewall rule on the PC; manual IP entry is the fallback.)
class Discovery {
  RawDatagramSocket? _sock;
  Timer? _timer;
  final _controller = StreamController<DiscoveredServer>.broadcast();
  Stream<DiscoveredServer> get stream => _controller.stream;

  Future<void> start({int port = 8770}) async {
    await stop();
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sock!.broadcastEnabled = true;
      _sock!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _sock!.receive();
        if (dg == null) return;
        try {
          final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (msg['t'] == 'server') {
            _controller.add(DiscoveredServer(
              (msg['name'] ?? dg.address.address).toString(),
              dg.address.address,
              (msg['port'] is int) ? msg['port'] as int : port,
            ));
          }
        } catch (_) {}
      });
      _probe(port);
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _probe(port));
    } catch (_) {
      // discovery is best-effort
    }
  }

  void _probe(int port) {
    final data = utf8.encode(jsonEncode({'t': 'discover', 'app': 'JawnRemote'}));
    try {
      _sock?.send(data, InternetAddress('255.255.255.255'), port);
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _sock?.close();
    _sock = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
