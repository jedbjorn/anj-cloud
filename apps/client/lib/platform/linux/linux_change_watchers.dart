import '../../core/ports/change_watcher.dart';
import '../../core/ports/root_filesystem.dart';
import '../native/local_watcher.dart';
import '../native/native_root_fs.dart';

/// The Linux [ChangeWatcherFactory]: inotify through [LocalWatcher]. It
/// loads no Flutter library, so the sync engine keeps running in pure-Dart
/// processes (the crash fixtures under tool/).
class LinuxChangeWatchers implements ChangeWatcherFactory {
  const LinuxChangeWatchers();

  /// Network and FUSE filesystems ([LocalWatcher.silentFsMagic]) need not
  /// pass another client's change through this kernel's inotify.
  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      !LocalWatcher.silentFsMagic.contains(fs.fsMagic(fd, path));

  /// inotify through this adapter's own native binding; a filesystem that is
  /// not [NativeRootFs] has no watch handle here, so it gets no watcher.
  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => fs is NativeRootFs
      ? LocalWatcher.start(
          fs,
          rootFd,
          rootPath,
          settings: settings,
          waitTimeout: waitTimeout,
        )
      : Future.value(null);
}
