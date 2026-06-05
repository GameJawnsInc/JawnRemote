import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

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

  StreamSubscription<GamepadEvent>? _hwSub;
  String _hwName = '';
  Timer? _tx; // ~60 Hz coalescing sender
  bool _dirty = false;
  List<int> _lastSent = const [];

  @override
  void initState() {
    super.initState();
    // Gamepads live in landscape, full-bleed.
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _tx = Timer.periodic(const Duration(milliseconds: 16), (_) => _flush());
    _connect();
    _initHardware();
  }

  Future<void> _connect() async {
    final ok = await widget.client.padConnect();
    if (mounted) setState(() => _available = ok);
  }

  Future<void> _initHardware() async {
    try {
      final pads = await Gamepads.list();
      if (pads.isNotEmpty && mounted) {
        setState(() => _hwName = pads.first.name);
      }
      _hwSub = Gamepads.events.listen(_onHwEvent);
    } catch (_) {
      // No gamepad support on this platform / no controller -- touch still works.
    }
  }

  // ---- merge touch + hardware into one state and send (coalesced) ----
  int _mergeAxis(int t, int h) => h.abs() > 4000 ? h : t; // hw wins when deflected
  int _mergeTrig(int t, int h) => h > t ? h : t;

  void _markDirty() => _dirty = true;

  void _flush() {
    if (!_dirty) return;
    _dirty = false;
    final b = _tBtn | _hBtn;
    final lt = _mergeTrig(_tLT, _hLT), rt = _mergeTrig(_tRT, _hRT);
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

  // ---- physical controller forwarding (Android keycodes / motion axes) ----
  void _onHwEvent(GamepadEvent e) {
    if (e.type == KeyType.button) {
      final bit = _hwButtonBits[e.key];
      final down = e.value > 0.5;
      if (bit != null) {
        _hBtn = down ? (_hBtn | bit) : (_hBtn & ~bit);
      } else if (e.key == '104') {
        _hLT = down ? 255 : 0; // L2 as a digital button
      } else if (e.key == '105') {
        _hRT = down ? 255 : 0; // R2 as a digital button
      }
    } else {
      _applyHwAxis(e.key, e.value);
    }
    if (_hwName.isEmpty) _hwName = 'Controller';
    _markDirty();
  }

  void _applyHwAxis(String key, double v) {
    int s16() => (v * 32767).round().clamp(-32768, 32767);
    int trig() => (v.clamp(0.0, 1.0) * 255).round();
    switch (key) {
      case '0': // AXIS_X
      case 'AXIS_X':
        _hLX = s16();
        break;
      case '1': // AXIS_Y
      case 'AXIS_Y':
        _hLY = -s16(); // device +y is down; stick +y is up
        break;
      case '11': // AXIS_Z
      case 'AXIS_Z':
        _hRX = s16();
        break;
      case '14': // AXIS_RZ
      case 'AXIS_RZ':
        _hRY = -s16();
        break;
      case '17': // AXIS_LTRIGGER
      case '23': // AXIS_BRAKE
      case 'AXIS_LTRIGGER':
      case 'AXIS_BRAKE':
        _hLT = trig();
        break;
      case '18': // AXIS_RTRIGGER
      case '22': // AXIS_GAS
      case 'AXIS_RTRIGGER':
      case 'AXIS_GAS':
        _hRT = trig();
        break;
      case '15': // AXIS_HAT_X (d-pad)
      case 'AXIS_HAT_X':
        _hBtn &= ~(_kLeft | _kRight);
        if (v < -0.5) _hBtn |= _kLeft;
        if (v > 0.5) _hBtn |= _kRight;
        break;
      case '16': // AXIS_HAT_Y (d-pad)
      case 'AXIS_HAT_Y':
        _hBtn &= ~(_kUp | _kDown);
        if (v < -0.5) _hBtn |= _kUp;
        if (v > 0.5) _hBtn |= _kDown;
        break;
    }
  }

  static const Map<String, int> _hwButtonBits = {
    '96': _kA, '97': _kB, '99': _kX, '100': _kY,
    '102': _kLB, '103': _kRB,
    '106': _kLS, '107': _kRS,
    '108': _kStart, '109': _kBack, '110': _kGuide,
    '19': _kUp, '20': _kDown, '21': _kLeft, '22': _kRight, // dpad keys
  };

  @override
  void dispose() {
    _tx?.cancel();
    _hwSub?.cancel();
    // Release everything and unplug so nothing stays "held" on the PC.
    widget.client.sendPad();
    widget.client.padDisconnect();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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
            const SizedBox(width: 10),
            IconButton(
              tooltip: 'Exit gamepad',
              icon: const Icon(Icons.close, color: Colors.white38),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 10),
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
      final stick = (c.maxWidth * 0.42).clamp(96.0, 150.0);
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
      final stick = (c.maxWidth * 0.42).clamp(96.0, 150.0);
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

/// 4-way d-pad as a cross of buttons.
class _DPad extends StatelessWidget {
  final void Function(int bit, bool down) onChanged;
  const _DPad({required this.onChanged});
  @override
  Widget build(BuildContext context) {
    Widget b(IconData icon, int bit) => _DirButton(icon: icon, onChanged: (d) => onChanged(bit, d));
    const sz = 150.0;
    return SizedBox(
      width: sz,
      height: sz,
      child: Stack(children: [
        Align(alignment: Alignment.topCenter, child: b(Icons.keyboard_arrow_up, _kUp)),
        Align(alignment: Alignment.bottomCenter, child: b(Icons.keyboard_arrow_down, _kDown)),
        Align(alignment: Alignment.centerLeft, child: b(Icons.keyboard_arrow_left, _kLeft)),
        Align(alignment: Alignment.centerRight, child: b(Icons.keyboard_arrow_right, _kRight)),
      ]),
    );
  }
}

class _DirButton extends StatefulWidget {
  final IconData icon;
  final ValueChanged<bool> onChanged;
  const _DirButton({required this.icon, required this.onChanged});
  @override
  State<_DirButton> createState() => _DirButtonState();
}

class _DirButtonState extends State<_DirButton> {
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
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _down ? _accent : const Color(0xFF2A313C),
        ),
        child: Icon(widget.icon, color: Colors.white, size: 30),
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
  final VoidCallback onRetry;
  final VoidCallback onBack;
  const _UnavailableMessage(
      {required this.error, required this.onRetry, required this.onBack});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.sports_esports_outlined,
              size: 56, color: Colors.white38),
          const SizedBox(height: 16),
          const Text('Gamepad driver not available',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'The PC needs the ViGEmBus virtual-controller driver. Re-run the '
            'JawnRemote installer and tick "Install virtual-gamepad driver", '
            'then reconnect.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          if (error.isNotEmpty) ...[
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
    );
  }
}
