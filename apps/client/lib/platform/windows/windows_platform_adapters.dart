import 'dart:io';

import '../../core/ports/autostart.dart';
import '../../core/ports/change_watcher.dart';
import '../../core/ports/desktop_launcher.dart';
import '../../core/ports/desktop_session.dart';
import '../../core/ports/documents.dart';
import '../../core/ports/platform_adapters.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/root_placement.dart';
import '../../core/ports/root_location.dart';
import '../../core/ports/secret_store.dart';
import '../../core/ports/self_update.dart';
import '../linux/desktop_launcher.dart';
import '../linux/manager_autostart.dart';
import 'dpapi_secrets.dart';
import 'windows_change_watchers.dart';
import 'windows_desktop_session.dart';
import 'windows_root_fs.dart';

/// The Windows adapter set (spec #32).
///
/// The root filesystem, root identity and release guard are
/// `anj_rootfs.dll` (W2). The desktop session (lock, activation pipe, tray,
/// window, session end), the DPAPI secret store and the launcher are W3.
/// Start at login goes through the installed manager (W5). The watcher factory
/// is [WindowsChangeWatchers]: one recursive `ReadDirectoryChangesW` watch on
/// the root (spec #32 File Watching).
class WindowsPlatformAdapters implements PlatformAdapters {
  const WindowsPlatformAdapters();

  /// `anj_rootfs.dll` (spec #32 W2), with its exclusive-open release guard.
  @override
  RootFilesystem rootFilesystem([String? library]) =>
      windowsRootFilesystem(library);

  /// DPAPI (user scope) under `%LOCALAPPDATA%\anj-cloud\secrets`, a private
  /// directory.
  @override
  SecretStore secretStore() => DpapiSecrets(
    makePrivate: (path) => windowsRootFilesystem().privateDir(path),
  );

  /// The shared launcher with folders enabled: Open uses the shell's default
  /// app (url_launcher, ShellExecute); a folder opens in Explorer after the
  /// root identity check through anj_rootfs.dll (replaces doc #14's
  /// `Platform.isLinux` gate).
  @override
  DesktopLauncher desktopLauncher({String? nativeLibrary}) =>
      PlatformDesktopLauncher(
        directorySupported: true,
        nativeLibrary: nativeLibrary ?? windowsRootfsLibrary(),
      );

  @override
  DesktopSession desktopSession() => WindowsDesktopSession();

  /// The installed manager's `autostart` command (anj-cloud-manager.exe,
  /// tool/windows_manager), the only writer of the HKCU Run value, as on
  /// Linux.
  /// Spec #34 P1, P2. Linux first: the picker only until this platform's spec revises.
  @override
  RootPlacement rootPlacement({String? reservedParent}) =>
      const PickerOnlyPlacement();

  @override
  AutostartControl managerAutostart(String command) =>
      ManagerAutostart(command);

  /// U-windows (spec #37) lands with the W5 manager once a Windows seat
  /// returns (decision #156).
  @override
  SelfUpdatePort? managerSelfUpdate(String command) => null;

  /// No documents provider: desktop apps open the root directly.
  @override
  AppAccess? startDocuments(DocumentsHost host, String profile) => null;

  @override
  RootLocationPolicy rootLocationPolicy() => const AnyRootLocation();

  @override
  Future<String> deviceLabel() async => Platform.localHostname;

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      const WindowsChangeWatchers().watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => const WindowsChangeWatchers().changeWatcher(
    fs,
    rootFd,
    rootPath,
    settings,
    waitTimeout: waitTimeout,
  );
}

/// The refusal every not-yet-built Windows port raises.
UnsupportedError notYet(String what, String unit) =>
    UnsupportedError('$what is not built yet; it arrives in spec #32 $unit.');
