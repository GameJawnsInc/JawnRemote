import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/remote_client.dart';
import '../services/settings.dart';

/// The touch surface. Translates touch gestures into mouse events:
///  - one finger drag  -> move cursor
///  - one finger tap    -> left click
///  - two finger tap    -> right click
///  - three finger tap  -> middle click
///  - two finger drag   -> scroll
///  - double-tap + drag -> hold left button and drag (selection)
class Trackpad extends StatefulWidget {
  final RemoteClient client;
  final Settings settings;
  const Trackpad({super.key, required this.client, required this.settings});

  @override
  State<Trackpad> createState() => _TrackpadState();
}

class _TrackpadState extends State<Trackpad> {
  final Map<int, Offset> _positions = {};
  int _maxPointers = 0;
  double _moved = 0;
  int? _gestureStartMs;
  bool _dragging = false;
  bool _armDrag = false;
  int? _lastTapUpMs;
  Offset? _lastCentroid;
  double _ax = 0, _ay = 0, _scrollY = 0, _scrollX = 0;
  bool _touching = false;

  RemoteClient get c => widget.client;
  Settings get s => widget.settings;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  Offset _centroid() {
    double x = 0, y = 0;
    for (final p in _positions.values) {
      x += p.dx;
      y += p.dy;
    }
    final n = _positions.length;
    return n == 0 ? Offset.zero : Offset(x / n, y / n);
  }

  void _down(PointerDownEvent e) {
    _positions[e.pointer] = e.position;
    _maxPointers = math.max(_maxPointers, _positions.length);
    if (_positions.length == 1) {
      _gestureStartMs = _now;
      _moved = 0;
      if (_lastTapUpMs != null && _now - _lastTapUpMs! < 320) _armDrag = true;
    }
    if (_positions.length >= 2) _lastCentroid = _centroid();
    if (!_touching) setState(() => _touching = true);
  }

  void _move(PointerMoveEvent e) {
    if (!_positions.containsKey(e.pointer)) return;
    _positions[e.pointer] = e.position;
    if (_positions.length >= 2) {
      final cen = _centroid();
      if (_lastCentroid != null) {
        final d = cen - _lastCentroid!;
        _moved += d.distance;
        _handleScroll(d);
      }
      _lastCentroid = cen;
    } else if (_maxPointers == 1) {
      final d = e.delta;
      _moved += d.distance;
      if (_armDrag && !_dragging && _moved > 8) {
        _dragging = true;
        _armDrag = false;
        c.mouseDown('left');
      }
      _handleMove(d);
    }
  }

  void _endPointer(int pointer) {
    _positions.remove(pointer);
    if (_positions.length < 2) _lastCentroid = null;
    if (_positions.isEmpty) _finish();
  }

  void _finish() {
    final dur = _gestureStartMs == null ? 9999 : _now - _gestureStartMs!;
    if (_dragging) {
      c.mouseUp('left');
      _dragging = false;
    } else if (_moved < 12 && dur < 300) {
      if (_maxPointers == 1) {
        if (s.tapToClick) {
          c.click('left');
          _lastTapUpMs = _now;
        }
      } else if (_maxPointers == 2) {
        c.click('right');
      } else if (_maxPointers >= 3) {
        c.click('middle');
      }
    }
    _maxPointers = 0;
    _moved = 0;
    _armDrag = false;
    _gestureStartMs = null;
    _ax = _ay = _scrollY = _scrollX = 0;
    if (mounted && _touching) setState(() => _touching = false);
  }

  void _handleMove(Offset d) {
    final sens = s.sensitivity;
    var accel = 1.0 + d.distance * 0.03;
    if (accel > 2.5) accel = 2.5;
    _ax += d.dx * sens * accel;
    _ay += d.dy * sens * accel;
    final sx = _ax.truncate();
    final sy = _ay.truncate();
    if (sx != 0 || sy != 0) {
      c.move(sx, sy);
      _ax -= sx;
      _ay -= sy;
    }
  }

  void _handleScroll(Offset d) {
    final k = s.scrollSpeed;
    final dir = s.naturalScroll ? 1.0 : -1.0;
    _scrollY += d.dy * k * dir;
    _scrollX += d.dx * k * dir;
    final wy = _scrollY.truncate();
    final wx = _scrollX.truncate();
    if (wy != 0 || wx != 0) {
      c.scroll(wy, wx);
      _scrollY -= wy;
      _scrollX -= wx;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _endPointer(e.pointer),
      onPointerCancel: (e) => _endPointer(e.pointer),
      child: Container(
        color: const Color(0xFF151A21),
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: AnimatedOpacity(
            opacity: _touching ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.touch_app_outlined, size: 46, color: Colors.white24),
                SizedBox(height: 12),
                Text('Drag to move  •  Tap to click',
                    style: TextStyle(color: Colors.white38)),
                SizedBox(height: 4),
                Text('Two fingers: right-click or scroll',
                    style: TextStyle(color: Colors.white24, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
