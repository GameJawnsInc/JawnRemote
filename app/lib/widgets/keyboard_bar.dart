import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/remote_client.dart';

/// Bottom keyboard panel: modifier toggles, special keys, and a text field
/// that captures typing (sent live to the PC).
class KeyboardBar extends StatefulWidget {
  final RemoteClient client;
  const KeyboardBar({super.key, required this.client});

  @override
  State<KeyboardBar> createState() => _KeyboardBarState();
}

class _KeyboardBarState extends State<KeyboardBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _prev = '';
  final Set<String> _mods = {};

  RemoteClient get c => widget.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Diff previous vs new text to find inserted text and deletions.
    final minLen = math.min(value.length, _prev.length);
    var cp = 0;
    while (cp < minLen && value[cp] == _prev[cp]) {
      cp++;
    }
    var cs = 0;
    while (cs < (minLen - cp) &&
        value[value.length - 1 - cs] == _prev[_prev.length - 1 - cs]) {
      cs++;
    }
    final removed = _prev.length - cp - cs;
    final inserted = value.substring(cp, value.length - cs);

    if (_mods.isNotEmpty &&
        removed == 0 &&
        inserted.length == 1 &&
        inserted != '\n') {
      // modifier shortcut, e.g. Ctrl+C
      c.key(inserted.toLowerCase(), _mods.toList());
      setState(_mods.clear);
    } else {
      for (var i = 0; i < removed; i++) {
        c.key('backspace');
      }
      if (inserted.isNotEmpty) {
        final parts = inserted.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) c.text(parts[i]);
          if (i < parts.length - 1) c.key('enter');
        }
      }
    }

    if (inserted.contains('\n') || value.length > 160) {
      _controller.clear();
      _prev = '';
    } else {
      _prev = value;
    }
  }

  void _special(String key) {
    c.key(key, _mods.toList());
    if (_mods.isNotEmpty) setState(_mods.clear);
    _focus.requestFocus();
  }

  /// Fire a fixed combo (e.g. Ctrl+C), independent of the sticky modifiers.
  void _combo(String key, List<String> mods) {
    c.key(key, mods);
    if (_mods.isNotEmpty) setState(_mods.clear);
    _focus.requestFocus();
  }

  void _toggleMod(String m) {
    setState(() {
      if (!_mods.add(m)) _mods.remove(m);
    });
    _focus.requestFocus();
  }

  Widget _modChip(String label, String m) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: ChoiceChip(
          label: Text(label),
          selected: _mods.contains(m),
          onSelected: (_) => _toggleMod(m),
        ),
      );

  Widget _btn(String label, String key, {double w = 50}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: SizedBox(
          width: w,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 10),
              foregroundColor: Colors.white,
            ),
            onPressed: () => _special(key),
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
        ),
      );

  /// A one-tap shortcut button (sends a fixed combo regardless of sticky mods).
  Widget _shortcut(String label, String key, List<String> mods) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => _combo(key, mods),
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      );

  Widget _scrollRow(List<Widget> children) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: children),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF11161D),
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Modifiers (sticky — tap one, then a key) + the two big standalones.
          _scrollRow([
            _modChip('Ctrl', 'ctrl'),
            _modChip('Alt', 'alt'),
            _modChip('Shift', 'shift'),
            _modChip('Win', 'win'),
            const SizedBox(width: 10),
            _btn('Esc', 'escape'),
            _btn('Tab', 'tab'),
          ]),
          const SizedBox(height: 6),
          // Function keys (respect the sticky modifiers, e.g. Alt+F4).
          _scrollRow([for (var i = 1; i <= 12; i++) _btn('F$i', 'f$i', w: 46)]),
          const SizedBox(height: 6),
          // Navigation + editing cluster.
          _scrollRow([
            _btn('←', 'left', w: 46),
            _btn('↑', 'up', w: 46),
            _btn('↓', 'down', w: 46),
            _btn('→', 'right', w: 46),
            const SizedBox(width: 10),
            _btn('Home', 'home', w: 58),
            _btn('End', 'end'),
            _btn('PgUp', 'pageup', w: 58),
            _btn('PgDn', 'pagedown', w: 58),
            const SizedBox(width: 10),
            _btn('Ins', 'insert'),
            _btn('Del', 'delete'),
            _btn('⌫', 'backspace', w: 46),
            _btn('⏎', 'enter', w: 46),
          ]),
          const SizedBox(height: 6),
          // One-tap shortcuts.
          _scrollRow([
            _shortcut('Copy', 'c', ['ctrl']),
            _shortcut('Cut', 'x', ['ctrl']),
            _shortcut('Paste', 'v', ['ctrl']),
            _shortcut('Undo', 'z', ['ctrl']),
            _shortcut('Redo', 'y', ['ctrl']),
            _shortcut('Select all', 'a', ['ctrl']),
            _shortcut('Alt+Tab', 'tab', ['alt']),
          ]),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'Type here — keys go to the PC',
                prefixIcon: Icon(Icons.keyboard_alt_outlined, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
