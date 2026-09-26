import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import '../services/hardware_volume.dart';
import '../services/remote_client.dart';

// XUSB button bits -- must match the server (gamepad_win.BUTTON_BITS).
const int _kUp = 0x0001,
    _kDown = 0x0002,
    _kLeft = 0x0004,
    _kRight = 0x0008,
    _kStart = 0x0010,
    _kBack = 0x0020,
    _kLS = 0x0040,
    _kRS = 0x0080,
    _kLB = 0x0100,
    _kRB = 0x0200,
    _kGuide = 0x0400,
    _kA = 0x1000,
    _kB = 0x2000,
    _kX = 0x4000,
    _kY = 0x8000;

const Color _accent = Color(0xFF4F8CFF);
const Color _bg = Color(0xFF0B0E13);

/// A virtual Xbox 360 gamepad. Touch controls drive it directly; if a physical
/// controller is paired to the phone, its input is forwarded too (the two are
/// merged, so either works). The pad is stateful end-to-end: holding a control
/// holds the input on the PC until released.
class GamepadScreen extends StatefulWidget {
  final RemoteClient client;
  const GamepadScreen({super.key, required this.client});
  @override
  State<GamepadScreen> createState() => _GamepadScreenState();
}

class _GamepadScreenState extends State<GamepadScreen> {
  // Resolved padconnect result: null = still asking, true/false = answer.
  bool? _available;

  // Touch contribution.
  int _tBtn = 0, _tLT = 0, _tRT = 0, _tLX = 0, _tLY = 0, _tRX = 0, _tRY = 0;
  // Hardware-controller contribution (forwarded physical pad).
  int _hBtn = 0, _hLT = 0, _hRT = 0, _hLX = 0, _hLY = 0, _hRX = 0, _hRY = 0;
  // L2/R2 reported as keys, kept apart from the analog trigger axes so an axis
  // event can't cancel a held digital press.
  int _hLTd = 0, _hRTd = 0;

  StreamSubscription<GamepadEvent>? _hwSub;
  String _hwName = '';
  Timer? _tx; // ~60 Hz coalescing sender
  bool _dirty = false;
  bool _released = false; // user unplugged the pad via the Release button
  List<int> _lastSent = const [];

  // Gamepad screens alive right now. Reopening it during the close animation
  // runs the new one's initState before the old one's dispose, so only the
  // last one out may undo the capture / landscape / immersive settings.
  static int _live = 0;

  @override
  void initState() {
    super.initState();
    _live++;
    // Gamepads live in landscape, full-bleed.
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _tx = Timer.periodic(const Duration(milliseconds: 16), (_) => _flush());
    // Route a paired controller's keys/axes to the gamepads plugin while this
    // screen is open (everywhere else they reach the app as usual).
    HardwareVolume.setPadCapture(true);
    _connect();
    _initHardware();
  }

