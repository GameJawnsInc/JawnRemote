import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host.dart';

/// App settings + saved hosts, persisted with shared_preferences.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;

  double sensitivity = 1.4; // pointer speed multiplier
  double scrollSpeed = 6.0; // wheel units per logical pixel
  double airSensitivity = 60.0; // air-mouse: px per (rad/s) per sample
  bool naturalScroll = false; // false = drag down scrolls page down
  bool tapToClick = true;
  bool keepScreenOn = true;
  String deviceName = 'Phone';
  List<RemoteHost> hosts = [];

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    sensitivity = _p.getDouble('sensitivity') ?? 1.4;
    scrollSpeed = _p.getDouble('scrollSpeed') ?? 6.0;
    airSensitivity = _p.getDouble('airSensitivity') ?? 60.0;
    naturalScroll = _p.getBool('naturalScroll') ?? false;
    tapToClick = _p.getBool('tapToClick') ?? true;
    keepScreenOn = _p.getBool('keepScreenOn') ?? true;
    deviceName = _p.getString('deviceName') ?? 'Phone';
    final raw = _p.getStringList('hosts') ?? [];
    hosts = raw
        .map((s) {
          try {
            return RemoteHost.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<RemoteHost>()
        .toList();
    notifyListeners();
  }

  Future<void> setSensitivity(double v) async {
    sensitivity = v;
    await _p.setDouble('sensitivity', v);
    notifyListeners();
  }

  Future<void> setScrollSpeed(double v) async {
    scrollSpeed = v;
    await _p.setDouble('scrollSpeed', v);
    notifyListeners();
  }

  Future<void> setAirSensitivity(double v) async {
    airSensitivity = v;
    await _p.setDouble('airSensitivity', v);
    notifyListeners();
  }

  Future<void> setNaturalScroll(bool v) async {
    naturalScroll = v;
    await _p.setBool('naturalScroll', v);
    notifyListeners();
  }

  Future<void> setTapToClick(bool v) async {
    tapToClick = v;
    await _p.setBool('tapToClick', v);
    notifyListeners();
  }

  Future<void> setKeepScreenOn(bool v) async {
    keepScreenOn = v;
    await _p.setBool('keepScreenOn', v);
    notifyListeners();
  }

  Future<void> setDeviceName(String v) async {
    deviceName = v.trim().isEmpty ? 'Phone' : v.trim();
    await _p.setString('deviceName', deviceName);
    notifyListeners();
  }

  Future<void> _saveHosts() async {
    await _p.setStringList(
        'hosts', hosts.map((h) => jsonEncode(h.toJson())).toList());
    notifyListeners();
  }

  /// Add or update a host (most-recent first, deduped by ip:port).
  Future<void> upsertHost(RemoteHost h) async {
    hosts.removeWhere((e) => e.key == h.key);
    hosts.insert(0, h);
    await _saveHosts();
  }

  Future<void> removeHost(RemoteHost h) async {
    hosts.removeWhere((e) => e.key == h.key);
    await _saveHosts();
  }
}
