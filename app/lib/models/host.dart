/// A saved or discovered PC running the JawnRemote server.
class RemoteHost {
  final String name;
  final String ip;
  final int port;
  final String pin;

  const RemoteHost({
    required this.name,
    required this.ip,
    this.port = 8770,
    this.pin = '',
  });

  String get key => '$ip:$port';

  RemoteHost copyWith({String? name, String? ip, int? port, String? pin}) =>
      RemoteHost(
        name: name ?? this.name,
        ip: ip ?? this.ip,
        port: port ?? this.port,
        pin: pin ?? this.pin,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'ip': ip, 'port': port, 'pin': pin};

  factory RemoteHost.fromJson(Map<String, dynamic> j) => RemoteHost(
        name: (j['name'] ?? j['ip'] ?? '').toString(),
        ip: (j['ip'] ?? '').toString(),
        port: (j['port'] is int) ? j['port'] as int : 8770,
        pin: (j['pin'] ?? '').toString(),
      );
}
