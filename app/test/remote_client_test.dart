import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/services/remote_client.dart';

import 'support/fake_pc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePc pc;
  late RemoteClient client;

  setUp(() async {
    pc = await FakePc.start();
    client = RemoteClient();
  });

  tearDown(() async {
    client.dispose();
    await pc.close();
  });

  Map<String, dynamic>? welcomeOk(Map<String, dynamic> m, Socket s) =>
      m['t'] == 'hello' ? {'t': 'welcome', 'ok': true, 'server': 'PC'} : null;

  test('rejected PIN stays authFailed (socket close does not clobber it)',
      () async {
    pc.onMsg = (m, s) {
      if (m['t'] != 'hello') return null;
      pc.send(s, {'t': 'welcome', 'ok': false, 'err': 'locked'});
      s.destroy(); // the server hangs up too
      return null;
    };
    await client.connect('127.0.0.1', pc.port, '1234');
    expect(await waitFor(() => client.state == ConnState.authFailed), isTrue);
    await Future.delayed(const Duration(milliseconds: 800));
    expect(client.state, ConnState.authFailed);
    expect(client.authError, 'locked');
    expect(client.pin, '1234');
    expect(pc.connections, 1, reason: 'no auto-reconnect after a rejection');

    // A fresh connect() clears the rejection.
    pc.onMsg = welcomeOk;
    await client.connect('127.0.0.1', pc.port, '5678');
    expect(await waitFor(() => client.isConnected), isTrue);
    expect(client.authError, '');
    expect(client.pin, '5678');
    expect(client.everConnected, isTrue);
  });

  test('fetchClipboard returns text, empty text, and coalesces', () async {
    var clip = 'hello from the PC';
    pc.onMsg = (m, s) {
      if (m['t'] == 'clipget') return {'t': 'clip', 's': clip};
      return welcomeOk(m, s);
    };
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.isConnected), isTrue);

    final a = client.fetchClipboard();
    final b = client.fetchClipboard();
    expect(await a, 'hello from the PC');
    expect(await b, 'hello from the PC');
    expect(pc.count('clipget'), 1);
    expect(client.pcClipboard, 'hello from the PC');

    clip = '';
    expect(await client.fetchClipboard(), '');
  });

  test('no reply: fetchClipboard -> null, padConnect -> padNoReply',
      () async {
    pc.onMsg = welcomeOk; // ignores clipget / padconnect (old server)
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.isConnected), isTrue);
    final clip = client.fetchClipboard();
    final pad = client.padConnect();
    expect(client.padNoReply, isFalse);
    expect(await clip, isNull);
    expect(await pad, isFalse);
    expect(client.padNoReply, isTrue);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('padstatus clears padNoReply', () async {
    pc.onMsg = (m, s) {
      if (m['t'] == 'padconnect') {
        return {'t': 'padstatus', 'ok': false, 'err': 'ViGEmBus missing'};
      }
      return welcomeOk(m, s);
    };
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.isConnected), isTrue);
    client.padNoReply = true;
    expect(await client.padConnect(), isFalse);
    expect(client.padNoReply, isFalse);
    expect(client.padError, 'ViGEmBus missing');
  });

  test('invalid port is an error, not an endless retry', () async {
    await client.connect('127.0.0.1', 70000, '');
    expect(client.state, ConnState.error);
    expect(client.lastError, 'Invalid port.');
    await Future.delayed(const Duration(milliseconds: 400));
    expect(client.state, ConnState.error);
  });

  test('"ip:port" typed as the host is an error', () async {
    await client.connect('192.168.1.20:8770', 8770, '');
    expect(client.state, ConnState.error);
    expect(client.lastError, contains('address'));
  });

  test('refused first connect keeps retrying and reports struggling',
      () async {
    final port = pc.port;
    await pc.close(); // nothing listens there any more
    await client.connect('127.0.0.1', port, '');
    expect(client.struggling, isFalse);
    expect(await waitFor(() => client.struggling), isTrue);
    expect(client.state, ConnState.connecting);
    expect(client.lastError, contains('refused'));
    expect(client.everConnected, isFalse);
    client.disconnect();
    expect(client.struggling, isFalse);
    pc = await FakePc.start(); // for tearDown
  });

  test('a connect that finishes after disconnect() is dropped', () async {
    pc.onMsg = welcomeOk;
    final pending = client.connect('127.0.0.1', pc.port, '');
    client.disconnect();
    await pending;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(client.state, ConnState.disconnected);
    expect(pc.count('hello'), 0);
  });

  test('a superseded attempt does not replace the newer one', () async {
    final other = await FakePc.start();
    other.onMsg = welcomeOk;
    pc.onMsg = welcomeOk;
    final first = client.connect('127.0.0.1', other.port, '');
    final second = client.connect('127.0.0.1', pc.port, '');
    await Future.wait([first, second]);
    expect(await waitFor(() => client.isConnected), isTrue);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(other.count('hello'), 0, reason: 'stale attempt must not say hello');
    expect(pc.count('hello'), 1);
    expect(client.isConnected, isTrue);
    await other.close();
  });

  test('server that never answers the hello is explained', () async {
    await client.connect('127.0.0.1', pc.port, ''); // no onMsg -> no welcome
    expect(
        await waitFor(() => client.lastError.contains("didn't answer"),
            timeout: const Duration(seconds: 10)),
        isTrue);
    expect(client.state, ConnState.connecting);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('something that hangs up on the hello is explained', () async {
    pc.onMsg = (m, s) {
      s.destroy();
      return null;
    };
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.struggling), isTrue);
    expect(client.lastError, contains('closed the connection'));
  });

  test('dropped link after a session reconnects', () async {
    pc.onMsg = welcomeOk;
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.isConnected), isTrue);
    pc.sockets.first.destroy();
    expect(await waitFor(() => client.isReconnecting), isTrue);
    expect(await waitFor(() => client.isConnected), isTrue);
    expect(pc.connections, 2);
    expect(client.struggling, isFalse);
  });
}
