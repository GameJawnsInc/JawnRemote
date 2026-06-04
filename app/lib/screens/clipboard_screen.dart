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

  /// Quick View: pull a one-off screenshot of the PC and open it in a
  /// pinch-to-zoom viewer. Nothing is saved — the bytes live only in memory.
  Future<void> _quickView() async {
    final client = widget.client;
    if (!client.isConnected) {
      _snack('Not connected.');
      return;
    }
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Uint8List? png;
    String? err;
    try {
      png = await client.requestShot();
    } catch (e) {
      err = e.toString();
    }
    if (!mounted) return;
    nav.pop(); // dismiss the loading spinner
    if (png == null) {
      _snack(err ?? 'Couldn\'t capture the screen.');
      return;
    }
    final bytes = png;
    nav.push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ScreenViewer(client: client, png: bytes),
    ));
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
            const SizedBox(height: 24),
            const Text('SCREEN',
                style: TextStyle(
                    color: Color(0xFF4F8CFF),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            _ActionCard(
              icon: Icons.screenshot_monitor,
              title: 'Quick View',
              subtitle: 'Peek at the PC screen — pinch to zoom. Nothing saved.',
              onTap: _quickView,
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

/// Full-screen, pinch-to-zoom view of a one-off PC screenshot. The bytes are
/// held only in memory; closing the screen drops them. Refresh re-captures.
class _ScreenViewer extends StatefulWidget {
  final RemoteClient client;
  final Uint8List png;
  const _ScreenViewer({required this.client, required this.png});

  @override
  State<_ScreenViewer> createState() => _ScreenViewerState();
}

class _ScreenViewerState extends State<_ScreenViewer> {
  late Uint8List _png = widget.png;
  bool _busy = false;

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final p = await widget.client.requestShot();
      if (mounted) setState(() => _png = p);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
              content: Text(e.toString()),
              behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Quick View'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refresh,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 1,
        maxScale: 10,
        child: SizedBox.expand(
          child: Image.memory(
            _png,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
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
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: connected ? Colors.greenAccent : Colors.orangeAccent,
          shape: BoxShape.circle,
        ),
      );
}
