import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/app_scope.dart';
import 'package:jawnremote/models/host.dart';
import 'package:jawnremote/screens/connect_screen.dart';
import 'package:jawnremote/screens/presentation_screen.dart';
import 'package:jawnremote/screens/remote_screen.dart';
import 'package:jawnremote/services/discovery.dart';
import 'package:jawnremote/services/file_transfer.dart';
import 'package:jawnremote/services/remote_client.dart';
import 'package:jawnremote/services/settings.dart';
import 'package:jawnremote/widgets/keyboard_bar.dart';
import 'package:jawnremote/widgets/trackpad.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A RemoteClient that never touches the network: tests drive its state and
/// read back what the UI sent.
class FakeClient extends RemoteClient {
  final List<String> sent = [];
  final List<String> connects = [];
  int disconnects = 0;
  String fakePin = '';
  bool reconnecting = false;
  bool strugglingNow = false;

  @override
  String get pin => fakePin;
  @override
  bool get isReconnecting => reconnecting && state == ConnState.connecting;
  @override
  bool get struggling => strugglingNow && state == ConnState.connecting;

  void emit(ConnState s) {
    state = s;
    notifyListeners();
  }

  @override
  Future<void> connect(String host, int port, String pin) async {
    connects.add('$host:$port/$pin');
    fakePin = pin;
    authError = '';
    emit(ConnState.connecting);
  }

  @override
  void disconnect() {
    disconnects++;
    super.disconnect();
  }

  @override
  void key(String k, [List<String> mods = const []]) =>
      sent.add(mods.isEmpty ? 'key:$k' : 'key:${[...mods, k].join('+')}');
  @override
  void text(String s) => sent.add('text:$s');
  @override
  void click([String b = 'left']) => sent.add('click:$b');
  @override
  void scroll(int dy, [int dx = 0]) => sent.add('scroll:$dy,$dx');
  @override
  void move(int dx, int dy) {}
}

class FakeDiscovery extends Discovery {
  final _ctl = StreamController<DiscoveredServer>.broadcast();
  @override
  Stream<DiscoveredServer> get stream => _ctl.stream;
  @override
  Future<void> start({int port = 8770}) async {}
  @override
  Future<void> stop() async {}
  void add(DiscoveredServer s) => _ctl.add(s);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const volume = MethodChannel('jawnremote/volume');
  final volumeCalls = <MethodCall>[];

