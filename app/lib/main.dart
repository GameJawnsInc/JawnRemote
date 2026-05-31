import 'package:flutter/material.dart';
import 'app_scope.dart';
import 'services/settings.dart';
import 'services/remote_client.dart';
import 'services/discovery.dart';
import 'screens/connect_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();
  final client = RemoteClient()..deviceName = settings.deviceName;
  final discovery = Discovery();
  runApp(JawnRemoteApp(
    settings: settings,
    client: client,
    discovery: discovery,
  ));
}

class JawnRemoteApp extends StatelessWidget {
  final Settings settings;
  final RemoteClient client;
  final Discovery discovery;
  const JawnRemoteApp({
    super.key,
    required this.settings,
    required this.client,
    required this.discovery,
  });

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      client: client,
      discovery: discovery,
      child: MaterialApp(
        title: 'JawnRemote',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF4F8CFF),
          scaffoldBackgroundColor: const Color(0xFF0E1116),
        ),
        home: const ConnectScreen(),
      ),
    );
  }
}
