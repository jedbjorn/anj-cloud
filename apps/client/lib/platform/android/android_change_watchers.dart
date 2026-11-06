import '../../core/ports/change_watcher.dart';
import '../../core/ports/root_filesystem.dart';
import '../linux/linux_change_watchers.dart';

/// The Android [ChangeWatcherFactory] (spec #28 A2): inotify through the
/// shared native watcher, exactly as on Linux. A1 found inotify working in
/// the app sandbox but its limits unreadable, so the watcher cannot size
/// itself: a directory whose watch fails with ENOSPC is unwatched and
/// audited by the stat scan, as on Linux (decision #123 (4)), and the
/// first such fallback also asks for a full verification (#130 (3)). Like the Linux
/// factory it loads no Flutter library, so `platformWatchers()` can select
/// it in pure-Dart processes.
class AndroidChangeWatchers implements ChangeWatcherFactory {
  const AndroidChangeWatchers();

  static const _inotify = LinuxChangeWatchers();

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      _inotify.watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => _inotify.changeWatcher(
    fs,
    rootFd,
    rootPath,
    // Ordinary passes hash only reported paths here, so a directory the
    // watch limit leaves unwatched gets a full verification (#130 (3)).
    settings.withFullAuditOnLimit(),
    waitTimeout: waitTimeout,
  );
}
