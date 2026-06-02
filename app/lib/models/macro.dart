import 'dart:convert';

/// One step in a macro: a key combo, typed text, an app/URL launch, or a pause.
class MacroStep {
  final String type; // 'key' | 'text' | 'launch' | 'delay'
  final String value; // key name / text / launch target / milliseconds
  final List<String> mods; // modifiers for a 'key' step: ctrl/alt/shift/win

  const MacroStep({required this.type, this.value = '', this.mods = const []});

  MacroStep copyWith({String? type, String? value, List<String>? mods}) =>
      MacroStep(
        type: type ?? this.type,
        value: value ?? this.value,
        mods: mods ?? this.mods,
      );

  Map<String, dynamic> toJson() => {'type': type, 'value': value, 'mods': mods};

  factory MacroStep.fromJson(Map<String, dynamic> j) => MacroStep(
        type: (j['type'] ?? 'key').toString(),
        value: (j['value'] ?? '').toString(),
        mods: ((j['mods'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  /// Short human-readable description for the editor's step list.
  String get summary {
    switch (type) {
      case 'key':
        final combo = [...mods.map(_cap), if (value.isNotEmpty) _cap(value)];
        return combo.isEmpty ? 'Key' : combo.join(' + ');
      case 'text':
        return 'Type  "$value"';
      case 'launch':
        return 'Launch  $value';
      case 'delay':
        return 'Wait  ${value.isEmpty ? '0' : value} ms';
      default:
        return type;
    }
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// A user-defined button: a label/icon/color and an ordered list of steps that
/// fire over the existing key/text/launch protocol when tapped.
class Macro {
  final String label;
  final String icon; // keyword (see widgets/macro_style.dart)
  final String color; // RRGGBB hex
  final List<MacroStep> steps;

  const Macro({
    required this.label,
    this.icon = 'bolt',
    this.color = '4F8CFF',
    this.steps = const [],
  });

  Macro copyWith({
    String? label,
    String? icon,
    String? color,
    List<MacroStep>? steps,
  }) =>
      Macro(
        label: label ?? this.label,
        icon: icon ?? this.icon,
        color: color ?? this.color,
        steps: steps ?? this.steps,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'icon': icon,
        'color': color,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory Macro.fromJson(Map<String, dynamic> j) => Macro(
        label: (j['label'] ?? '').toString(),
        icon: (j['icon'] ?? 'bolt').toString(),
        color: (j['color'] ?? '4F8CFF').toString(),
        steps: ((j['steps'] as List?) ?? const [])
            .map((e) => MacroStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  String encode() => jsonEncode(toJson());

  static Macro? decode(String s) {
    try {
      return Macro.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
