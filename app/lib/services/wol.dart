import 'dart:io';

/// Wake-on-LAN: send a "magic packet" to power on a PC whose NIC is listening
/// (WoL enabled in BIOS/driver). The packet is 6 bytes of 0xFF followed by the
/// target MAC repeated 16 times, broadcast over UDP. No server needed — the
/// network card wakes the machine in hardware.
Future<bool> sendMagicPacket(String mac, {String? ip}) async {
  final bytes = _parseMac(mac);
  if (bytes == null) return false;

  final packet = <int>[
    ...List<int>.filled(6, 0xFF),
    for (var i = 0; i < 16; i++) ...bytes,
  ];

  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    // Global broadcast + the host's /24 subnet broadcast (more routers/NICs
    // honor the directed one). Common WoL ports are 9 and 7.
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    final directed = _subnetBroadcast(ip);
    if (directed != null) targets.add(InternetAddress(directed));

    for (final addr in targets) {
      for (final port in const [9, 7]) {
        sock.send(packet, addr, port);
      }
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    sock?.close();
  }
}

/// Parses "AA:BB:CC:DD:EE:FF" / "AA-BB-..." / "aabbccddeeff" into 6 bytes.
List<int>? _parseMac(String mac) {
  final hex = mac.replaceAll(RegExp(r'[:\-\.\s]'), '');
  if (hex.length != 12) return null;
  final out = <int>[];
  for (var i = 0; i < 12; i += 2) {
    final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

/// Derives the /24 broadcast address from an IPv4 (e.g. 192.168.1.50 -> .255).
String? _subnetBroadcast(String? ip) {
  if (ip == null) return null;
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  if (parts.any((p) => int.tryParse(p) == null)) return null;
  return '${parts[0]}.${parts[1]}.${parts[2]}.255';
}
