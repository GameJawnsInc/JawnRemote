import 'package:flutter/services.dart';

/// Bridges the phone's hardware volume rocker to the PC.
///
/// The native side (MainActivity) consumes the volume keys while capture is
/// enabled and calls `volumeUp` / `volumeDown` here; we forward those to
/// [onVolume]. Call [setIntercept] to turn capture on (while connected) or off
/// (so the buttons change the phone's own volume as usual). No-ops on platforms
/// without the native handler (e.g. iOS) — the on-screen buttons still work.
class HardwareVolume {
  static const _channel = MethodChannel('jawnremote/volume');

  /// Invoked with `'up'` or `'down'` when a hardware volume key is pressed
  /// while interception is enabled.
  void Function(String direction)? onVolume;

  HardwareVolume() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'volumeUp':
          onVolume?.call('up');
          break;
        case 'volumeDown':
          onVolume?.call('down');
          break;
      }
      return null;
    });
  }

  Future<void> setIntercept(bool enabled) async {
    try {
      await _channel.invokeMethod('setIntercept', enabled);
    } catch (_) {
      // Channel not available (non-Android / engine not ready): ignore.
    }
  }
}
