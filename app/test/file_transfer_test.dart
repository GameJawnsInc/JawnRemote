import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/services/file_transfer.dart';
import 'package:jawnremote/services/remote_client.dart';

import 'support/fake_pc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;
  late FakePc pc;
  late RemoteClient client;
  late FileTransfer ft;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('jawn_ft_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('jawnremote/files'),
            (call) async => call.method == 'cacheDir' ? cache.path : null);
    pc = await FakePc.start();
    client = RemoteClient();
  });

  tearDown(() async {
    ft.dispose();
    client.dispose();
    await pc.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('jawnremote/files'), null);
    await cache.delete(recursive: true);
  });

  Future<void> connect() async {
    await client.connect('127.0.0.1', pc.port, '');
    expect(await waitFor(() => client.isConnected), isTrue);
  }

  Future<File> makeFile(String name, int size) async {
    final f = File('${cache.path}/$name');
    final rnd = Random(1);
    await f.writeAsBytes(List.generate(size, (_) => rnd.nextInt(256)));
    return f;
  }

  Map<String, dynamic>? welcomeOk(Map<String, dynamic> m) =>
      m['t'] == 'hello' ? {'t': 'welcome', 'ok': true} : null;

  test('startup sweep removes only our own stale cache files', () async {
    final old = DateTime.now().subtract(const Duration(days: 2));
    final stalePick = await makeFile('pick_1_old.bin', 10);
    final staleRx = await makeFile('jawn_1_old.bin', 10);
    final other = await makeFile('someone_elses.bin', 10);
    final freshPick = await makeFile('pick_2_new.bin', 10);
    for (final f in [stalePick, staleRx, other]) {
      await f.setLastModified(old);
    }
    ft = FileTransfer(client);
    expect(await waitFor(() => !stalePick.existsSync() && !staleRx.existsSync()),
        isTrue);
    expect(other.existsSync(), isTrue);
    expect(freshPick.existsSync(), isTrue);
  });

  test('upload works and deletes its pick_ copy', () async {
    pc.onMsg = (m, s) {
      switch (m['t']) {
        case 'filebeg':
          return {'t': 'fileack', 'id': m['id'], 'i': -1};
        case 'filedat':
          return {'t': 'fileack', 'id': m['id'], 'i': m['i']};
        case 'fileend':
          return {'t': 'filedone', 'id': m['id'], 'ok': true};
      }
      return welcomeOk(m);
    };
    ft = FileTransfer(client);
    await connect();
    final f = await makeFile('pick_3_photo.jpg', 300 * 1024);
    await ft.sendFile(f.path, 'photo.jpg');
    expect(ft.txState, TxState.done, reason: ft.txError);
    expect(ft.canCancel, isFalse);
    expect(f.existsSync(), isFalse);
    expect(pc.count('filedat'), 5);
  });

  test('PC rejecting mid-upload fails fast with its reason', () async {
    pc.onMsg = (m, s) {
      switch (m['t']) {
        case 'filebeg':
          return {'t': 'fileack', 'id': m['id'], 'i': -1};
        case 'filedat': // never acks; refuses on the first chunk
          return m['i'] == 0
              ? {'t': 'filedone', 'id': m['id'], 'ok': false,
                  'err': "The PC's disk is full"}
              : null;
      }
      return welcomeOk(m);
    };
    ft = FileTransfer(client);
    await connect();
    final f = await makeFile('video.mp4', 2 * 1024 * 1024); // 32 chunks
    final sw = Stopwatch()..start();
    await ft.sendFile(f.path, 'video.mp4');
    expect(ft.txState, TxState.error);
    expect(ft.txError, contains("disk is full"));
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(f.existsSync(), isTrue, reason: 'not a pick_ copy: left alone');
  });

  test('link loss mid-upload fails fast', () async {
    pc.onMsg = (m, s) {
      if (m['t'] == 'filebeg') {
        s.destroy(); // Wi-Fi drops
        return null;
      }
      return welcomeOk(m);
    };
    ft = FileTransfer(client);
    await connect();
    final f = await makeFile('pick_4_big.bin', 2 * 1024 * 1024);
    final sw = Stopwatch()..start();
    await ft.sendFile(f.path, 'big.bin');
    expect(ft.txState, TxState.error);
    expect(ft.txError, 'Connection lost — try again.');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(f.existsSync(), isFalse);
  });

  test('cancel while waiting for the link cancels the upload', () async {
    ft = FileTransfer(client); // never connected
    final f = await makeFile('pick_5_doc.pdf', 1000);
    final send = ft.sendFile(f.path, 'doc.pdf');
    await Future.delayed(const Duration(milliseconds: 300));
    expect(ft.isSending, isTrue);
    expect(ft.canCancel, isTrue);
    ft.cancelOutgoing();
    await send;
    expect(ft.txError, 'Canceled.');
    expect(pc.count('filebeg'), 0);
    expect(f.existsSync(), isFalse);
  });

  test('an empty file still honors cancel and link loss', () async {
    pc.onMsg = (m, s) => m['t'] == 'fileend'
        ? {'t': 'filedone', 'id': m['id'], 'ok': true}
        : welcomeOk(m);
    ft = FileTransfer(client);
    await connect();
    final f = await makeFile('empty.txt', 0);

    final canceled = ft.sendFile(f.path, 'empty.txt');
    ft.cancelOutgoing(); // Cancel was offered, so it must win
    await canceled;
    expect(ft.txError, 'Canceled.');
    expect(pc.count('fileend'), 0);

    final sw = Stopwatch()..start();
    final dropped = ft.sendFile(f.path, 'empty.txt');
    client.disconnect(); // the link goes before any chunk check runs
    await dropped;
    expect(ft.txError, 'Connection lost — try again.');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('files over 2 GB are refused up front', () async {
    pc.onMsg = (m, s) => welcomeOk(m);
    ft = FileTransfer(client);
    await connect();
    final f = File('${cache.path}/huge.bin');
    final raf = await f.open(mode: FileMode.write);
    await raf.truncate(2 * 1024 * 1024 * 1024 + 1); // sparse
    await raf.close();
    await ft.sendFile(f.path, 'huge.bin');
    expect(ft.txState, TxState.error);
    expect(ft.txError, "Files over 2 GB can't be sent.");
    expect(pc.count('filebeg'), 0);
  });

  test('a push cut off by a link drop resets and deletes the partial',
      () async {
    pc.onMsg = (m, s) {
      if (m['t'] == 'hello') {
        pc.send(s, {'t': 'welcome', 'ok': true});
        if (pc.connections == 1) {
          pc.send(s, {'t': 'filebeg', 'id': 'x1', 'name': 'a.txt', 'size': 10});
          pc.send(s, {'t': 'filedat', 'id': 'x1', 'i': 0, 'b': 'aGVsbG8='});
        }
      }
      if (m['t'] == 'fileack') s.destroy(); // drop mid-push
      return null;
    };
    ft = FileTransfer(client);
    var sawReceiving = false;
    ft.addListener(() => sawReceiving |= ft.isReceiving);
    await connect();
    expect(await waitFor(() => sawReceiving && !ft.isReceiving), isTrue);
    expect(ft.rxName, '');
    expect(ft.received, isEmpty);
    expect(
        await waitFor(() => !cache
            .listSync()
            .any((e) => e.path.split('/').last.startsWith('jawn_'))),
        isTrue);
  });

  test('a corrupt chunk ends the receive', () async {
    pc.onMsg = (m, s) {
      if (m['t'] == 'hello') {
        pc.send(s, {'t': 'welcome', 'ok': true});
        pc.send(s, {'t': 'filebeg', 'id': 'x2', 'name': 'b.txt', 'size': 10});
        pc.send(s, {'t': 'filedat', 'id': 'x2', 'i': 0, 'b': '!!not base64'});
      }
      return null;
    };
    ft = FileTransfer(client);
    await connect();
    expect(await waitFor(() => pc.count('filedone') == 1), isTrue);
    expect(await waitFor(() => !ft.isReceiving), isTrue);
    expect(pc.received.last['ok'], isFalse);
  });
}
