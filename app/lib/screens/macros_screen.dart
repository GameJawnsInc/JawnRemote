import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_scope.dart';
import '../models/macro.dart';
import '../services/remote_client.dart';
import '../services/settings.dart';
import '../widgets/macro_style.dart';
import 'macro_editor_screen.dart';

/// Custom buttons & macros: user-defined buttons that fire a sequence of
/// keystrokes, text, app launches and pauses over the existing protocol.
/// Stored on the phone (per-device). Tap to run, long-press to edit.
class MacrosScreen extends StatefulWidget {
  final RemoteClient client;
  const MacrosScreen({super.key, required this.client});

  @override
  State<MacrosScreen> createState() => _MacrosScreenState();
}

class _MacrosScreenState extends State<MacrosScreen> {
  Settings get _settings => AppScope.of(context).settings;

  Future<void> _run(Macro m) async {
    if (!widget.client.isConnected) {
      _snack('Not connected to a PC.');
      return;
    }
    HapticFeedback.lightImpact();
    _snack('Running ${m.label}…');
    await runMacro(widget.client, m);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _add() async {
    final m = await Navigator.of(context).push<Macro>(MaterialPageRoute(
        builder: (_) => const MacroEditorScreen(initial: null)));
    if (m != null) await _settings.saveMacros([..._settings.macros, m]);
  }

  Future<void> _edit(int i) async {
    final m = await Navigator.of(context).push<Macro>(MaterialPageRoute(
        builder: (_) => MacroEditorScreen(initial: _settings.macros[i])));
    if (m != null) {
      final list = [..._settings.macros];
      list[i] = m;
      await _settings.saveMacros(list);
    }
  }

  Future<void> _delete(int i) async {
    final list = [..._settings.macros]..removeAt(i);
    await _settings.saveMacros(list);
  }

  void _longPress(int i) {
    final m = _settings.macros[i];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text('Edit "${m.label}"'),
            onTap: () {
              Navigator.pop(ctx);
              _edit(i);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () {
              Navigator.pop(ctx);
              _delete(i);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Macros'),
        actions: [
          ListenableBuilder(
            listenable: widget.client,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Center(child: _Dot(connected: widget.client.isConnected)),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _settings,
          builder: (context, _) {
            final macros = _settings.macros;
            if (macros.isEmpty) return const _Empty();
            return Column(children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Tap to run · long-press to edit',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 90),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  itemCount: macros.length,
                  itemBuilder: (context, i) => _MacroTile(
                    macro: macros[i],
                    onTap: () => _run(macros[i]),
                    onLongPress: () => _longPress(i),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Runs a macro's steps in order over the live connection.
Future<void> runMacro(RemoteClient client, Macro m) async {
  for (final s in m.steps) {
    switch (s.type) {
      case 'key':
        if (s.value.isNotEmpty) client.key(s.value, s.mods);
        break;
      case 'text':
        if (s.value.isNotEmpty) client.text(s.value);
        break;
      case 'launch':
        if (s.value.isNotEmpty) client.launch(s.value);
        break;
      case 'delay':
        await Future.delayed(
            Duration(milliseconds: int.tryParse(s.value) ?? 100));
        continue; // skip the default inter-step pacing
    }
    await Future.delayed(const Duration(milliseconds: 70));
  }
}

class _MacroTile extends StatelessWidget {
  final Macro macro;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _MacroTile({
    required this.macro,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF161C24),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                  color: colorFromHex(macro.color), shape: BoxShape.circle),
              child: Icon(macroIcon(macro.icon), color: Colors.white, size: 28),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                macro.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, size: 56, color: Colors.white24),
            SizedBox(height: 16),
            Text('No buttons yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
              'Tap "New" to make a button that fires a shortcut (e.g. Ctrl+Shift+Esc), types text, or launches an app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final bool connected;
  const _Dot({required this.connected});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: connected ? Colors.greenAccent : Colors.orangeAccent,
        shape: BoxShape.circle,
      ),
    );
  }
}
