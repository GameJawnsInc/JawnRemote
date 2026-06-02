import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host.dart';
import '../models/macro.dart';

/// App settings + saved hosts, persisted with shared_preferences.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;

  double sensitivity = 1.4; // pointer speed multiplier
  double scrollSpeed = 6.0; // wheel units per logical pixel
  bool naturalScroll = false; // false = drag down scrolls page down
  bool tapToClick = true;
  bool keepScreenOn = true;
  String deviceName = 'Phone';
  List<RemoteHost> hosts = [];
  List<Macro> macros = [];
  Set<String> hiddenFeatures = {}; // feature-bar buttons the user hid

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    sensitivity = _p.getDouble('sensitivity') ?? 1.4;
    scrollSpeed = _p.getDouble('scrollSpeed') ?? 6.0;
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
    macros = (_p.getStringList('macros') ?? [])
        .map(Macro.decode)
        .whereType<Macro>()
        .toList();
    hiddenFeatures = (_p.getStringList('hiddenFeatures') ?? []).toSet();
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

  /// Update a saved host in place, or add a new one at the top. Preserves the
  /// user's manual order on reconnect (no bump-to-top).
  Future<void> upsertHost(RemoteHost h) async {
    final i = hosts.indexWhere((e) => e.key == h.key);
    if (i >= 0) {
      hosts[i] = h;
    } else {
      hosts.insert(0, h);
    }
    await _saveHosts();
  }

  /// Replace the host with [oldKey], keeping its position — used when editing a
  /// host whose ip/port (and therefore key) may have changed.
  Future<void> replaceHost(String oldKey, RemoteHost h) async {
    final i = hosts.indexWhere((e) => e.key == oldKey);
    if (i >= 0) {
      hosts[i] = h;
    } else {
      hosts.insert(0, h);
    }
    await _saveHosts();
  }

  /// Drag-to-reorder (ReorderableListView semantics for newIndex).
  Future<void> reorderHost(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= hosts.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final h = hosts.removeAt(oldIndex);
    hosts.insert(newIndex.clamp(0, hosts.length), h);
    await _saveHosts();
  }

  Future<void> removeHost(RemoteHost h) async {
    hosts.removeWhere((e) => e.key == h.key);
    await _saveHosts();
  }

  /// Replace the whole macro list (the editor manages add/edit/remove).
  Future<void> saveMacros(List<Macro> list) async {
    macros = list;
    await _p.setStringList('macros', macros.map((m) => m.encode()).toList());
    notifyListeners();
  }

  bool isFeatureVisible(String key) => !hiddenFeatures.contains(key);

  Future<void> setFeatureVisible(String key, bool visible) async {
    if (visible) {
      hiddenFeatures.remove(key);
    } else {
      hiddenFeatures.add(key);
    }
    await _p.setStringList('hiddenFeatures', hiddenFeatures.toList());
    notifyListeners();
  }
}
