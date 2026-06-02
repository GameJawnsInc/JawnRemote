import 'package:flutter/material.dart';
import '../app_scope.dart';
import '../services/file_transfer.dart';
import '../services/remote_client.dart';

/// Send files to the PC (they land in Downloads\JawnRemote) and save files the
/// PC pushes over. Everything stays on the local network.
class FilesScreen extends StatefulWidget {
  final RemoteClient client;
  const FilesScreen({super.key, required this.client});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  FileTransfer? _ft;

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _pickAndSend() async {
    final ft = _ft!;
    if (!widget.client.isConnected) {
      _snack('Not connected.');
      return;
    }
    if (ft.isSending) return;
    final picked = await ft.pickFile();
    if (picked == null) return;
    final path = picked['path'] as String?;
    final name = (picked['name'] as String?) ?? 'file';
    if (path == null) {
      _snack('Couldn\'t open that file.');
      return;
    }
    await ft.sendFile(path, name);
    if (!mounted) return;
    if (ft.txState == TxState.done) {
      _snack('Sent $name to the PC.');
    } else if (ft.txState == TxState.error) {
      _snack(ft.txError);
    }
  }

  Future<void> _save(IncomingFile f) async {
    final ok = await _ft!.saveReceived(f);
    _snack(ok ? 'Saved ${f.name}.' : 'Save canceled.');
  }

  Future<void> _open(IncomingFile f) async {
    final ok = await _ft!.openReceived(f);
    if (!ok) _snack('No app can open ${f.name}.');
  }

  @override
  Widget build(BuildContext context) {
    _ft ??= AppScope.of(context).fileTransfer;
    final ft = _ft!;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Files'),
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
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([ft, widget.client]),
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Send a file to your PC, or save one the PC sends you. '
                  'Files never leave your local network.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 18),
                _ActionCard(
                  icon: Icons.upload_file,
                  title: 'Send a file to PC',
                  subtitle:
                      'Pick any file — it lands in Downloads\\JawnRemote on the PC.',
                  onTap: _pickAndSend,
                ),
                if (ft.txState != TxState.idle) ...[
                  const SizedBox(height: 12),
                  _TransferCard(
                    icon: Icons.upload,
                    title: switch (ft.txState) {
                      TxState.sending => 'Sending ${ft.txName}',
                      TxState.done => 'Sent ${ft.txName}',
                      _ => 'Couldn\'t send ${ft.txName}',
                    },
                    progress: ft.txProgress,
                    active: ft.txState == TxState.sending,
                    error: ft.txState == TxState.error ? ft.txError : null,
                    onCancel:
                        ft.txState == TxState.sending ? ft.cancelOutgoing : null,
                    onDismiss:
                        ft.txState != TxState.sending ? ft.clearOutgoing : null,
                  ),
                ],
                if (ft.isReceiving) ...[
                  const SizedBox(height: 12),
                  _TransferCard(
                    icon: Icons.download,
                    title: 'Receiving ${ft.rxName}',
                    progress: ft.rxProgress,
                    active: true,
                  ),
                ],
                if (ft.received.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text('RECEIVED FROM PC',
                      style: TextStyle(
                          color: Color(0xFF4F8CFF),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0)),
                  const SizedBox(height: 8),
                  for (final f in ft.received)
                    _ReceivedTile(
                        file: f,
                        onOpen: () => _open(f),
                        onSave: () => _save(f)),
                ],
              ],
            );
          },
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
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
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

class _TransferCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final double progress;
  final bool active;
  final String? error;
  final VoidCallback? onCancel;
  final VoidCallback? onDismiss;
  const _TransferCard({
    required this.icon,
    required this.title,
    required this.progress,
    required this.active,
    this.error,
    this.onCancel,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161C24),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: const Color(0xFF4F8CFF), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (onCancel != null)
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
            if (onDismiss != null)
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
                color: Colors.white38,
                tooltip: 'Dismiss',
              ),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: active && progress == 0 ? null : progress,
              minHeight: 6,
              backgroundColor: const Color(0xFF0E1116),
              color: error != null
                  ? Colors.redAccent
                  : const Color(0xFF4F8CFF),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            error ?? '${(progress * 100).round()}%',
            style: TextStyle(
              color: error != null ? Colors.redAccent : Colors.white54,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceivedTile extends StatelessWidget {
  final IncomingFile file;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  const _ReceivedTile(
      {required this.file, required this.onOpen, required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161C24),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        const Icon(Icons.insert_drive_file_outlined, color: Color(0xFF4F8CFF)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
              Text(_humanSize(file.size),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
        IconButton(
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_new, size: 20),
          color: const Color(0xFF4F8CFF),
          tooltip: 'Open',
        ),
        IconButton(
          onPressed: onSave,
          icon: const Icon(Icons.save_alt, size: 20),
          color: const Color(0xFF4F8CFF),
          tooltip: 'Save',
        ),
      ]),
    );
  }
}

String _humanSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
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
