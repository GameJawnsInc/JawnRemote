import 'dart:async';
import 'package:flutter/material.dart';
import '../app_scope.dart';
import '../models/host.dart';
import '../services/discovery.dart';
import '../services/wol.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final Map<String, DiscoveredServer> _discovered = {};
  final Map<String, DateTime> _seen = {}; // last reply per discovered key
  StreamSubscription<DiscoveredServer>? _sub;
  Timer? _pruneTimer;

  /// A PC that hasn't answered for this long (~3 probes) is dropped.
  static const _staleAfter = Duration(seconds: 7);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startDiscovery());
    _pruneTimer = Timer.periodic(
        const Duration(milliseconds: 2500), (_) => _pruneDiscovered());
  }

  void _startDiscovery() {
    final scope = AppScope.of(context);
    _sub ??= scope.discovery.stream.listen((srv) {
      if (!mounted) return;
      setState(() {
        _discovered[srv.key] = srv;
        _seen[srv.key] = DateTime.now();
      });
    });
    scope.discovery.start();
  }

  /// Forget PCs that stopped answering (shut down, changed IP).
  void _pruneDiscovered() {
    // Discovery is stopped while the remote is open, and nothing is shown
    // under a pushed screen or dialog — don't expire PCs meanwhile.
    if (!mounted || ModalRoute.isCurrentOf(context) != true) return;
    final cutoff = DateTime.now().subtract(_staleAfter);
    final stale = [
      for (final e in _seen.entries)
        if (e.value.isBefore(cutoff)) e.key
    ];
    if (stale.isEmpty) return;
    setState(() {
      for (final k in stale) {
        _seen.remove(k);
        _discovered.remove(k);
      }
    });
  }

  @override
  void dispose() {
    _pruneTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void _open(RemoteHost host) {
    final scope = AppScope.of(context);
    scope.discovery.stop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RemoteScreen(host: host)))
        .then((_) {
      if (mounted) {
        scope.discovery.start();
        // A fresh grace period, so PCs don't blink out before the first
        // reply to the restarted discovery.
        final now = DateTime.now();
        setState(() => _seen.updateAll((_, _) => now));
      }
    });
  }

  void _removeHost(RemoteHost h) {
    final settings = AppScope.of(context).settings;
    final index = settings.hosts.indexWhere((e) => e.key == h.key);
    settings.removeHost(h);
    // The PIN, name and learned MAC go with it, so make it undoable.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed ${h.name}'),
        behavior: SnackBarBehavior.floating,
        persist: false, // an action would otherwise keep it up for good
        action: SnackBarAction(
            label: 'Undo', onPressed: () => settings.insertHost(index, h)),
      ));
  }

  Future<void> _wake(RemoteHost h) async {
    final ok = await sendMagicPacket(h.mac, ip: h.ip);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Wake signal sent to ${h.name}. Give it a few seconds…'
          : 'Couldn\'t send the wake signal.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _addManually() async {
    final host = await showDialog<RemoteHost>(
      context: context,
      builder: (_) => const AddHostDialog(),
    );
    if (host != null && mounted) _open(host);
  }

  Future<void> _editHost(RemoteHost h) async {
    final edited = await showDialog<RemoteHost>(
      context: context,
      builder: (_) => AddHostDialog(initial: h),
    );
    if (edited != null && mounted) {
      AppScope.of(context).settings.replaceHost(h.key, edited);
    }
  }

  Future<void> _connectDiscovered(DiscoveredServer srv) async {
    final scope = AppScope.of(context);
    final matches = scope.settings.hosts.where((h) => h.ip == srv.ip);
    var pin = matches.isNotEmpty ? matches.first.pin : '';
    if (pin.isEmpty) {
      final entered = await _askPin(srv.name);
      if (entered == null) return;
      pin = entered;
    }
    if (!mounted) return;
    _open(RemoteHost(name: srv.name, ip: srv.ip, port: srv.port, pin: pin));
  }

  Future<String?> _askPin(String name) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PIN for $name'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Shown on the PC server'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.settings,
      builder: (context, _) {
        final saved = scope.settings.hosts;
        final savedIps = saved.map((h) => h.ip).toSet();
        final discovered =
            _discovered.values.where((d) => !savedIps.contains(d.ip)).toList();
        final anySavedOnline = saved.any((h) => _discovered.containsKey(h.key));
        return Scaffold(
          appBar: AppBar(
            title: const Text('JawnRemote'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SettingsScreen())),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addManually,
            icon: const Icon(Icons.add),
            label: const Text('Add PC'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (saved.isNotEmpty) const _Header('Saved'),
              if (saved.isNotEmpty)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: saved.length,
                  // ignore: deprecated_member_use  (onReorder's raw newIndex is what reorderHost expects)
                  onReorder: scope.settings.reorderHost,
                  itemBuilder: (context, i) {
                    final h = saved[i];
                    return _SavedTile(
                      key: ValueKey(h.key),
                      index: i,
                      host: h,
                      // Answering discovery right now (no reply doesn't mean
                      // off — UDP may just be blocked).
                      online: _discovered.containsKey(h.key),
                      onTap: () => _open(h),
                      onWake: h.mac.isNotEmpty ? () => _wake(h) : null,
                      onEdit: () => _editHost(h),
                      onDelete: () => _removeHost(h),
                    );
                  },
                ),
              const _Header('Discovered on Wi-Fi'),
              if (discovered.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Row(children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text(
                            anySavedOnline
                                ? 'Looking for other PCs…'
                                : 'Searching… make sure the PC server is running on the same Wi-Fi.',
                            style: const TextStyle(color: Colors.white54))),
                  ]),
                ),
              ...discovered.map((d) => _HostTile(
                    title: d.name,
                    subtitle: '${d.ip}:${d.port}',
                    icon: Icons.wifi,
                    onTap: () => _connectDiscovered(d),
                  )),
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Tip: if your PC isn\'t found automatically, tap "Add PC" and '
                  'type the IP address shown in the server window.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2)),
      );
}

