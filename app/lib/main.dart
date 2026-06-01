import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'app_scope.dart';
import 'config.dart';
import 'services/settings.dart';
import 'services/remote_client.dart';
import 'services/discovery.dart';
import 'services/billing.dart';
import 'screens/connect_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kAdsEnabled) unawaited(MobileAds.instance.initialize());

  final settings = Settings();
  await settings.load();
  final client = RemoteClient()..deviceName = settings.deviceName;
  final discovery = Discovery();
  final billing = BillingService();
  unawaited(billing.init());

  runApp(JawnRemoteApp(
    settings: settings,
    client: client,
    discovery: discovery,
    billing: billing,
  ));
}

class JawnRemoteApp extends StatelessWidget {
  final Settings settings;
  final RemoteClient client;
  final Discovery discovery;
  final BillingService billing;
  const JawnRemoteApp({
    super.key,
    required this.settings,
    required this.client,
    required this.discovery,
    required this.billing,
  });

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      client: client,
      discovery: discovery,
      billing: billing,
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
