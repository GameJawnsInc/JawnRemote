import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jawnremote/app_scope.dart';
import 'package:jawnremote/models/macro.dart';
import 'package:jawnremote/screens/apps_screen.dart';
import 'package:jawnremote/screens/clipboard_screen.dart';
import 'package:jawnremote/screens/files_screen.dart';
import 'package:jawnremote/screens/gamepad_screen.dart';
import 'package:jawnremote/screens/macro_editor_screen.dart';
import 'package:jawnremote/screens/macros_screen.dart';
import 'package:jawnremote/services/discovery.dart';
import 'package:jawnremote/services/file_transfer.dart';
import 'package:jawnremote/services/remote_client.dart';
import 'package:jawnremote/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Network-free client for the feature screens: tests set its state and
/// scripted replies, and read back what the UI sent.
class FakeClient extends RemoteClient {
  final List<String> sent = [];
  final List<List<int>> pads = [];
  int appRequests = 0;
  int clipFetches = 0;
  Completer<String?>? clip;
  Completer<List<Map<String, dynamic>>>? displays;
  Completer<Uint8List>? shot;
  bool padOk = true;
  bool padSilent = false;

  void emit(ConnState s) {
    state = s;
    notifyListeners();
  }

  @override
  void key(String k, [List<String> mods = const []]) =>
      sent.add(mods.isEmpty ? 'key:$k' : 'key:${[...mods, k].join('+')}');
  @override
  void text(String s) => sent.add('text:$s');
  @override
  void launch(String target) => sent.add('launch:$target');
  @override
  void requestApps() => appRequests++;

  @override
  Future<String?> fetchClipboard() {
    clipFetches++;
    clip = Completer<String?>();
    return clip!.future;
  }

  @override
  Future<List<Map<String, dynamic>>> requestDisplays() {
    displays = Completer();
    return displays!.future;
  }

  @override
  Future<Uint8List> requestShot({int? display}) {
    shot = Completer();
    return shot!.future;
  }

  @override
  Future<bool> padConnect() async {
    padNoReply = padSilent;
    return padOk && !padSilent;
  }

  @override
  void padDisconnect() => sent.add('paddisconnect');

  @override
  void sendPad(
          {int b = 0,
          int lt = 0,
          int rt = 0,
          int lx = 0,
          int ly = 0,
          int rx = 0,
          int ry = 0}) =>
      pads.add([b, lt, rt, lx, ly, rx, ry]);
}

class _NoDiscovery extends Discovery {
  @override
  Stream<DiscoveredServer> get stream => const Stream.empty();
  @override
  Future<void> start({int port = 8770}) async {}
  @override
  Future<void> stop() async {}
}

// A valid 1x1 PNG for the Quick View viewer.
final Uint8List _png = Uint8List.fromList(const [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, //
  0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84,
  120, 156, 99, 96, 96, 96, 0, 0, 0, 4, 0, 1, 246, 23, 56, 85, 0, 0, 0, 0, 73,
  69, 78, 68, 174, 66, 96, 130,
]);