  Future<void> _connect() async {
    // Opened (or retried) while the link is re-establishing: give it up to
    // ~10 s first, or padconnect is dropped and reads as "no driver".
    for (var i = 0; i < 50 && mounted && !widget.client.isConnected; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    final ok = await widget.client.padConnect();
    if (mounted) setState(() => _available = ok);
  }

  /// Explicitly unplug the virtual pad from the PC and leave. Sets [_released]
  /// so _flush stops sending state (the server auto-replugs on any pad frame).
  void _releaseAndExit() {
    _released = true;
    _tx?.cancel();
    widget.client.padDisconnect();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _initHardware() async {
    try {
      final pads = await Gamepads.list();
      if (pads.isNotEmpty && mounted) {
        setState(() => _hwName = pads.first.name);
      }
    } catch (_) {
      // No gamepad support on this platform / no controller -- touch still works.
    }
    if (!mounted) return; // left the screen while list() was pending
    try {
      // Independent of list(): a controller turned on later still reports.
      _hwSub = Gamepads.events.listen(_onHwEvent);
    } catch (_) {}
  }

  // ---- merge touch + hardware into one state and send (coalesced) ----
  int _mergeAxis(int t, int h) => h.abs() > 4000 ? h : t; // hw wins when deflected
  int _mergeTrig(int t, int h) => h > t ? h : t;

  void _markDirty() => _dirty = true;

  void _flush() {
    if (_released || !_dirty) return;
    _dirty = false;
    final b = _tBtn | _hBtn;
    final lt = _mergeTrig(_tLT, math.max(_hLT, _hLTd)),
        rt = _mergeTrig(_tRT, math.max(_hRT, _hRTd));
    final lx = _mergeAxis(_tLX, _hLX), ly = _mergeAxis(_tLY, _hLY);
    final rx = _mergeAxis(_tRX, _hRX), ry = _mergeAxis(_tRY, _hRY);
    final snap = [b, lt, rt, lx, ly, rx, ry];
    if (_listEq(snap, _lastSent)) return; // nothing actually changed
    _lastSent = snap;
    widget.client.sendPad(b: b, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry);
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- touch handlers ----
  void _touchButton(int bit, bool down) {
    setState(() => _tBtn = down ? (_tBtn | bit) : (_tBtn & ~bit));
    if (down) HapticFeedback.selectionClick();
    _markDirty();
  }

  void _touchTrigger(bool left, bool down) {
    setState(() {
      if (left) {
        _tLT = down ? 255 : 0;
      } else {
        _tRT = down ? 255 : 0;
      }
    });
    if (down) HapticFeedback.selectionClick();
    _markDirty();
  }

  void _touchStick(bool left, double x, double y) {
    // x,y are -1..1 (screen convention: +y down). Stick +Y is up -> invert.
    final ix = (x * 32767).round().clamp(-32768, 32767);
    final iy = (-y * 32767).round().clamp(-32768, 32767);
    if (left) {
      _tLX = ix;
      _tLY = iy;
    } else {
      _tRX = ix;
      _tRY = iy;
    }
    _markDirty();
  }

  // ---- physical controller forwarding ----
  // The Android gamepads plugin names keys by KeyEvent.keyCodeToString()
  // ("KEYCODE_BUTTON_A") and axes by MotionEvent.axisToString() ("AXIS_Y"),
  // and already flips AXIS_Y / AXIS_RZ / AXIS_HAT_Y so +1 is up.
  void _onHwEvent(GamepadEvent e) {
    if (e.type == KeyType.button) {
      final bit = _hwButtonBits[e.key];
      final down = e.value > 0.5;
      if (bit != null) {
        _hBtn = down ? (_hBtn | bit) : (_hBtn & ~bit);
      } else if (e.key == 'KEYCODE_BUTTON_L2') {
        _hLTd = down ? 255 : 0; // L2 as a digital button
      } else if (e.key == 'KEYCODE_BUTTON_R2') {
        _hRTd = down ? 255 : 0; // R2 as a digital button
      }
    } else {
      _applyHwAxis(e.key, e.value);
    }
    if (_hwName.isEmpty && mounted) setState(() => _hwName = 'Controller');
    _markDirty();
  }

  void _applyHwAxis(String key, double v) {
    int s16() => (v * 32767).round().clamp(-32768, 32767);
    int trig() => (v.clamp(0.0, 1.0) * 255).round();
    switch (key) {
      case 'AXIS_X':
        _hLX = s16();
        break;
      case 'AXIS_Y':
        _hLY = s16(); // already +up (the plugin inverts it)
        break;
      case 'AXIS_Z':
        _hRX = s16();
        break;
      case 'AXIS_RZ':
        _hRY = s16(); // already +up
        break;
      case 'AXIS_LTRIGGER':
      case 'AXIS_BRAKE':
        _hLT = trig();
        break;
      case 'AXIS_RTRIGGER':
      case 'AXIS_GAS':
        _hRT = trig();
        break;
      case 'AXIS_HAT_X': // d-pad
        _hBtn &= ~(_kLeft | _kRight);
        if (v < -0.5) _hBtn |= _kLeft;
        if (v > 0.5) _hBtn |= _kRight;
        break;
      case 'AXIS_HAT_Y': // d-pad, +1 = up
        _hBtn &= ~(_kUp | _kDown);
        if (v > 0.5) _hBtn |= _kUp;
        if (v < -0.5) _hBtn |= _kDown;
        break;
    }
  }

  static const Map<String, int> _hwButtonBits = {
    'KEYCODE_BUTTON_A': _kA,
    'KEYCODE_BUTTON_B': _kB,
    'KEYCODE_BUTTON_X': _kX,
    'KEYCODE_BUTTON_Y': _kY,
    'KEYCODE_BUTTON_L1': _kLB,
    'KEYCODE_BUTTON_R1': _kRB,
    'KEYCODE_BUTTON_THUMBL': _kLS,
    'KEYCODE_BUTTON_THUMBR': _kRS,
    'KEYCODE_BUTTON_START': _kStart,
    'KEYCODE_BUTTON_SELECT': _kBack,
    'KEYCODE_BUTTON_MODE': _kGuide,
    'KEYCODE_DPAD_UP': _kUp,
    'KEYCODE_DPAD_DOWN': _kDown,
    'KEYCODE_DPAD_LEFT': _kLeft,
    'KEYCODE_DPAD_RIGHT': _kRight,
  };

  @override
  void dispose() {
    _tx?.cancel();
    _hwSub?.cancel();
    // Release all inputs but KEEP the pad plugged in. Leaving this screen (to
    // use Macros/Mouse and come back) must NOT disconnect the controller, or
    // games pause on "controller disconnected." The pad is unplugged only when
    // the connection ends (server failsafe) or you disconnect from the PC.
    if (!_released) widget.client.sendPad();
    if (--_live == 0) {
      HardwareVolume.setPadCapture(false);
      // Back to the app's normal mode (bars shown, laid out above the nav
      // bar). Not edgeToEdge: that would put the remote's bottom buttons
      // under the nav bar on Android 10-14.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(child: _content()),
    );
  }

  Widget _content() {
    if (_available == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_available == false) {
      return _UnavailableMessage(
        error: widget.client.padError,
        noReply: widget.client.padNoReply,
        onRetry: () {
          setState(() => _available = null);
          _connect();
        },
        onBack: () => Navigator.of(context).maybePop(),
      );
    }
    return _controls();
  }

  Widget _controls() {
    return Stack(children: [
      Row(children: [
        Expanded(child: _leftHalf()),
        Expanded(child: _rightHalf()),
      ]),
      // Back / Start in the center top, plus a close button.
      Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _MiniButton(label: 'Back', onChanged: (d) => _touchButton(_kBack, d)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Release controller (unplug from the PC)',
              icon: const Icon(Icons.videogame_asset_off, color: Colors.white38),
              onPressed: _releaseAndExit,
            ),
            IconButton(
              tooltip: 'Minimize — keeps the controller connected',
              icon: const Icon(Icons.close, color: Colors.white38),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            _MiniButton(
                label: 'Start', onChanged: (d) => _touchButton(_kStart, d)),
          ]),
        ),
      ),
      if (_hwName.isNotEmpty)
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('🎮 $_hwName connected',
                style: const TextStyle(color: Colors.white30, fontSize: 11)),
          ),
        ),
    ]);
  }

  Widget _leftHalf() {
    return LayoutBuilder(builder: (context, c) {
      // Shrink the stick on narrow halves so it never reaches the D-pad box
      // (150 wide, 12 from the edge; the stick sits 16 in, plus an 8 gap).
      final base = (c.maxWidth * 0.42).clamp(96.0, 150.0);
      final room = c.maxWidth - 150 - 12 - 16 - 8;
      final stick = math.max(72.0, math.min(base, room));
      return Stack(children: [
        Positioned(
          left: 8,
          top: 2,
          child: Row(children: [
            _Shoulder(label: 'LB', onChanged: (d) => _touchButton(_kLB, d)),
            const SizedBox(width: 8),
            _Shoulder(label: 'LT', onChanged: (d) => _touchTrigger(true, d)),
          ]),
        ),
        Positioned(
          left: 16,
          bottom: 14,
          child: _AnalogStick(
              size: stick, onChanged: (x, y) => _touchStick(true, x, y)),
        ),
        Positioned(
          right: 12,
          bottom: 22,
          child: _DPad(onChanged: _touchButton),
        ),
      ]);
    });
  }

  Widget _rightHalf() {
    return LayoutBuilder(builder: (context, c) {
      // Same for the face buttons (174 box, 16 from the edge; stick 12 in).
      final base = (c.maxWidth * 0.42).clamp(96.0, 150.0);
      final room = c.maxWidth - 174 - 16 - 12 - 8;
      final stick = math.max(72.0, math.min(base, room));
      return Stack(children: [
        Positioned(
          right: 8,
          top: 2,
          child: Row(children: [
            _Shoulder(label: 'RT', onChanged: (d) => _touchTrigger(false, d)),
            const SizedBox(width: 8),
            _Shoulder(label: 'RB', onChanged: (d) => _touchButton(_kRB, d)),
          ]),
        ),
        Positioned(
          right: 16,
          bottom: 14,
          child: _FaceButtons(onChanged: _touchButton),
        ),
        Positioned(
          left: 12,
          bottom: 22,
          child: _AnalogStick(
              size: stick, onChanged: (x, y) => _touchStick(false, x, y)),
        ),
      ]);
    });
  }
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

