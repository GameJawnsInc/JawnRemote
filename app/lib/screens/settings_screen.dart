import 'package:flutter/material.dart';
import '../app_scope.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          children: [
            ListTile(
              title: const Text('Pointer speed'),
              subtitle: Slider(
                min: 0.4,
                max: 3.0,
                divisions: 26,
                value: s.sensitivity.clamp(0.4, 3.0),
                label: s.sensitivity.toStringAsFixed(1),
                onChanged: s.setSensitivity,
              ),
            ),
            ListTile(
              title: const Text('Scroll speed'),
              subtitle: Slider(
                min: 1,
                max: 15,
                divisions: 14,
                value: s.scrollSpeed.clamp(1, 15),
                label: s.scrollSpeed.toStringAsFixed(0),
                onChanged: s.setScrollSpeed,
              ),
            ),
            SwitchListTile(
              title: const Text('Natural scrolling'),
              subtitle: const Text('Content follows your fingers'),
              value: s.naturalScroll,
              onChanged: s.setNaturalScroll,
            ),
            SwitchListTile(
              title: const Text('Tap to click'),
              value: s.tapToClick,
              onChanged: s.setTapToClick,
            ),
            SwitchListTile(
              title: const Text('Keep screen on'),
              subtitle: const Text('While the remote is open'),
              value: s.keepScreenOn,
              onChanged: s.setKeepScreenOn,
            ),
            ListTile(
              title: const Text('Device name'),
              subtitle: Text(s.deviceName),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final ctrl = TextEditingController(text: s.deviceName);
                final v = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Device name'),
                    content: TextField(controller: ctrl, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, ctrl.text),
                          child: const Text('Save')),
                    ],
                  ),
                );
                if (v != null) s.setDeviceName(v);
              },
            ),
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'JawnRemote connects to the JawnRemote PC server over Wi-Fi.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
