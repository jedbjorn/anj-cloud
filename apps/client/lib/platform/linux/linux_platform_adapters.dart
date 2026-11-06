import 'dart:io';

import '../../core/ports/autostart.dart';
import '../../core/ports/change_watcher.dart';
import '../../core/ports/desktop_launcher.dart';
import '../../core/ports/desktop_session.dart';
import '../../core/ports/documents.dart';
import '../../core/ports/platform_adapters.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/root_placement.dart';
import 'xdg_root_placement.dart';
import '../../core/ports/root_location.dart';
import '../../core/ports/secret_store.dart';
import '../../core/ports/self_update.dart';
import 'desktop_launcher.dart';
import 'keyring_secrets.dart';
import 'linux_change_watchers.dart';
import 'linux_desktop_session.dart';
import 'manager_autostart.dart';
import 'manager_self_update.dart';
import '../native/native_root_fs.dart';

class LinuxPlatformAdapters implements PlatformAdapters {
  const LinuxPlatformAdapters();

  @override
  RootFilesystem rootFilesystem([String? library]) => NativeRootFs(library);

  @override
  SecretStore secretStore() => KeyringSecrets();

  @override
  DesktopLauncher desktopLauncher({String? nativeLibrary}) =>
      PlatformDesktopLauncher(nativeLibrary: nativeLibrary);

  @override
  DesktopSession desktopSession() => LinuxDesktopSession();

  /// Spec #34 P1, P2.
  @override
  RootPlacement rootPlacement({String? reservedParent}) =>
      XdgRootPlacement(reservedParent: reservedParent);

  @override
  AutostartControl managerAutostart(String command) =>
      ManagerAutostart(command);

  /// Spec #37 U-linux.
  @override
  SelfUpdatePort managerSelfUpdate(String command) =>
      ManagerSelfUpdate(command);

  /// Linux has no documents provider: apps open the root directly.
  @override
  AppAccess? startDocuments(DocumentsHost host, String profile) => null;

  @override
  RootLocationPolicy rootLocationPolicy() => const AnyRootLocation();

  @override
  Future<String> deviceLabel() async => Platform.localHostname;

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      const LinuxChangeWatchers().watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => const LinuxChangeWatchers().changeWatcher(
    fs,
    rootFd,
    rootPath,
    settings,
    waitTimeout: waitTimeout,
  );
}
