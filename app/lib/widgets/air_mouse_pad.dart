import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/remote_client.dart';
import '../services/settings.dart';

/// "Air mouse" — point the phone like a laser. While the button is held, the
/// gyroscope's angular velocity is turned into relative cursor moves (reusing
/// the same move() protocol as the trackpad — no server change). Releasing
/// freezes the cursor, which also neutralises gyro drift.
class AirMousePad extends StatefulWidget {
  final RemoteClient client;
  final Settings settings;
  const AirMousePad({super.key, required this.client, required this.settings});

  @override
  State<AirMousePad> createState() => _AirMousePadState();
}

class _AirMousePadState extends State<AirMousePad> {
  StreamSubscription<GyroscopeEvent>? _sub;
  bool _active = false;
  double _ax = 0, _ay = 0; // fractional remainder carried between sends

  void _start() {
    if (_active) return;
    _ax = _ay = 0;
    _sub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onGyro, onError: (_) {});
    setState(() => _active = true);
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (mounted && _active) setState(() => _active = false);
  }

  void _onGyro(GyroscopeEvent e) {
    if (!_active) return;
    final k = widget.settings.airSensitivity;
    // Phone upright (portrait), back pointed at the screen:
    //   yaw   (rotation about device Y) -> horizontal cursor
    //   pitch (rotation about device X) -> vertical cursor
    // Negated so it tracks like a laser pointer. Flip a sign here if a given
    // hold feels mirrored. Sample interval is ~constant (gameInterval), so dt
    // is folded into k rather than multiplied per-event.
    _ax += -e.y * k;
    _ay += -e.x * k;
    final dx = _ax.truncate();
    final dy = _ay.truncate();
    if (dx != 0 || dy != 0) {
      widget.client.move(dx, dy);
      _ax -= dx;
      _ay -= dy;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      color: const Color(0xFF151A21),
      width: double.infinity,
      child: Column(
        children: [
          const Spacer(),
          Icon(Icons.my_location,
              size: 46, color: _active ? accent : Colors.white24),
          const SizedBox(height: 12),
          Text(_active ? 'Pointing…' : 'Point the phone at the screen',
              style: TextStyle(
                  color: _active ? accent : Colors.white38, fontSize: 15)),
          const SizedBox(height: 26),
          // Listener (not GestureDetector) so a long hold can't be lost to the
          // gesture arena — pointer-down activates, pointer-up/cancel stops.
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _start(),
            onPointerUp: (_) => _stop(),
            onPointerCancel: (_) => _stop(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 22),
              decoration: BoxDecoration(
                color: _active ? accent : Colors.transparent,
                border: Border.all(color: accent, width: 2),
                borderRadius: BorderRadius.circular(40),
              ),
              child: Text(
                _active ? 'MOVING' : 'HOLD TO POINT',
                style: TextStyle(
                  color: _active ? const Color(0xFF0E1116) : accent,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.only(bottom: 16, left: 24, right: 24),
            child: Text(
              'Hold the button and aim the phone to move • use the buttons below to click',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
