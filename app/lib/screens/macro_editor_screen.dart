import 'package:flutter/material.dart';
import '../models/macro.dart';
import '../widgets/macro_style.dart';

/// Create or edit one custom button (a macro = label/icon/color + ordered
/// steps). Returns the [Macro] via Navigator.pop, or null if cancelled.
class MacroEditorScreen extends StatefulWidget {
  final Macro? initial;
  const MacroEditorScreen({super.key, required this.initial});

  @override
  State<MacroEditorScreen> createState() => _MacroEditorScreenState();
}

class _MacroEditorScreenState extends State<MacroEditorScreen> {
  late final TextEditingController _label;
  late String _icon;
  late String _color; // hex
  late List<MacroStep> _steps;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    _label = TextEditingController(text: m?.label ?? '');
    _icon = m?.icon ?? 'bolt';
    _color = m?.color ?? '4F8CFF';
    _steps = [...(m?.steps ?? const <MacroStep>[])];
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _warn(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _save() {
    final label = _label.text.trim();
    if (label.isEmpty) return _warn('Give the button a name.');
    if (_steps.isEmpty) return _warn('Add at least one step.');
    Navigator.of(context)
        .pop(Macro(label: label, icon: _icon, color: _color, steps: _steps));
  }

  Future<void> _addStep() async {
    final s = await showModalBottomSheet<MacroStep>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _StepSheet(initial: null),
    );
    if (s != null) setState(() => _steps.add(s));
  }

  Future<void> _editStep(int i) async {
    final s = await showModalBottomSheet<MacroStep>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StepSheet(initial: _steps[i]),
    );
    if (s != null) setState(() => _steps[i] = s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'New button' : 'Edit button'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Task Manager',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
                child: _IconPicker(
                    value: _icon,
                    color: colorFromHex(_color),
                    onChanged: (v) => setState(() => _icon = v))),
            const SizedBox(width: 12),
            Expanded(
                child: _ColorPicker(
                    value: _color,
                    onChanged: (v) => setState(() => _color = v))),
          ]),
          const SizedBox(height: 22),
          Row(children: [
            const Text('Steps',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
                onPressed: _addStep,
                icon: const Icon(Icons.add),
                label: const Text('Add step')),
          ]),
          if (_steps.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No steps yet. A button can press a shortcut (e.g. Ctrl+Shift+Esc), type text, launch an app, or wait between steps.',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ..._steps.asMap().entries.map((e) {
            final i = e.key;
            final s = e.value;
            return Card(
              color: const Color(0xFF161C24),
              child: ListTile(
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF2A3340),
                  child: Text('${i + 1}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white)),
                ),
                title: Text(s.summary),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editStep(i)),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _steps.removeAt(i))),
                ]),
                onTap: () => _editStep(i),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _IconPicker extends StatelessWidget {
  final String value;
  final Color color;
  final ValueChanged<String> onChanged;
  const _IconPicker(
      {required this.value, required this.color, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
          labelText: 'Icon', border: OutlineInputBorder()),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: kMacroIconKeys.contains(value) ? value : 'bolt',
          isExpanded: true,
          items: kMacroIconKeys
              .map((k) => DropdownMenuItem(
                    value: k,
                    child: Row(children: [
                      Icon(macroIcon(k), size: 20, color: color),
                      const SizedBox(width: 10),
                      Text(k),
                    ]),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _ColorPicker extends StatelessWidget {
  final String value; // hex
  final ValueChanged<String> onChanged;
  const _ColorPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final current = kMacroColors.entries.firstWhere(
      (e) => e.value.toUpperCase() == value.toUpperCase(),
      orElse: () => const MapEntry('Blue', '4F8CFF'),
    );
    return InputDecorator(
      decoration: const InputDecoration(
          labelText: 'Color', border: OutlineInputBorder()),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current.key,
          isExpanded: true,
          items: kMacroColors.entries
              .map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Row(children: [
                      Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                              color: colorFromHex(e.value),
                              shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Text(e.key),
                    ]),
                  ))
              .toList(),
          onChanged: (k) {
            if (k != null) onChanged(kMacroColors[k]!);
          },
        ),
      ),
    );
  }
}

