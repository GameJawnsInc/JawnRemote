import 'package:flutter/material.dart';

/// Icon keywords offered for macro buttons, in editor order.
const List<String> kMacroIconKeys = [
  'bolt',
  'keyboard',
  'terminal',
  'mouse',
  'copy',
  'paste',
  'cut',
  'window',
  'settings',
  'power',
  'volume',
  'play',
  'folder',
  'web',
  'star',
  'app',
];

/// Maps a macro icon keyword to a Material icon.
IconData macroIcon(String key) {
  switch (key.toLowerCase()) {
    case 'bolt':
      return Icons.bolt;
    case 'keyboard':
      return Icons.keyboard;
    case 'terminal':
      return Icons.terminal;
    case 'mouse':
      return Icons.mouse;
    case 'copy':
      return Icons.content_copy;
    case 'paste':
      return Icons.content_paste;
    case 'cut':
      return Icons.content_cut;
    case 'window':
      return Icons.web_asset;
    case 'settings':
      return Icons.settings;
    case 'power':
      return Icons.power_settings_new;
    case 'volume':
      return Icons.volume_up;
    case 'play':
      return Icons.play_arrow;
    case 'folder':
      return Icons.folder;
    case 'web':
      return Icons.language;
    case 'star':
      return Icons.star;
    case 'app':
    default:
      return Icons.apps;
  }
}

/// Named colors offered in the macro editor, mapped to RRGGBB.
const Map<String, String> kMacroColors = {
  'Blue': '4F8CFF',
  'Red': 'FF3B30',
  'Orange': 'FF8800',
  'Green': '1DB954',
  'Cyan': '17B2E7',
  'Purple': '9146FF',
  'Pink': 'E5407A',
  'Grey': '8A94A6',
};

/// Parses an "RRGGBB" (or "#RRGGBB") hex string; falls back to the accent blue.
Color colorFromHex(String hex) {
  final h = hex.replaceAll('#', '').trim();
  final v = int.tryParse(h, radix: 16);
  if (v == null || h.length != 6) return const Color(0xFF4F8CFF);
  return Color(0xFF000000 | v);
}
