import 'dart:async';
import 'package:flutter/material.dart';
import 'app_scope.dart';
import 'services/settings.dart';
import 'services/remote_client.dart';
import 'services/discovery.dart';
import 'services/file_transfer.dart';
import 'screens/connect_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = Settings();
  await settings.load();
  final client = RemoteClient()..deviceName = settings.deviceName;
  final discovery = Discovery();
  final fileTransfer = FileTransfer(client);

  runApp(JawnRemoteApp(
    settings: settings,
    client: client,
    discovery: discovery,
    fileTransfer: fileTransfer,
  ));
}

class JawnRemoteApp extends StatelessWidget {
  final Settings settings;
  final RemoteClient client;
  final Discovery discovery;
  final FileTransfer fileTransfer;
  const JawnRemoteApp({
    super.key,
    required this.settings,
    required this.client,
    required this.discovery,
    required this.fileTransfer,
  });

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      client: client,
      discovery: discovery,
      fileTransfer: fileTransfer,
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
