import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/remote_client.dart';

/// Dedicated presenter remote. Everything here is a plain key event the PC
/// server already understands (PageUp/PageDown, F5, Esc, Home/End, B/W) — these
/// are the shortcuts PowerPoint, Google Slides, Keynote and PDF viewers share,
/// and what hardware presenter remotes send. Big tap targets + haptics so you
/// can drive a deck without looking at the phone.
class PresentationScreen extends StatelessWidget {
  final RemoteClient client;
  const PresentationScreen({super.key, required this.client});

  void _send(String key) {
    HapticFeedback.lightImpact();
    client.key(key);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Presentation'),
        actions: [
          ListenableBuilder(
            listenable: client,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Center(child: _Dot(connected: client.isConnected)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Slideshow controls.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(children: [
                _SmallCtl(
                    icon: Icons.play_arrow,
                    label: 'Start',
                    onTap: () => _send('f5')),
                _SmallCtl(
                    icon: Icons.brightness_1,
                    label: 'Black',
                    onTap: () => _send('b')),
                _SmallCtl(
                    icon: Icons.brightness_high,
                    label: 'White',
                    onTap: () => _send('w')),
                _SmallCtl(
                    icon: Icons.close,
                    label: 'End',
                    onTap: () => _send('escape')),
              ]),
            ),
            // The main event: huge prev / next slide targets.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(
                    child: _BigNav(
                      icon: Icons.chevron_left,
                      label: 'Prev',
                      onTap: () => _send('pageup'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _BigNav(
                      icon: Icons.chevron_right,
                      label: 'Next',
                      primary: true,
                      onTap: () => _send('pagedown'),
                    ),
                  ),
                ]),
              ),
            ),
            // Jump to the ends of the deck.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(children: [
                _SmallCtl(
                    icon: Icons.first_page,
                    label: 'First',
                    onTap: () => _send('home')),
                _SmallCtl(
                    icon: Icons.last_page,
                    label: 'Last',
                    onTap: () => _send('end')),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Large full-height slide-advance button.
class _BigNav extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _BigNav({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
    final child = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 76),
        const SizedBox(height: 6),
        Text(label,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ],
    );
    return SizedBox.expand(
      child: primary
          ? FilledButton(onPressed: onTap, style: style, child: child)
          : FilledButton.tonal(onPressed: onTap, style: style, child: child),
    );
  }
}

/// Compact labelled control used for the secondary rows.
class _SmallCtl extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallCtl(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          height: 62,
          child: FilledButton.tonal(
            onPressed: onTap,
            style: FilledButton.styleFrom(padding: EdgeInsets.zero),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22),
                const SizedBox(height: 3),
                Text(label, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
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