class _HostTile extends StatelessWidget {
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onTap;
  const _HostTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _SavedTile extends StatelessWidget {
  final int index;
  final RemoteHost host;
  final bool online;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onWake;
  const _SavedTile({
    super.key,
    required this.index,
    required this.host,
    this.online = false,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.onWake,
  });

  PopupMenuItem<String> _item(String value, IconData icon, String label) =>
      PopupMenuItem<String>(
        value: value,
        child: Row(children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Badge(
          isLabelVisible: online,
          smallSize: 9,
          backgroundColor: Colors.greenAccent,
          child: const Icon(Icons.computer),
        ),
        title: Text(host.name),
        subtitle: Text('${online ? 'Online · ' : ''}${host.ip}:${host.port}'),
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<String>(
              tooltip: 'Options',
              onSelected: (v) {
                if (v == 'edit') {
                  onEdit();
                } else if (v == 'wake') {
                  onWake?.call();
                } else if (v == 'remove') {
                  onDelete();
                }
              },
              itemBuilder: (_) => [
                _item('edit', Icons.edit_outlined, 'Edit'),
                if (onWake != null)
                  _item('wake', Icons.power_settings_new, 'Wake PC'),
                _item('remove', Icons.delete_outline, 'Remove'),
              ],
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(left: 4, right: 8),
                child: Icon(Icons.drag_handle, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddHostDialog extends StatefulWidget {
  final RemoteHost? initial;
  const AddHostDialog({super.key, this.initial});
  @override
  State<AddHostDialog> createState() => _AddHostDialogState();
}

class _AddHostDialogState extends State<AddHostDialog> {
  late final TextEditingController _name;
  late final TextEditingController _ip;
  late final TextEditingController _port;
  late final TextEditingController _pin;
  String? _ipErr, _portErr;

  @override
  void initState() {
    super.initState();
    final h = widget.initial;
    _name = TextEditingController(text: h?.name ?? 'My PC');
    _ip = TextEditingController(text: h?.ip ?? '');
    _port = TextEditingController(text: (h?.port ?? 8770).toString());
    _pin = TextEditingController(text: h?.pin ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    final editing = widget.initial != null;
    var ip = _ip.text.trim();
    // A pasted "ip:port" goes into both fields. Only a single colon, so an
    // IPv6 literal is left alone.
    final colon = ip.indexOf(':');
    if (colon >= 0 && colon == ip.lastIndexOf(':')) {
      final p = int.tryParse(ip.substring(colon + 1).trim());
      if (p != null) {
        ip = ip.substring(0, colon).trim();
        _ip.text = ip;
        _port.text = '$p';
      }
    }
    final portText = _port.text.trim();
    final port = portText.isEmpty ? 8770 : int.tryParse(portText);
    setState(() {
      _ipErr = ip.isEmpty ? 'Enter the PC\'s IP address' : null;
      _portErr = (port == null || port < 1 || port > 65535)
          ? 'Port must be 1–65535'
          : null;
    });
    if (_ipErr != null || _portErr != null) return;
    final name = _name.text.trim();
    Navigator.pop(
      context,
      RemoteHost(
        name: name.isEmpty ? ip : name,
        ip: ip,
        port: port!,
        pin: _pin.text.trim(),
        mac: widget.initial?.mac ?? '',
        // Editing, or typing a name of your own, locks the name; the default
        // stays auto-upgradable to the server's hostname on connect.
        customName: editing || (name.isNotEmpty && name != 'My PC'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? 'Edit PC' : 'Add PC'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: _ip,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_ipErr != null) setState(() => _ipErr = null);
              },
              decoration: InputDecoration(
                  labelText: 'IP address',
                  hintText: 'e.g. 10.0.0.210',
                  errorText: _ipErr)),
          TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_portErr != null) setState(() => _portErr = null);
              },
              decoration:
                  InputDecoration(labelText: 'Port', errorText: _portErr)),
          TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                  labelText: 'PIN', hintText: 'shown on the PC server')),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          child: Text(editing ? 'Save' : 'Connect'),
        ),
      ],
    );
  }
}
