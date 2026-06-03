import 'package:flutter/widgets.dart';
import 'services/settings.dart';
import 'services/remote_client.dart';
import 'services/discovery.dart';
import 'services/file_transfer.dart';

/// Provides the shared service singletons to the widget tree.
class AppScope extends InheritedWidget {
  final Settings settings;
  final RemoteClient client;
  final Discovery discovery;
  final FileTransfer fileTransfer;

  const AppScope({
    super.key,
    required this.settings,
    required this.client,
    required this.discovery,
    required this.fileTransfer,
    required super.child,
  });

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}
