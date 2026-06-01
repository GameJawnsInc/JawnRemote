import 'dart:async';
import 'package:flutter/material.dart';
import '../app_scope.dart';
import '../models/host.dart';
import '../services/remote_client.dart';
import '../services/hardware_volume.dart';
import '../widgets/trackpad.dart';
import '../widgets/keyboard_bar.dart';
import 'settings_screen.dart';

class RemoteScreen extends StatefulWidget {
  final RemoteHost host;
  const RemoteScreen({super.key, required this.host});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  bool _keyboard = false;
  bool _volume = false;
  bool _saved = false;
  bool _started = false;
  bool _intercepting = false;
  RemoteClient? _client;
  final HardwareVolume _hwVolume = HardwareVolume();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _client = AppScope.of(context).client;
  }

  @override
  void initState() {
    super.initState();
    // Hardware volume rocker -> PC volume (forwarded only while connected).
    _hwVolume.onVolume =
        (dir) => _client?.key(dir == 'up' ? 'volumeup' : 'volumedown');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_started || !mounted) return;
      _started = true;
      final scope = AppScope.of(context);
      scope.client.deviceName = scope.settings.deviceName;
      scope.client.connect(widget.host.ip, widget.host.port, widget.host.pin);
    });
  }

  @override
  void dispose() {
    _hwVolume.setIntercept(false); // restore normal volume-button behavior
    _hwVolume.onVolume = null;
    _client?.disconnect();
    super.dispose();
  }

  void _saveHostOnce(RemoteClient client) {
    if (_saved) return;
    _saved = true;
    final scope = AppScope.of(context);
    final name =
        client.serverName.isNotEmpty ? client.serverName : widget.host.name;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scope.settings.upsertHost(widget.host.copyWith(name: name));
    });
  }

  Future<void> _reenterPin(RemoteClient client) async {
    final ctrl = TextEditingController(text: widget.host.pin);
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter PIN'),
        content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
    if (pin != null) {
      client.connect(widget.host.ip, widget.host.port, pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final client = scope.client;
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        if (client.isConnected) _saveHostOnce(client);
        if (client.isConnected != _intercepting) {
          _intercepting = client.isConnected;
          _hwVolume.setIntercept(_intercepting); // capture rocker only while connected
        }
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              _StatusDot(client.state),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  client.isConnected && client.serverName.isNotEmpty
                      ? client.serverName
                      : widget.host.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            actions: [
              IconButton(
                tooltip: 'Volume',
                isSelected: _volume,
                icon: const Icon(Icons.volume_up),
                onPressed: () => setState(() => _volume = !_volume),
              ),
              IconButton(
                tooltip: 'Keyboard',
                icon: Icon(_keyboard ? Icons.keyboard_hide : Icons.keyboard),
                onPressed: () => setState(() => _keyboard = !_keyboard),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SettingsScreen())),
              ),
            ],
          ),
          body: _body(client, scope),
        );
      },
    );
  }

  Widget _body(RemoteClient client, AppScope scope) {
    switch (client.state) {
      case ConnState.connected:
        return Column(children: [
          Expanded(
            child: Trackpad(client: client, settings: scope.settings),
          ),
          if (_volume) _VolumeBar(client: client),
          _MouseButtons(client: client),
          if (_keyboard) KeyboardBar(client: client),
        ]);
      case ConnState.authFailed:
        return _Message(
          icon: Icons.lock_outline,
          title: 'Wrong PIN',
          detail:
              'The PIN didn\'t match. Check the number shown in the PC server window.',
          actionLabel: 'Re-enter PIN',
          onAction: () => _reenterPin(client),
        );
      case ConnState.error:
        return _Message(
          icon: Icons.error_outline,
          title: 'Can\'t connect',
          detail: client.lastError,
          actionLabel: 'Retry',
          onAction: () =>
              client.connect(widget.host.ip, widget.host.port, widget.host.pin),
        );
      default:
        return _Message(
          icon: Icons.wifi_tethering,
          title: 'Connecting…',
          detail: '${widget.host.ip}:${widget.host.port}',
          showSpinner: true,
        );
    }
  }
}

class _StatusDot extends StatelessWidget {
  final ConnState state;
  const _StatusDot(this.state);
  @override
  Widget build(BuildContext context) {
    Color col;
    switch (state) {
      case ConnState.connected:
        col = Colors.greenAccent;
        break;
      case ConnState.connecting:
        col = Colors.orangeAccent;
        break;
      case ConnState.authFailed:
      case ConnState.error:
        col = Colors.redAccent;
        break;
      default:
        col = Colors.grey;
    }
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(color: col, shape: BoxShape.circle),
    );
  }
}

class _MouseButtons extends StatelessWidget {
  final RemoteClient client;
  const _MouseButtons({required this.client});

  @override
  Widget build(BuildContext context) {
    Widget b(String label, String btn, int flex) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: 54,
              child: FilledButton.tonal(
                onPressed: () => client.click(btn),
                child: Text(label),
              ),
            ),
          ),
        );
    return Container(
      color: const Color(0xFF0E1116),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(children: [
        b('Left', 'left', 3),
        b('•', 'middle', 1),
        b('Right', 'right', 3),
      ]),
    );
  }
}

/// System-volume controls. Sends the media volume keys to the PC (the server
/// maps these to VK_VOLUME_*). Up/down repeat while held.
class _VolumeBar extends StatelessWidget {
  final RemoteClient client;
  const _VolumeBar({required this.client});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E1116),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: _HoldRepeatButton(
            icon: Icons.volume_down,
            onFire: () => client.key('volumedown'),
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: 54,
              child: FilledButton.tonal(
                onPressed: () => client.key('volumemute'),
                child: const Icon(Icons.volume_off, size: 24),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: _HoldRepeatButton(
            icon: Icons.volume_up,
            onFire: () => client.key('volumeup'),
          ),
        ),
      ]),
    );
  }
}

/// A tonal button that fires once on press and then repeats while held —
/// natural for nudging the volume.
class _HoldRepeatButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onFire;
  const _HoldRepeatButton({required this.icon, required this.onFire});
  @override
  State<_HoldRepeatButton> createState() => _HoldRepeatButtonState();
}

class _HoldRepeatButtonState extends State<_HoldRepeatButton> {
  Timer? _delay;
  Timer? _repeat;

  void _start() {
    widget.onFire(); // immediate step
    _delay?.cancel();
    _delay = Timer(const Duration(milliseconds: 350), () {
      _repeat?.cancel();
      _repeat = Timer.periodic(
          const Duration(milliseconds: 110), (_) => widget.onFire());
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 54,
        child: Listener(
          onPointerDown: (_) => _start(),
          onPointerUp: (_) => _stop(),
          onPointerCancel: (_) => _stop(),
          child: FilledButton.tonal(
            onPressed: () {}, // visual feedback only; firing handled above
            child: Icon(widget.icon, size: 26),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool showSpinner;
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner)
              const Padding(
                padding: EdgeInsets.only(bottom: 22),
                child: CircularProgressIndicator(),
              )
            else
              Icon(icon, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54)),
            if (actionLabel != null) ...[
              const SizedBox(height: 22),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
