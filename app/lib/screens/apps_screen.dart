import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/remote_client.dart';

/// Quick-launch remote: tap to open a media service or app on the PC.
///
/// The list is configured on the PC (the server's "Manage apps" window) and
/// fetched over the connection. Older servers that don't support it return
/// nothing, so we fall back to a built-in default set. Tapping sends the
/// server's `launch` command; drive playback afterward with the trackpad +
/// Media controls.
class AppsScreen extends StatefulWidget {
  final RemoteClient client;
  const AppsScreen({super.key, required this.client});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  @override
  void initState() {
    super.initState();
    // Pull the PC-configured list; the handler updates serverApps + notifies.
    widget.client.requestApps();
  }

  void _open(_AppEntry app) {
    HapticFeedback.lightImpact();
    widget.client.launch(app.target);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Opening ${app.name} on the PC…'),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ));
  }

  List<_AppEntry> _entries() {
    final server = widget.client.serverApps;
    if (server.isEmpty) return _defaults;
    return server
        .map((m) => _AppEntry(
              (m['name'] ?? '').toString(),
              (m['target'] ?? '').toString(),
              _colorFromHex((m['color'] ?? '').toString()),
              _iconFor((m['icon'] ?? 'app').toString()),
            ))
        .where((e) => e.name.isNotEmpty && e.target.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Apps'),
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
          listenable: widget.client,
          builder: (context, _) {
            final entries = _entries();
            return GridView.builder(
              padding: const EdgeInsets.all(14),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemCount: entries.length,
              itemBuilder: (context, i) =>
                  _AppTile(app: entries[i], onTap: () => _open(entries[i])),
            );
          },
        ),
      ),
    );
  }
}

/// Maps the server's icon keyword to a Material icon.
IconData _iconFor(String key) {
  switch (key.toLowerCase()) {
    case 'play':
      return Icons.smart_display;
    case 'movie':
      return Icons.movie;
    case 'music':
      return Icons.music_note;
    case 'film':
      return Icons.theaters;
    case 'castle':
      return Icons.castle;
    case 'sparkle':
      return Icons.movie_filter;
    case 'tv':
      return Icons.live_tv;
    case 'game':
      return Icons.videogame_asset;
    case 'video':
      return Icons.ondemand_video;
    case 'web':
      return Icons.language;
    case 'folder':
      return Icons.folder;
    case 'star':
      return Icons.star;
    case 'app':
    default:
      return Icons.apps;
  }
}

/// Parses an "RRGGBB" (or "#RRGGBB") hex string; falls back to the accent blue.
Color _colorFromHex(String hex) {
  final h = hex.replaceAll('#', '').trim();
  final v = int.tryParse(h, radix: 16);
  if (v == null || h.length != 6) return const Color(0xFF4F8CFF);
  return Color(0xFF000000 | v);
}

/// Built-in fallback set, used when the server doesn't provide a list.
const List<_AppEntry> _defaults = [
  _AppEntry('YouTube', 'https://www.youtube.com', Color(0xFFFF0000),
      Icons.smart_display),
  _AppEntry('Netflix', 'https://www.netflix.com', Color(0xFFE50914), Icons.movie),
  _AppEntry('Spotify', 'https://open.spotify.com', Color(0xFF1DB954),
      Icons.music_note),
  _AppEntry('Prime Video', 'https://www.primevideo.com', Color(0xFF00A8E1),
      Icons.theaters),
  _AppEntry('Disney+', 'https://www.disneyplus.com', Color(0xFF113CCF),
      Icons.castle),
  _AppEntry('Max', 'https://play.max.com', Color(0xFF0046FF), Icons.movie_filter),
  _AppEntry('Hulu', 'https://www.hulu.com', Color(0xFF1CE783), Icons.live_tv),
  _AppEntry('Twitch', 'https://www.twitch.tv', Color(0xFF9146FF),
      Icons.videogame_asset),
  _AppEntry('VLC', 'vlc.exe', Color(0xFFFF8800), Icons.play_circle_fill),
  _AppEntry('Kodi', 'kodi.exe', Color(0xFF17B2E7), Icons.ondemand_video),
];

class _AppEntry {
  final String name;
  final String target;
  final Color color;
  final IconData icon;
  const _AppEntry(this.name, this.target, this.color, this.icon);
}

class _AppTile extends StatelessWidget {
  final _AppEntry app;
  final VoidCallback onTap;
  const _AppTile({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF161C24),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration:
                  BoxDecoration(color: app.color, shape: BoxShape.circle),
              child: Icon(app.icon, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                app.name,
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