  late Settings settings;
  late FakeClient client;
  late FakeDiscovery discovery;
  final nav = GlobalKey<NavigatorState>();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = Settings();
    await settings.load();
    client = FakeClient();
    discovery = FakeDiscovery();
    volumeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(volume, (call) async {
      volumeCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(volume, null);
  });

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(AppScope(
      settings: settings,
      client: client,
      discovery: discovery,
      fileTransfer: FileTransfer(client),
      child: MaterialApp(navigatorKey: nav, home: home),
    ));
  }

  /// Like pumpAndSettle, but the connecting/searching spinners never settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  const desk = RemoteHost(
      name: 'Desk', ip: '10.0.0.5', pin: '1111', mac: 'AA:BB:CC:DD:EE:FF');

  /// Pushes a RemoteScreen over a blank home page (so it can be popped).
  Future<void> openRemote(WidgetTester tester,
      {RemoteHost host = desk}) async {
    await pumpApp(tester, const Scaffold(body: Text('home')));
    nav.currentState!
        .push(MaterialPageRoute(builder: (_) => RemoteScreen(host: host)));
    await settle(tester);
  }

  group('RemoteScreen', () {
    testWidgets('wrong PIN -> re-enter (keyboard submit) saves the new PIN',
        (tester) async {
      await openRemote(tester);
      expect(client.connects, ['10.0.0.5:8770/1111']);
      client.serverName = 'DESKTOP-X';
      client.emit(ConnState.connected);
      await settle(tester);
      expect(settings.hosts.single.pin, '1111');

      // The PC's PIN changed: a reconnect is refused.
      client.authError = 'bad_pin';
      client.emit(ConnState.authFailed);
      await settle(tester);
      expect(find.text('Wrong PIN'), findsOneWidget);
      await tester.tap(find.text('Re-enter PIN'));
      await settle(tester);
      final field = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      expect(tester.widget<TextField>(field).controller!.text, '1111');
      await tester.enterText(field, ' 2222 ');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(client.connects.last, '10.0.0.5:8770/2222');

      client.emit(ConnState.connected);
      await settle(tester);
      expect(settings.hosts.single.pin, '2222');
      expect(settings.hosts.single.name, 'DESKTOP-X');
    });

    testWidgets('lockout shows Too many tries + Try again with the same PIN',
        (tester) async {
      await openRemote(tester);
      client.authError = 'locked';
      client.emit(ConnState.authFailed);
      await settle(tester);
      expect(find.text('Too many tries'), findsOneWidget);
      expect(find.text('Wrong PIN'), findsNothing);
      expect(find.text('Re-enter PIN'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(client.connects.last, '10.0.0.5:8770/1111');
    });

    testWidgets('struggling first connect explains and offers Wake PC',
        (tester) async {
      await openRemote(tester);
      expect(find.text('Connecting…'), findsOneWidget);
      client.lastError = 'Connection refused — is the server running?';
      client.strugglingNow = true;
      client.emit(ConnState.connecting);
      await tester.pump();
      expect(find.text('Can\'t reach Desk'), findsOneWidget);
      expect(
          find.text('Connection refused — is the server running?\n'
              'Still trying 10.0.0.5:8770…'),
          findsOneWidget);
      expect(find.text('Wake PC'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('error Retry reconnects with the PIN in use', (tester) async {
      await openRemote(tester);
      client.lastError = 'Invalid port.';
      client.emit(ConnState.error);
      await tester.pump();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(client.connects.last, '10.0.0.5:8770/1111');
    });

    testWidgets('back needs a second press while connected; arrow leaves',
        (tester) async {
      await openRemote(tester);
      client.emit(ConnState.connected);
      await settle(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(RemoteScreen), findsOneWidget);
      expect(find.text('Press back again to disconnect'), findsOneWidget);
      expect(client.disconnects, 0);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(RemoteScreen), findsNothing);
      expect(client.disconnects, 1);

      // The app-bar arrow is deliberate: one tap.
      nav.currentState!.push(
          MaterialPageRoute(builder: (_) => const RemoteScreen(host: desk)));
      await settle(tester);
      client.emit(ConnState.connected);
      await settle(tester);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byType(RemoteScreen), findsNothing);
    });

    testWidgets('the back hint does not follow you to the host list',
        (tester) async {
      await openRemote(tester);
      client.emit(ConnState.connected);
      await settle(tester);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Press back again to disconnect'), findsOneWidget);
      await tester.tap(find.byType(BackButton)); // left with the arrow instead
      await settle(tester);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('Press back again to disconnect'), findsNothing);
    });

    testWidgets('landscape: lockout screen scrolls instead of clipping',
        (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(800 * 3, 360 * 3);
      tester.view.padding = const FakeViewPadding(top: 24 * 3);
      addTearDown(tester.view.reset);
      await openRemote(tester);
      client.authError = 'locked';
      client.emit(ConnState.authFailed);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Re-enter PIN'));
      await tester.tap(find.text('Re-enter PIN'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('back leaves at once while not connected', (tester) async {
      await openRemote(tester);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(RemoteScreen), findsNothing);
    });

    testWidgets('keep screen on follows the setting and clears on exit',
        (tester) async {
      await openRemote(tester);
      List<Object?> keepOn() => [
            for (final c in volumeCalls)
              if (c.method == 'setKeepScreenOn') c.arguments
          ];
      expect(keepOn(), [true]);
      await settings.setKeepScreenOn(false);
      await tester.pump();
      expect(keepOn(), [true, false]);
      await settings.setKeepScreenOn(true);
      await tester.pump();
      nav.currentState!.pop();
      await settle(tester);
      expect(keepOn(), [true, false, true, false]);
    });

    testWidgets('hiding Keyboard in Settings closes its open panel',
        (tester) async {
      await openRemote(tester);
      client.emit(ConnState.connected);
      await settle(tester);
      await tester.tap(find.text('Keyboard'));
      await settle(tester);
      expect(find.byType(KeyboardBar), findsOneWidget);
      await settings.setFeatureVisible('keyboard', false);
      await settle(tester);
      expect(find.byType(KeyboardBar), findsNothing);
    });

    testWidgets('small phone + soft keyboard: panels cap, trackpad keeps room',
        (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
      addTearDown(tester.view.reset);
      await openRemote(tester);
      client.emit(ConnState.connected);
      await settle(tester);
      await tester.tap(find.text('Media'));
      await settle(tester);
      await tester.tap(find.text('Keyboard'));
      await settle(tester);
      // The IME comes up (and the nav-bar inset goes under it).
      tester.view.viewInsets = const FakeViewPadding(bottom: 290 * 3);
      tester.view.padding = const FakeViewPadding(top: 24 * 3);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Trackpad)).height, greaterThan(120));

      // Without the IME the mouse buttons clear the nav bar (SafeArea).
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
      await tester.tap(find.text('Keyboard'));
      await tester.tap(find.text('Media'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getBottomLeft(find.text('Left')).dy, lessThan(800 - 48));
    });
  });

  group('KeyboardBar', () {
    Future<void> pumpBar(WidgetTester tester) async {
      await pumpApp(
          tester,
          Scaffold(
              body: Align(
                  alignment: Alignment.bottomCenter,
                  child: KeyboardBar(client: client))));
      await settle(tester);
    }

    testWidgets('empty-field Backspace key event reaches the PC',
        (tester) async {
      await pumpBar(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(client.sent, ['key:backspace']);
      // Sticky modifiers apply too, then disarm.
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(client.sent,
          ['key:backspace', 'key:ctrl+backspace', 'key:backspace']);
    });

    testWidgets('sticky modifiers combine with Enter and Backspace',
        (tester) async {
      await pumpBar(tester);
      final field = find.byType(TextField);
      await tester.enterText(field, 'ab');
      expect(client.sent, ['text:ab']);

      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      await tester.enterText(field, 'a'); // Ctrl+Backspace
      await tester.tap(find.text('Shift'));
      await tester.pump();
      await tester.enterText(field, 'a\n'); // Shift+Enter
      await tester.enterText(field, 'x'); // modifiers are disarmed again
      expect(client.sent, [
        'text:ab',
        'key:ctrl+backspace',
        'key:shift+enter',
        'text:x',
      ]);
    });
  });

  group('Trackpad', () {
    Future<void> pumpPad(WidgetTester tester) async {
      await pumpApp(
          tester,
          Scaffold(
              body: Trackpad(client: client, settings: settings)));
    }

    testWidgets('horizontal scroll goes the same way as vertical',
        (tester) async {
      await pumpPad(tester);
      Future<List<String>> drag(Offset by) async {
        client.sent.clear();
        final a = await tester.startGesture(const Offset(100, 300), pointer: 1);
        final b = await tester.startGesture(const Offset(160, 300), pointer: 2);
        for (var i = 0; i < 4; i++) {
          await a.moveBy(by);
          await b.moveBy(by);
        }
        await a.up();
        await b.up();
        await tester.pump(const Duration(milliseconds: 400));
        return List.of(client.sent);
      }

      // Traditional: fingers right -> scroll right (+HWHEEL), like fingers
      // down -> scroll down (-WHEEL).
      final right = await drag(const Offset(10, 0));
      expect(right, isNotEmpty);
      expect(right.every((e) => RegExp(r'^scroll:0,\d+$').hasMatch(e)), isTrue,
          reason: '$right');
      final down = await drag(const Offset(0, 10));
      expect(down.every((e) => RegExp(r'^scroll:-\d+,0$').hasMatch(e)), isTrue,
          reason: '$down');

      await settings.setNaturalScroll(true);
      final natural = await drag(const Offset(10, 0));
      expect(
          natural.every((e) => RegExp(r'^scroll:0,-\d+$').hasMatch(e)), isTrue,
          reason: '$natural');
    });

    testWidgets('lifting one of three fingers is not a scroll; tap = middle',
        (tester) async {
      await pumpPad(tester);
      final a = await tester.startGesture(const Offset(100, 300), pointer: 1);
      final b = await tester.startGesture(const Offset(160, 300), pointer: 2);
      final c = await tester.startGesture(const Offset(130, 360), pointer: 3);
      await c.up();
      await a.moveBy(const Offset(1, 0)); // jitter on a remaining finger
      await b.moveBy(const Offset(0, 1));
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 400));
      // Jitter may scroll a hair, but no jump (was ~120 units = a notch) and
      // the three-finger tap still counts.
      expect(client.sent.last, 'click:middle');
      for (final e in client.sent.where((e) => e.startsWith('scroll:'))) {
        final v = e.substring(7).split(',').map(int.parse);
        expect(v.every((n) => n.abs() < 10), isTrue, reason: e);
      }
    });
  });

  group('ConnectScreen', () {
    const a = RemoteHost(name: 'Desk', ip: '10.0.0.5', pin: '1111');
    const b = RemoteHost(name: 'Laptop', ip: '10.0.0.7');

    testWidgets('Remove can be undone', (tester) async {
      await settings.upsertHost(b);
      await settings.upsertHost(a); // [Desk, Laptop]
      await pumpApp(tester, const ConnectScreen());
      await settle(tester);
      await tester.tap(find.byTooltip('Options').first);
      await settle(tester);
      await tester.tap(find.text('Remove'));
      await settle(tester);
      expect(settings.hosts.map((h) => h.name), ['Laptop']);
      expect(find.text('Removed Desk'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(settings.hosts.map((h) => h.name), ['Desk', 'Laptop']);
      expect(settings.hosts.first.pin, '1111');

      // Not undone: the snackbar still goes away by itself.
      await tester.tap(find.byTooltip('Options').last);
      await settle(tester);
      await tester.tap(find.text('Remove'));
      await settle(tester);
      expect(find.text('Removed Laptop'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('Removed Laptop'), findsNothing);
      expect(settings.hosts.map((h) => h.name), ['Desk']);
    });

    testWidgets('saved PC shows online; silent PCs expire (not while covered)',
        (tester) async {
      await settings.upsertHost(a);
      await pumpApp(tester, const ConnectScreen());
      await settle(tester);
      expect(find.textContaining('make sure the PC server is running'),
          findsOneWidget);

      discovery.add(DiscoveredServer('DESK', '10.0.0.5', 8770));
      discovery.add(DiscoveredServer('Other', '10.0.0.9', 8770));
      await tester.pump();
      expect(find.text('Online · 10.0.0.5:8770'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);

      // Covered by another screen: nothing expires.
      nav.currentState!.push(MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('covered'))));
      await settle(tester);
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 7300)));
      await tester.pump(const Duration(seconds: 3));
      nav.currentState!.pop();
      await settle(tester);
      expect(find.text('Other'), findsOneWidget);

      // Back on top: both went quiet 7+ s ago -> dropped.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Other'), findsNothing);
      expect(find.text('10.0.0.5:8770'), findsOneWidget);
    });

    testWidgets('only the online saved PC answering: no scary hint',
        (tester) async {
      await settings.upsertHost(a);
      await pumpApp(tester, const ConnectScreen());
      await settle(tester);
      discovery.add(DiscoveredServer('DESK', '10.0.0.5', 8770));
      await tester.pump();
      expect(find.text('Looking for other PCs…'), findsOneWidget);
    });
  });

  group('AddHostDialog', () {
    RemoteHost? got;
    Finder field(String label) => find.widgetWithText(TextField, label);

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    Future<void> pumpOpener(WidgetTester tester) async {
      got = null;
      await pumpApp(
          tester,
          Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async => got = await showDialog<RemoteHost>(
                          context: context,
                          builder: (_) => const AddHostDialog()),
                      child: const Text('open')))));
    }

    testWidgets('rejects an empty IP and an out-of-range port',
        (tester) async {
      await pumpOpener(tester);
      await openDialog(tester);
      await tester.tap(find.text('Connect'));
      await settle(tester);
      expect(find.text('Enter the PC\'s IP address'), findsOneWidget);
      expect(find.byType(AddHostDialog), findsOneWidget);

      await tester.enterText(field('IP address'), '10.0.0.5');
      await tester.pump();
      expect(find.text('Enter the PC\'s IP address'), findsNothing);
      await tester.enterText(field('Port'), '70000');
      await tester.tap(find.text('Connect'));
      await settle(tester);
      expect(find.text('Port must be 1–65535'), findsOneWidget);
      expect(find.byType(AddHostDialog), findsOneWidget);
      expect(got, isNull);
    });

    testWidgets('splits a pasted ip:port, keeps a typed name, submits on Done',
        (tester) async {
      await pumpOpener(tester);
      await openDialog(tester);
      await tester.enterText(field('IP address'), ' 10.0.0.5:9000 ');
      await tester.enterText(field('Name'), 'Living Room');
      await tester.enterText(field('PIN'), '4321');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(find.byType(AddHostDialog), findsNothing);
      expect(got, isNotNull);
      expect(got!.ip, '10.0.0.5');
      expect(got!.port, 9000);
      expect(got!.pin, '4321');
      expect(got!.name, 'Living Room');
      expect(got!.customName, isTrue);

      // The untouched default name stays auto-upgradable.
      await openDialog(tester);
      await tester.enterText(field('IP address'), '10.0.0.6');
      await tester.tap(find.text('Connect'));
      await settle(tester);
      expect(got!.port, 8770);
      expect(got!.name, 'My PC');
      expect(got!.customName, isFalse);
    });
  });

  group('PresentationScreen', () {
    testWidgets('warns and sends nothing while the link is down',
        (tester) async {
      await pumpApp(tester, const SizedBox());
      nav.currentState!.push(MaterialPageRoute(
          builder: (_) => PresentationScreen(client: client)));
      await settle(tester);
      expect(find.text('Disconnected from the PC'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(client.sent, isEmpty);

      client.emit(ConnState.connecting);
      await tester.pump();
      expect(find.text('Reconnecting… taps won\'t reach the PC'),
          findsOneWidget);

      client.emit(ConnState.connected);
      await tester.pump();
      expect(find.textContaining('reach the PC'), findsNothing);
      expect(find.text('Disconnected from the PC'), findsNothing);
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(client.sent, ['key:pagedown']);
    });

    testWidgets('landscape: the banner does not overflow the big buttons',
        (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(800 * 3, 360 * 3);
      tester.view.padding = const FakeViewPadding(top: 24 * 3);
      addTearDown(tester.view.reset);
      client.emit(ConnState.connecting);
      await pumpApp(tester, const SizedBox());
      nav.currentState!.push(MaterialPageRoute(
          builder: (_) => PresentationScreen(client: client)));
      await settle(tester);
      expect(find.text('Reconnecting… taps won\'t reach the PC'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
