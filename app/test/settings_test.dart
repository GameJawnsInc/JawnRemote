import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/models/host.dart';
import 'package:jawnremote/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const a = RemoteHost(name: 'Desk', ip: '10.0.0.5', pin: '1111');
  const b = RemoteHost(
      name: 'DESKTOP-X', ip: '10.0.0.9', pin: '2222', mac: 'AA:BB:CC:DD:EE:FF');
  const c = RemoteHost(name: 'Laptop', ip: '10.0.0.7');

  Future<Settings> load(List<RemoteHost> hosts) async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    await s.load();
    for (final h in hosts.reversed) {
      await s.upsertHost(h); // new hosts go on top
    }
    return s;
  }

  test('replaceHost onto another saved PC merges instead of duplicating',
      () async {
    final s = await load([a, b, c]);
    // The user fixes Desk's IP to the one the rediscovered PC was saved at.
    await s.replaceHost(a.key, a.copyWith(ip: b.ip));
    expect(s.hosts.map((h) => h.key), ['10.0.0.9:8770', '10.0.0.7:8770']);
    final merged = s.hosts.first;
    expect(merged.name, 'Desk'); // the edit wins...
    expect(merged.pin, '1111');
    expect(merged.mac, 'AA:BB:CC:DD:EE:FF'); // ...but keeps the learned MAC

    // Persisted too.
    final again = Settings();
    await again.load();
    expect(again.hosts.map((h) => h.key), ['10.0.0.9:8770', '10.0.0.7:8770']);
  });

  test('replaceHost keeps position when the key is unchanged or new',
      () async {
    final s = await load([a, b, c]);
    await s.replaceHost(b.key, b.copyWith(name: 'Office'));
    expect(s.hosts.map((h) => h.name), ['Desk', 'Office', 'Laptop']);
    await s.replaceHost(c.key, c.copyWith(port: 9000));
    expect(s.hosts.map((h) => h.key),
        ['10.0.0.5:8770', '10.0.0.9:8770', '10.0.0.7:9000']);
  });

  test('insertHost restores a removed PC in place (Undo)', () async {
    final s = await load([a, b, c]);
    final idx = s.hosts.indexWhere((h) => h.key == b.key);
    await s.removeHost(b);
    expect(s.hosts.length, 2);
    await s.insertHost(idx, b);
    expect(s.hosts.map((h) => h.name), ['Desk', 'DESKTOP-X', 'Laptop']);
    expect(s.hosts[1].mac, b.mac);

    // Already back (e.g. reconnected before Undo): no duplicate.
    await s.insertHost(0, b);
    expect(s.hosts.length, 3);

    // Out-of-range index is clamped.
    await s.removeHost(c);
    await s.insertHost(99, c);
    expect(s.hosts.last.key, c.key);
  });
}
