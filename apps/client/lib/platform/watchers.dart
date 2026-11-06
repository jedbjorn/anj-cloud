import 'dart:io';

import '../core/ports/change_watcher.dart';
import '../core/ports/root_filesystem.dart';
import 'android/android_change_watchers.dart';
import 'linux/linux_change_watchers.dart';
import 'macos/macos_change_watchers.dart';
import 'windows/windows_change_watchers.dart';

/// The running platform's watcher factory (decision #74), the same one
/// `platformAdapters()` provides. A separate selector because the sync
/// engine also runs in pure-Dart processes, where the full adapter set
/// (which loads Flutter) cannot be imported.
///
/// A platform without an entry here gets [UnwatchedChangeWatchers]: its
/// roots keep the per-pass stat scan, and `SyncEngine.startWatching` never
/// throws for it (flag SC-045 F3). Keep each entry the same factory its
/// `PlatformAdapters` returns; the per-OS selector tests check that.
ChangeWatcherFactory platformWatchers() {
  if (Platform.isLinux) return const LinuxChangeWatchers();
  if (Platform.isMacOS) return const MacosChangeWatchers();
  if (Platform.isWindows) return const WindowsChangeWatchers();
  if (Platform.isAndroid) return const AndroidChangeWatchers();
  return const UnwatchedChangeWatchers();
}

/// No watcher: every root keeps the per-pass stat scan.
class UnwatchedChangeWatchers implements ChangeWatcherFactory {
  const UnwatchedChangeWatchers();

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) => false;

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => Future.value(null);
}
