import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/remote_client.dart';

/// Quick-launch remote: tap to open a media service or app on the PC. The
/// server's `launch` command opens whatever target we send (a web URL, a
/// protocol URI, or an app registered on the PC), so this curated list can grow
/// in an app update without anyone reinstalling the PC server.
///
/// Streaming services open as web URLs (always available); local players open
/// by executable name (works if installed). After launching, drive playback
/// with the trackpad and the Media controls.
class AppsScreen extends StatelessWidget {
  final RemoteClient client;
  const AppsScreen({super.key, required this.client});

  static const List<_AppEntry> _apps = [
    _AppEntry('YouTube', 'https://www.youtube.com', Color(0xFFFF0000),
        Icons.smart_display),
    _AppEntry(
        'Netflix', 'https://www.netflix.com', Color(0xFFE50914), Icons.movie),
    _AppEntry('Spotify', 'https://open.spotify.com', Color(0xFF1DB954),
        Icons.music_note),
    _AppEntry('Prime Video', 'https://www.primevideo.com', Color(0xFF00A8E1),
        Icons.theaters),
    _AppEntry('Disney+', 'https://www.disneyplus.com', Color(0xFF113CCF),
        Icons.castle),
    _AppEntry('Max', 'https://play.max.com', Color(0xFF0046FF),
        Icons.movie_filter),
    _AppEntry('Hulu', 'https://www.hulu.com', Color(0xFF1CE783), Icons.live_tv),
    _AppEntry('Twitch', 'https://www.twitch.tv', Color(0xFF9146FF),
        Icons.videogame_asset),
    _AppEntry('VLC', 'vlc.exe', Color(0xFFFF8800), Icons.play_circle_fill),
    _AppEntry('Kodi', 'kodi.exe', Color(0xFF17B2E7), Icons.ondemand_video),
  ];

  void _open(BuildContext context, _AppEntry app) {
    HapticFeedback.lightImpact();
    client.launch(app.target);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Opening ${app.name} on the PC…'),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(
        title: const Text('Apps'),
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
        child: GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 130,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.92,
          ),
          itemCount: _apps.length,
          itemBuilder: (context, i) {
            final app = _apps[i];
            return _AppTile(app: app, onTap: () => _open(context, app));
          },
        ),
      ),
    );
  }
}

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
              decoration: BoxDecoration(color: app.color, shape: BoxShape.circle),
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
