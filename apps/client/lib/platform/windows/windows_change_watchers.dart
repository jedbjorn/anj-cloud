import '../../core/ports/change_watcher.dart';
import '../../core/ports/root_filesystem.dart';
import '../native/local_watcher.dart';
import '../native/native_root_fs.dart';

/// The Windows [ChangeWatcherFactory] (spec #32 "File Watching"): one
/// recursive `ReadDirectoryChangesW` watch on the root's handle, serviced by
/// a thread of anj_rootfs.dll (native/windows/rootfs_win.cc), behind the
/// shared [LocalWatcher]. Like the Linux and macOS factories it loads no
/// Flutter library, so `platformWatchers()` can select it in pure-Dart
/// processes.
class WindowsChangeWatchers implements ChangeWatcherFactory {
  const WindowsChangeWatchers();

  /// `anj_fs_magic` of an NTFS volume ("NTFS" as a little-endian word).
  static const ntfsMagic = 0x5346544E;

  /// Test seam: starting the root's watch fails, so [changeWatcher] returns
  /// null and the engine keeps the per-pass stat scan.
  static bool debugFailWatch = false;

  /// The supported root, a local fixed NTFS volume, reports every change
  /// made through any program on this machine. Roots open only on such a
  /// volume (the DLL refuses others), so this checks the filesystem the
  /// boundary reports; anything else keeps the stat scan.
  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      fs is NativeRootFs && fs.fsMagic(fd, path) == ntfsMagic;

  /// The watch starts when the root itself is added, so that happens here.
  /// Any failure (no handle, no thread, the read refused) closes the watcher
  /// and returns null: the engine keeps its per-pass stat scan (SC-045 F3).
  /// A watcher that fails later is handled by the engine as on Linux and
  /// macOS (stat scan, then a bounded restart with the same settings).
  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) async {
    if (fs is! NativeRootFs) return null;
    LocalWatcher? watcher;
    try {
      watcher = await LocalWatcher.start(
        fs,
        rootFd,
        rootPath,
        settings: settings,
        waitTimeout: waitTimeout,
        // Nothing beneath the root is on another volume: mount points and
        // junctions are reparse points, which the boundary never enters.
        silentVolume: (_, _) => false,
      );
      if (watcher == null) return null;
      if (debugFailWatch) watcher.debugFailAdds('');
      watcher.add(''); // A failure leaves the root unwatched.
      if (!watcher.watching('')) {
        watcher.close();
        return null;
      }
      return watcher;
    } on Object {
      watcher?.close();
      return null;
    }
  }
}