// XUSB bits (gamepad_win.BUTTON_BITS).
const int _up = 0x0001, _down = 0x0002, _left = 0x0004, _right = 0x0008;
const int _a = 0x1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const volume = MethodChannel('jawnremote/volume');
  const files = MethodChannel('jawnremote/files');
  const pads = MethodChannel('xyz.luan/gamepads');
  final volumeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  final fileCalls = <MethodCall>[];
  Completer<Object?>? pick;

  late Settings settings;
  late FakeClient client;
  final nav = GlobalKey<NavigatorState>();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = Settings();
    await settings.load();
    volumeCalls.clear();
    platformCalls.clear();
    fileCalls.clear();
    messenger().setMockMethodCallHandler(volume, (call) async {
      volumeCalls.add(call);
      return null;
    });
    messenger().setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      platformCalls.add(call);
      return null;
    });
    messenger().setMockMethodCallHandler(files, (call) async {
      fileCalls.add(call);
      if (call.method == 'pickFile') return pick?.future;
      return null;
    });
    messenger().setMockMethodCallHandler(pads, (call) async => <Object?>[]);
  });

  tearDown(() {
    for (final c in [volume, SystemChannels.platform, files, pads]) {
      messenger().setMockMethodCallHandler(c, null);
    }
  });

  /// Pushes [screen] over a blank home page (so it can be popped).
  Future<void> open(WidgetTester tester, Widget Function(FakeClient) screen,
      {bool connected = true}) async {
    client = FakeClient();
    if (connected) client.state = ConnState.connected;
    await tester.pumpWidget(AppScope(
      settings: settings,
      client: client,
      discovery: _NoDiscovery(),
      fileTransfer: FileTransfer(client),
      child: MaterialApp(
          navigatorKey: nav, home: const Scaffold(body: Text('home'))),
    ));
    nav.currentState!.push(MaterialPageRoute(builder: (_) => screen(client)));
    await tester.pumpAndSettle();
  }

  List<Object?> setClips() => [
        for (final c in platformCalls)
          if (c.method == 'Clipboard.setData') (c.arguments as Map)['text']
      ];

  group('Clipboard', () {
    testWidgets('Get from PC with no text leaves the phone clipboard alone',
        (tester) async {
      await open(tester, (c) => ClipboardScreen(client: c));
      await tester.tap(find.text('Get from PC'));
      await tester.pump();
      // Busy: spinner in the card, and a second tap doesn't ask again.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Get from PC'));
      expect(client.clipFetches, 1);

      // A notification unrelated to the reply must not be taken as it.
      client.emit(ConnState.connecting);
      client.emit(ConnState.connected);
      await tester.pump();
      expect(setClips(), isEmpty);

      client.clip!.complete('');
      await tester.pump();
      expect(setClips(), isEmpty);
      expect(
          find.text(
              'The PC clipboard has no text (it may hold an image or files).'),
          findsOneWidget);
      expect(find.text('(no text on the PC clipboard)'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Get from PC copies text; no reply says so', (tester) async {
      await open(tester, (c) => ClipboardScreen(client: c));
      await tester.tap(find.text('Get from PC'));
      await tester.pump();
      client.pcClipboard = 'hello';
      client.clip!.complete('hello');
      await tester.pumpAndSettle();
      expect(setClips(), ['hello']);
      expect(find.text('Copied the PC clipboard to your phone.'),
          findsOneWidget);

      await tester.tap(find.text('Get from PC'));
      await tester.pump();
      client.clip!.complete(null);
      await tester.pumpAndSettle();
      expect(setClips(), ['hello']);
      expect(find.text('The PC didn\'t answer. Try again.'), findsOneWidget);
    });

    testWidgets('Back during the Quick View spinner cancels it',
        (tester) async {
      await open(tester, (c) => ClipboardScreen(client: c));
      await tester.tap(find.text('Quick View'));
      await tester.pump();
      expect(find.text('Capturing the PC screen…'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Capturing the PC screen…'), findsNothing);

      client.displays!.complete(const []);
      await tester.pump();
      client.shot!.complete(_png);
      await tester.pumpAndSettle();
      // Still on the Clipboard screen, and no viewer popped up.
      expect(find.byType(ClipboardScreen), findsOneWidget);
      expect(find.text('Quick View'), findsOneWidget); // just the card
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Quick View opens the viewer when not canceled',
        (tester) async {
      await open(tester, (c) => ClipboardScreen(client: c));
      await tester.tap(find.text('Quick View'));
      await tester.pump();
      client.displays!.complete(const []);
      await tester.pump();
      client.shot!.complete(_png);
      await tester.pumpAndSettle();
      expect(find.text('Capturing the PC screen…'), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardScreen), findsOneWidget);
    });

    testWidgets('Cancel on the Quick View spinner cancels it',
        (tester) async {
      await open(tester, (c) => ClipboardScreen(client: c));
      await tester.tap(find.text('Quick View'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      client.displays!.complete(const []);
      await tester.pump();
      client.shot!.completeError('The PC could not capture the screen.');
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('Files', () {
    testWidgets('shows Preparing while the pick runs; no second picker',
        (tester) async {
      await open(tester, (c) => FilesScreen(client: c));
      pick = Completer<Object?>();
      await tester.tap(find.text('Send a file to PC'));
      await tester.pump();
      expect(find.text('Preparing file…'), findsOneWidget);
      await tester.tap(find.text('Send a file to PC'));
      await tester.pump();
      expect(fileCalls.where((c) => c.method == 'pickFile').length, 1);

      pick!.complete(null); // picker canceled
      await tester.pumpAndSettle();
      expect(find.text('Preparing file…'), findsNothing);
      pick = null;
    });
  });

  group('Apps', () {
    testWidgets('offline tap says so; list is re-requested on reconnect',
        (tester) async {
      await open(tester, (c) => AppsScreen(client: c), connected: false);
      expect(client.appRequests, 1);
      await tester.tap(find.text('YouTube'));
      await tester.pump();
      expect(client.sent, isEmpty);
      expect(find.text('Not connected to a PC.'), findsOneWidget);

      client.emit(ConnState.connected);
      expect(client.appRequests, 2);
      client.emit(ConnState.connecting);
      client.serverApps = [
        {'name': 'Plex', 'target': 'plex.exe'}
      ];
      client.emit(ConnState.connected);
      expect(client.appRequests, 2); // already have the PC's list
      await tester.pump();
      await tester.tap(find.text('Plex'));
      expect(client.sent, ['launch:plex.exe']);
    });
  });

  group('Macros', () {
    const a = Macro(label: 'Alpha', steps: [MacroStep(type: 'key', value: 'a')]);
    const b = Macro(label: 'Beta', steps: [
      MacroStep(type: 'key', value: 'b'),
      MacroStep(type: 'delay', value: '500'),
    ]);

    testWidgets('delete offers Undo that restores it in place',
        (tester) async {
      await settings.saveMacros([a, b]);
      await open(tester, (c) => MacrosScreen(client: c));
      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(settings.macros.map((m) => m.label), ['Beta']);
      expect(find.text('Deleted "Alpha"'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(settings.macros.map((m) => m.label), ['Alpha', 'Beta']);

      // The Undo bar times out on its own.
      await tester.longPress(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Deleted "Beta"'), findsNothing);
    });

    testWidgets('a second tap while running does not start another run',
        (tester) async {
      await settings.saveMacros([a, b]);
      await open(tester, (c) => MacrosScreen(client: c));
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(client.sent, ['key:b']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('Beta'));
      await tester.pump(const Duration(milliseconds: 700));
      expect(client.sent, ['key:b', 'key:b']);
      await tester.pumpAndSettle();
    });
  });

  group('Macro editor', () {
    const m = Macro(label: 'Copy', steps: [
      MacroStep(type: 'key', value: 'c', mods: ['ctrl']),
      MacroStep(type: 'text', value: 'hi'),
    ]);

    testWidgets('back without edits leaves at once', (tester) async {
      await open(tester, (_) => const MacroEditorScreen(initial: m));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MacroEditorScreen), findsNothing);
    });

    testWidgets('back with edits asks; Keep editing stays, Discard leaves',
        (tester) async {
      await open(tester, (_) => const MacroEditorScreen(initial: m));
      await tester.enterText(find.widgetWithText(TextField, 'Copy'), 'Copy2');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(MacroEditorScreen), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(MacroEditorScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('step delete can be undone; Save still returns the macro',
        (tester) async {
      Macro? result;
      client = FakeClient();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav, home: const Scaffold(body: Text('home'))));
      unawaited(nav.currentState!
          .push<Macro>(MaterialPageRoute(
              builder: (_) => const MacroEditorScreen(initial: m)))
          .then((v) => result = v));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + C'), findsNothing);
      expect(find.text('Step removed'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + C'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(result!.steps.map((s) => s.summary), ['Ctrl + C', 'Type  "hi"']);
    });

    testWidgets('step sheet shows why Done is refused, and scrolls',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(tester.view.reset);
      await open(tester, (_) => const MacroEditorScreen(initial: null));
      await tester.tap(find.text('Add step'));
      await tester.pumpAndSettle();
      // Landscape phone with the keyboard up.
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a key (e.g. c, f4, enter).'), findsOneWidget);
      expect(find.text('Step'), findsOneWidget); // sheet still open

      await tester.enterText(find.widgetWithText(TextField, 'Key'), 'pgdn');
      await tester.pump();
      expect(find.text('Enter a key (e.g. c, f4, enter).'), findsNothing);
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      tester.view.viewInsets = FakeViewPadding.zero; // keyboard goes away
      await tester.pumpAndSettle();
      expect(find.text('Step'), findsNothing);
      expect(find.text('Pgdn'), findsOneWidget);
    });
  });

  group('Gamepad', () {
    Future<void> openPad(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(tester.view.reset);
      await open(tester, (c) => GamepadScreen(client: c));
    }

    Future<void> closePad(WidgetTester tester) async {
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    }

    Future<void> hw(WidgetTester tester, String type, String key, double v) async {
      await messenger().handlePlatformMessage(
          'xyz.luan/gamepads',
          const StandardMethodCodec().encodeMethodCall(
              MethodCall('onGamepadEvent', {
            'gamepadId': '7',
            'time': 0,
            'type': type,
            'key': key,
            'value': v,
          })),
          (_) {});
      await tester.pump(const Duration(milliseconds: 40));
    }

    List<Object?> capture() => [
          for (final c in volumeCalls)
            if (c.method == 'setPadCapture') c.arguments
        ];

    testWidgets('forwards a physical controller with the plugin key names',
        (tester) async {
      await openPad(tester);
      expect(capture(), [true]);

      await hw(tester, 'button', 'KEYCODE_BUTTON_A', 1.0);
      expect(client.pads.last[0], _a);
      expect(find.textContaining('Controller connected'), findsOneWidget);
      await hw(tester, 'button', 'KEYCODE_BUTTON_A', 0.0);
      expect(client.pads.last[0], 0);

      // The plugin already reports +1 as up for sticks and the hat.
      await hw(tester, 'analog', 'AXIS_Y', 1.0);
      expect(client.pads.last[4], 32767);
      await hw(tester, 'analog', 'AXIS_RZ', -1.0);
      expect(client.pads.last[6], -32767);
      await hw(tester, 'analog', 'AXIS_HAT_Y', 1.0);
      expect(client.pads.last[0], _up);
      await hw(tester, 'analog', 'AXIS_HAT_Y', -1.0);
      expect(client.pads.last[0], _down);
      await hw(tester, 'analog', 'AXIS_HAT_Y', 0.0);
      await hw(tester, 'button', 'KEYCODE_DPAD_LEFT', 1.0);
      expect(client.pads.last[0], _left);
      await hw(tester, 'button', 'KEYCODE_DPAD_LEFT', 0.0);

      // Digital L2 survives an analog trigger event.
      await hw(tester, 'button', 'KEYCODE_BUTTON_L2', 1.0);
      expect(client.pads.last[1], 255);
      await hw(tester, 'analog', 'AXIS_LTRIGGER', 0.0);
      expect(client.pads.last[1], 255);
      await hw(tester, 'button', 'KEYCODE_BUTTON_L2', 0.0);
      expect(client.pads.last[1], 0);

      await closePad(tester);
      expect(capture(), [true, false]);
      // Leaving restores the normal system UI (manual + all bars), not
      // edge-to-edge.
      final ui = platformCalls
          .where((c) => c.method.startsWith('SystemChrome.setEnabledSystemUI'))
          .last;
      expect(ui.method, 'SystemChrome.setEnabledSystemUIOverlays');
      expect(ui.arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
    });

    testWidgets('reopening during the close animation keeps capture on',
        (tester) async {
      await openPad(tester);
      nav.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 50)); // still animating
      nav.currentState!.push(
          MaterialPageRoute(builder: (_) => GamepadScreen(client: client)));
      await tester.pumpAndSettle();
      // The old screen's dispose ran after the new initState: it must not
      // switch capture (or landscape) back off under the open pad.
      expect(capture(), [true, true]);
      await closePad(tester);
      expect(capture(), [true, true, false]);
    });

    testWidgets('d-pad presses diagonals and rolls between directions',
        (tester) async {
      await openPad(tester);
      final up = tester.getCenter(find.byIcon(Icons.keyboard_arrow_up));
      final right = tester.getCenter(find.byIcon(Icons.keyboard_arrow_right));
      final centre = Offset(up.dx, right.dy);

      final g = await tester.startGesture(centre + const Offset(40, -40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(client.pads.last[0], _up | _right);
      await g.moveTo(centre + const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 40));
      expect(client.pads.last[0], _right);
      await g.moveTo(centre + const Offset(-50, 5));
      await tester.pump(const Duration(milliseconds: 40));
      expect(client.pads.last[0], _left);
      await g.up();
      await tester.pump(const Duration(milliseconds: 40));
      expect(client.pads.last[0], 0);
      await closePad(tester);
    });

    testWidgets('sticks stay clear of the face buttons and d-pad at 640x360',
        (tester) async {
      await openPad(tester);
      final sticks = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_AnalogStick');
      expect(sticks, findsNWidgets(2));
      final left = tester.getRect(sticks.at(0));
      final right = tester.getRect(sticks.at(1));
      // The d-pad's touch box is 150 wide around its cross; X is 58 wide.
      final dpadLeft =
          tester.getCenter(find.byIcon(Icons.keyboard_arrow_up)).dx - 75;
      final xLeft = tester.getCenter(find.text('X')).dx - 29;
      expect(left.right, lessThanOrEqualTo(dpadLeft - 8));
      expect(right.right, lessThanOrEqualTo(xLeft - 8));
      await closePad(tester);
    });

    testWidgets('no reply explains a link/server problem, not the driver',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(tester.view.reset);
      client = FakeClient()..state = ConnState.connected;
      client.padSilent = true;
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav, home: GamepadScreen(client: client)));
      await tester.pumpAndSettle();
      expect(find.text('The PC didn\'t answer'), findsOneWidget);
      expect(find.text('Gamepad driver not available'), findsNothing);

      client.padSilent = false;
      client.padOk = false;
      client.padError = 'ViGEmBus not installed';
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Gamepad driver not available'), findsOneWidget);
      expect(find.text('ViGEmBus not installed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