/// Bottom sheet to add/edit one step. Returns a [MacroStep] or null.
class _StepSheet extends StatefulWidget {
  final MacroStep? initial;
  const _StepSheet({required this.initial});

  @override
  State<_StepSheet> createState() => _StepSheetState();
}

class _StepSheetState extends State<_StepSheet> {
  late String _type;
  final _key = TextEditingController();
  final _text = TextEditingController();
  final _launch = TextEditingController();
  final _delay = TextEditingController(text: '200');
  final Set<String> _mods = {};

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _type = s?.type ?? 'key';
    if (s != null) {
      switch (s.type) {
        case 'key':
          _key.text = s.value;
          _mods.addAll(s.mods);
          break;
        case 'text':
          _text.text = s.value;
          break;
        case 'launch':
          _launch.text = s.value;
          break;
        case 'delay':
          _delay.text = s.value.isEmpty ? '200' : s.value;
          break;
      }
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _text.dispose();
    _launch.dispose();
    _delay.dispose();
    super.dispose();
  }

  void _warn(String m) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  void _done() {
    MacroStep step;
    switch (_type) {
      case 'text':
        if (_text.text.isEmpty) return _warn('Enter some text.');
        step = MacroStep(type: 'text', value: _text.text);
        break;
      case 'launch':
        if (_launch.text.trim().isEmpty) return _warn('Enter an app or URL.');
        step = MacroStep(type: 'launch', value: _launch.text.trim());
        break;
      case 'delay':
        step = MacroStep(
            type: 'delay',
            value: (int.tryParse(_delay.text.trim()) ?? 200).toString());
        break;
      case 'key':
      default:
        if (_key.text.trim().isEmpty) {
          return _warn('Enter a key (e.g. c, f4, enter).');
        }
        step = MacroStep(
            type: 'key',
            value: _key.text.trim().toLowerCase(),
            mods: _mods.toList());
        break;
    }
    Navigator.of(context).pop(step);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'key',
                  label: Text('Key'),
                  icon: Icon(Icons.keyboard)),
              ButtonSegment(
                  value: 'text',
                  label: Text('Text'),
                  icon: Icon(Icons.text_fields)),
              ButtonSegment(
                  value: 'launch',
                  label: Text('Launch'),
                  icon: Icon(Icons.open_in_new)),
              ButtonSegment(
                  value: 'delay',
                  label: Text('Wait'),
                  icon: Icon(Icons.timer_outlined)),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 16),
          ..._fields(),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            const Spacer(),
            FilledButton(onPressed: _done, child: const Text('Done')),
          ]),
        ],
      ),
    );
  }

  List<Widget> _fields() {
    switch (_type) {
      case 'text':
        return [
          TextField(
            controller: _text,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Text to type', border: OutlineInputBorder()),
          ),
        ];
      case 'launch':
        return [
          TextField(
            controller: _launch,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'App or URL',
                hintText: 'https://…  or  vlc.exe',
                border: OutlineInputBorder()),
          ),
        ];
      case 'delay':
        return [
          TextField(
            controller: _delay,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Milliseconds', border: OutlineInputBorder()),
          ),
        ];
      case 'key':
      default:
        return [
          Wrap(
            spacing: 8,
            children: const ['ctrl', 'alt', 'shift', 'win']
                .map((m) => FilterChip(
                      label: Text(_modLabel(m)),
                      selected: _mods.contains(m),
                      onSelected: (sel) => setState(
                          () => sel ? _mods.add(m) : _mods.remove(m)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Key',
                hintText: 'c, f4, enter, esc, tab, up, delete…',
                border: OutlineInputBorder()),
          ),
        ];
    }
  }

  static String _modLabel(String m) =>
      const {'ctrl': 'Ctrl', 'alt': 'Alt', 'shift': 'Shift', 'win': 'Win'}[m] ??
      m;
}