/// Draggable analog stick. Reports a unit vector (-1..1, +y down) while held and
/// snaps back to centre on release. Tracks its own pointer so it keeps following
/// a finger that drags outside its bounds (and other fingers hit other controls).
class _AnalogStick extends StatefulWidget {
  final double size;
  final void Function(double x, double y) onChanged;
  const _AnalogStick({required this.size, required this.onChanged});
  @override
  State<_AnalogStick> createState() => _AnalogStickState();
}

class _AnalogStickState extends State<_AnalogStick> {
  Offset _v = Offset.zero; // -1..1
  int? _ptr;

  void _update(Offset local) {
    final r = widget.size / 2;
    var dx = (local.dx - r) / r;
    var dy = (local.dy - r) / r;
    final mag = math.sqrt(dx * dx + dy * dy);
    if (mag > 1) {
      dx /= mag;
      dy /= mag;
    }
    setState(() => _v = Offset(dx, dy));
    widget.onChanged(dx, dy);
  }

  void _end() {
    _ptr = null;
    setState(() => _v = Offset.zero);
    widget.onChanged(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.size / 2;
    final knob = widget.size * 0.42;
    return Listener(
      onPointerDown: (e) {
        _ptr = e.pointer;
        _update(e.localPosition);
      },
      onPointerMove: (e) {
        if (e.pointer == _ptr) _update(e.localPosition);
      },
      onPointerUp: (e) {
        if (e.pointer == _ptr) _end();
      },
      onPointerCancel: (e) {
        if (e.pointer == _ptr) _end();
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF161C24),
          border: Border.all(color: Colors.white12, width: 2),
        ),
        child: Stack(children: [
          Positioned(
            left: r + _v.dx * r * 0.55 - knob / 2,
            top: r + _v.dy * r * 0.55 - knob / 2,
            child: Container(
              width: knob,
              height: knob,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _v == Offset.zero ? Colors.white24 : _accent,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A round press-and-hold button. Fires [onChanged] true on press, false on
/// release/cancel; multi-touch friendly (its own pointer stream).
class _PadButton extends StatefulWidget {
  final String label;
  final Color color;
  final ValueChanged<bool> onChanged;
  const _PadButton({
    required this.label,
    required this.onChanged,
    this.color = const Color(0xFF2A313C),
  });
  @override
  State<_PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<_PadButton> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        setState(() => _down = true);
        widget.onChanged(true);
      },
      onPointerUp: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      onPointerCancel: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down ? _accent : widget.color,
          border: Border.all(color: Colors.white10, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(widget.label,
            style: const TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// ABXY in the usual diamond (A bottom, B right, X left, Y top).
class _FaceButtons extends StatelessWidget {
  final void Function(int bit, bool down) onChanged;
  const _FaceButtons({required this.onChanged});
  @override
  Widget build(BuildContext context) {
    Widget b(String l, int bit, Color c) =>
        _PadButton(label: l, color: c, onChanged: (d) => onChanged(bit, d));
    const sz = 174.0;
    return SizedBox(
      width: sz,
      height: sz,
      child: Stack(children: [
        Align(alignment: Alignment.topCenter, child: b('Y', _kY, const Color(0xFF9A8000))),
        Align(alignment: Alignment.centerLeft, child: b('X', _kX, const Color(0xFF1C4FA0))),
        Align(alignment: Alignment.centerRight, child: b('B', _kB, const Color(0xFF9A1B1B))),
        Align(alignment: Alignment.bottomCenter, child: b('A', _kA, const Color(0xFF1B7A2E))),
      ]),
    );
  }
}

/// 8-way d-pad: one pointer tracked over the whole cross, so a thumb can hit
/// diagonals and roll between directions without lifting.
class _DPad extends StatefulWidget {
  final void Function(int bit, bool down) onChanged;
  const _DPad({required this.onChanged});
  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  static const double _sz = 150;
  int _bits = 0;
  int? _ptr;

  // Directions under [p]: a small dead centre, then 8 sectors slightly biased
  // toward the cardinals (so menus don't catch stray diagonals).
  static int _bitsFor(Offset p) {
    final d = p - const Offset(_sz / 2, _sz / 2);
    final dist = d.distance;
    if (dist < 18) return 0;
    var b = 0;
    if (d.dx > 0.45 * dist) b |= _kRight;
    if (d.dx < -0.45 * dist) b |= _kLeft;
    if (d.dy > 0.45 * dist) b |= _kDown;
    if (d.dy < -0.45 * dist) b |= _kUp;
    return b;
  }

  void _apply(int nb) {
    final changed = nb ^ _bits;
    if (changed == 0) return;
    for (final bit in const [_kUp, _kDown, _kLeft, _kRight]) {
      if ((changed & bit) != 0) widget.onChanged(bit, (nb & bit) != 0);
    }
    if ((nb & ~_bits) != 0) HapticFeedback.selectionClick();
    setState(() => _bits = nb);
  }

  void _end(PointerEvent e) {
    if (e.pointer != _ptr) return;
    _ptr = null;
    _apply(0);
  }

  @override
  Widget build(BuildContext context) {
    Widget arrow(IconData icon, int bit) => Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: (_bits & bit) != 0 ? _accent : const Color(0xFF2A313C),
          ),
          child: Icon(icon, color: Colors.white, size: 30),
        );
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (_ptr != null) return; // one thumb per d-pad
        _ptr = e.pointer;
        _apply(_bitsFor(e.localPosition));
      },
      onPointerMove: (e) {
        if (e.pointer == _ptr) _apply(_bitsFor(e.localPosition));
      },
      onPointerUp: _end,
      onPointerCancel: _end,
      child: SizedBox(
        width: _sz,
        height: _sz,
        child: Stack(children: [
          Align(alignment: Alignment.topCenter, child: arrow(Icons.keyboard_arrow_up, _kUp)),
          Align(alignment: Alignment.bottomCenter, child: arrow(Icons.keyboard_arrow_down, _kDown)),
          Align(alignment: Alignment.centerLeft, child: arrow(Icons.keyboard_arrow_left, _kLeft)),
          Align(alignment: Alignment.centerRight, child: arrow(Icons.keyboard_arrow_right, _kRight)),
        ]),
      ),
    );
  }
}

/// Wide shoulder/trigger button (LB/LT/RB/RT).
class _Shoulder extends StatefulWidget {
  final String label;
  final ValueChanged<bool> onChanged;
  const _Shoulder({required this.label, required this.onChanged});
  @override
  State<_Shoulder> createState() => _ShoulderState();
}

class _ShoulderState extends State<_Shoulder> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        setState(() => _down = true);
        widget.onChanged(true);
        HapticFeedback.selectionClick();
      },
      onPointerUp: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      onPointerCancel: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      child: Container(
        width: 76,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _down ? _accent : const Color(0xFF2A313C),
        ),
        child: Text(widget.label,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// Small pill button for Start/Back.
class _MiniButton extends StatefulWidget {
  final String label;
  final ValueChanged<bool> onChanged;
  const _MiniButton({required this.label, required this.onChanged});
  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        setState(() => _down = true);
        widget.onChanged(true);
      },
      onPointerUp: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      onPointerCancel: (_) {
        setState(() => _down = false);
        widget.onChanged(false);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: _down ? _accent : const Color(0xFF2A313C),
        ),
        child: Text(widget.label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ),
    );
  }
}

class _UnavailableMessage extends StatelessWidget {
  final String error;
  final bool noReply; // padconnect timed out: link down or an old server
  final VoidCallback onRetry;
  final VoidCallback onBack;
  const _UnavailableMessage(
      {required this.error,
      required this.noReply,
      required this.onRetry,
      required this.onBack});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.sports_esports_outlined,
                size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
                noReply
                    ? 'The PC didn\'t answer'
                    : 'Gamepad driver not available',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              noReply
                  ? 'Check that your phone is connected, and that the '
                      'JawnRemote server on the PC is up to date (the gamepad '
                      'needs version 1.13 or newer).'
                  : 'The PC needs the ViGEmBus virtual-controller driver. '
                      'Re-run the JawnRemote installer and tick "Install '
                      'virtual-gamepad driver", then reconnect.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
            if (!noReply && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white30, fontSize: 12)),
            ],
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(onPressed: onBack, child: const Text('Back')),
              const SizedBox(width: 12),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ]),
          ]),
        ),
      ),
    );
  }
}
