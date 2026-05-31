import 'dart:async';
import 'package:flutter/material.dart';
import '../app_scope.dart';
import '../models/host.dart';
import '../services/discovery.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';
import '../widgets/banner_ad.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final Map<String, DiscoveredServer> _discovered = {};
  StreamSubscription<DiscoveredServer>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startDiscovery());
  }

  void _startDiscovery() {
    final scope = AppScope.of(context);
    _sub ??= scope.discovery.stream.listen((srv) {
      if (!mounted) return;
      setState(() => _discovered[srv.key] = srv);
    });
    scope.discovery.start();
  }

  @override
  void dispose() {
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
        setState(() {});
      }
    });
  }

  Future<void> _addManually() async {
    final host = await showDialog<RemoteHost>(
      context: context,
      builder: (_) => const AddHostDialog(),
    );
    if (host != null && mounted) _open(host);
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
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Shown on the PC server'),
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
      listenable: Listenable.merge([scope.settings, scope.billing]),
      builder: (context, _) {
        final saved = scope.settings.hosts;
        final savedIps = saved.map((h) => h.ip).toSet();
        final discovered =
            _discovered.values.where((d) => !savedIps.contains(d.ip)).toList();
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
          bottomNavigationBar:
              scope.billing.isPro ? null : const BannerAdBar(),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (saved.isNotEmpty) const _Header('Saved'),
              ...saved.map((h) => _HostTile(
                    title: h.name,
                    subtitle: '${h.ip}:${h.port}',
                    icon: Icons.computer,
                    onTap: () => _open(h),
                    onDelete: () => scope.settings.removeHost(h),
                  )),
              const _Header('Discovered on Wi-Fi'),
              if (discovered.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Row(children: [
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 14),
                    Expanded(
                        child: Text(
                            'Searching… make sure the PC server is running on the same Wi-Fi.',
                            style: TextStyle(color: Colors.white54))),
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
  final VoidCallback? onDelete;
  const _HostTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: onDelete == null
            ? const Icon(Icons.chevron_right)
            : IconButton(
                icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        onTap: onTap,
      ),
    );
  }
}

class AddHostDialog extends StatefulWidget {
  const AddHostDialog({super.key});
  @override
  State<AddHostDialog> createState() => _AddHostDialogState();
}

class _AddHostDialogState extends State<AddHostDialog> {
  final _name = TextEditingController(text: 'My PC');
  final _ip = TextEditingController();
  final _port = TextEditingController(text: '8770');
  final _pin = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add PC'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: _ip,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'IP address', hintText: 'e.g. 10.0.0.210')),
          TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port')),
          TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'PIN', hintText: 'shown on the PC server')),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final ip = _ip.text.trim();
            if (ip.isEmpty) return;
            final port = int.tryParse(_port.text.trim()) ?? 8770;
            Navigator.pop(
              context,
              RemoteHost(
                name: _name.text.trim().isEmpty ? ip : _name.text.trim(),
                ip: ip,
                port: port,
                pin: _pin.text.trim(),
              ),
            );
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
