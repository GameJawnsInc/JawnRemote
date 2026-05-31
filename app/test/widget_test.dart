import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/models/host.dart';

void main() {
  test('RemoteHost JSON round-trips', () {
    const h = RemoteHost(
        name: 'JawnPC', ip: '10.0.0.210', port: 8770, pin: '1234');
    final restored = RemoteHost.fromJson(h.toJson());
    expect(restored.name, 'JawnPC');
    expect(restored.ip, '10.0.0.210');
    expect(restored.port, 8770);
    expect(restored.pin, '1234');
    expect(restored.key, '10.0.0.210:8770');
  });

  test('RemoteHost.fromJson tolerates missing fields', () {
    final h = RemoteHost.fromJson({'ip': '192.168.1.5'});
    expect(h.ip, '192.168.1.5');
    expect(h.port, 8770);
    expect(h.pin, '');
  });
}
