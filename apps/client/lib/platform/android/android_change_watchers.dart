import '../../core/ports/change_watcher.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/phone_folders.dart';
import '../linux/linux_change_watchers.dart';
import '../native/local_watcher.dart';
import '../native/mapped_root_fs.dart';

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

  /// The phone folders (spec #52) are MediaProvider's FUSE mount, which
  /// the Linux rule counts as silent; AC0 found inotify there reporting
  /// every change another app makes, so a watch on them is trusted.
  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      fs is PhoneFolderRouting && inPhoneFolder(path) ||
      _inotify.watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => fs is MappedRootFs
      ? LocalWatcher.start(
          fs,
          rootFd,
          rootPath,
          settings: settings.withFullAuditOnLimit(),
          waitTimeout: waitTimeout,
          // Shared storage (another volume than the root's) is watched.
          silentVolume: (volume, path) =>
              !inPhoneFolder(path) &&
              LocalWatcher.silentFsMagic.contains(fs.fsMagic(rootFd, path)),
        )
      : _inotify.changeWatcher(
          fs,
          rootFd,
          rootPath,
          // Ordinary passes hash only reported paths here, so a directory the
          // watch limit leaves unwatched gets a full verification (#130 (3)).
          settings.withFullAuditOnLimit(),
          waitTimeout: waitTimeout,
        );
}
