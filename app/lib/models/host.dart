/// A saved or discovered PC running the JawnRemote server.
class RemoteHost {
  final String name;
  final String ip;
  final int port;
  final String pin;

  /// The PC's LAN MAC, learned from the server on connect. Used for Wake-on-LAN
  /// (sending a magic packet to power the PC on while the server is off).
  final String mac;

  /// True when the user explicitly named this PC — connecting then won't
  /// overwrite it with the server's hostname.
  final bool customName;

  const RemoteHost({
    required this.name,
    required this.ip,
    this.port = 8770,
    this.pin = '',
    this.mac = '',
    this.customName = false,
  });

  String get key => '$ip:$port';

  RemoteHost copyWith({
    String? name,
    String? ip,
    int? port,
    String? pin,
    String? mac,
    bool? customName,
  }) =>
      RemoteHost(
        name: name ?? this.name,
        ip: ip ?? this.ip,
        port: port ?? this.port,
        pin: pin ?? this.pin,
        mac: mac ?? this.mac,
        customName: customName ?? this.customName,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'ip': ip,
        'port': port,
        'pin': pin,
        'mac': mac,
        'customName': customName,
      };

  factory RemoteHost.fromJson(Map<String, dynamic> j) => RemoteHost(
        name: (j['name'] ?? j['ip'] ?? '').toString(),
        ip: (j['ip'] ?? '').toString(),
        port: (j['port'] is int) ? j['port'] as int : 8770,
        pin: (j['pin'] ?? '').toString(),
        mac: (j['mac'] ?? '').toString(),
        customName: j['customName'] == true,
      );
}
