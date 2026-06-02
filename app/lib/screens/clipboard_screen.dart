import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/remote_client.dart';

/// Clipboard sync: push the phone's clipboard onto the PC, or pull the PC's
/// clipboard onto the phone. Uses the server's clipset/clipget commands; stays
/// entirely on the local network.
class ClipboardScreen extends StatefulWidget {
  final RemoteClient client;
  const ClipboardScreen({super.key, required this.client});

  @override
  State<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends State<ClipboardScreen> {
  bool _awaiting = false;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    super.dispose();
  }

  void _onClient() {
    if (!mounted) return;
    if (_awaiting) {
      _awaiting = false;
      final text = widget.client.pcClipboard;
      Clipboard.setData(ClipboardData(text: text));
      _snack(text.isEmpty
          ? 'The PC clipboard is empty.'
          : 'Copied the PC clipboard to your phone.');
    }
    setState(() {});
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _sendToPc() async {
    if (!widget.client.isConnected) {
      _snack('Not connected.');
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      _snack('Your phone clipboard is empty.');
      return;
    }
    widget.client.sendClipboard(text);
    _snack('Sent to the PC clipboard.');
  }

  void _getFromPc() {
    if (!widget.client.isConnected) {
      _snack('Not connected.');
      return;
    }
    _awaiting = true;
    widget.client.requestClipboard();
  }

  @override
  Widget build(BuildContext context) {
    final pc = widget.client.pcClipboard;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Clipboard'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(child: _Dot(connected: widget.client.isConnected)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Move text between your phone and PC. Nothing leaves your network.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 18),
            _ActionCard(
              icon: Icons.upload,
              title: 'Send to PC',
              subtitle: 'Put your phone\'s copied text on the PC clipboard.',
              onTap: _sendToPc,
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Icons.download,
              title: 'Get from PC',
              subtitle: 'Pull the PC clipboard onto your phone.',
              onTap: _getFromPc,
            ),
            const SizedBox(height: 24),
            const Text('PC CLIPBOARD',
                style: TextStyle(
                    color: Color(0xFF4F8CFF),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 80),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161C24),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                pc.isEmpty ? '(tap "Get from PC" to fetch)' : pc,
                style: TextStyle(
                  color: pc.isEmpty ? Colors.white38 : Colors.white,
                  fontStyle: pc.isEmpty ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF161C24),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(icon, color: const Color(0xFF4F8CFF), size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ]),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final bool connected;
  const _Dot({required this.connected});
  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: connected ? Colors.greenAccent : Colors.orangeAccent,
          shape: BoxShape.circle,
        ),
      );
}
