import '../../core/ports/change_watcher.dart';
import '../../core/ports/root_filesystem.dart';
import '../native/local_watcher.dart';
import '../native/native_root_fs.dart';

/// The macOS [ChangeWatcherFactory] (spec #31 M2): one FSEvents stream on
/// the root (native/posix/watch_fsevents.inc) behind the shared
/// [LocalWatcher]. Like the Linux factory, it loads no Flutter library, so
/// `platformWatchers()` can select it in pure-Dart processes.
class MacosChangeWatchers implements ChangeWatcherFactory {
  const MacosChangeWatchers();

  /// Test seam: the root's stream cannot be created, as when fseventsd
  /// refuses it, so [changeWatcher] returns null.
  static bool debugFailStream = false;

  /// Only APFS is trusted to report every change through FSEvents (spec #31
  /// "File Watching"): network, FUSE and other filesystems keep the per-pass
  /// stat scan. Darwin's stable volume key ("u" + the APFS volume UUID, see
  /// `stable_volume` in native/posix/compat_darwin.h) exists only on APFS.
  static bool trustedVolume(String volume) => volume.startsWith('u');

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) {
    if (fs is! NativeRootFs) return false;
    final identity = path.isEmpty
        ? fs.identity(fd)
        : fs.directoryIdentity(fd, path);
    return trustedVolume(identity.split(':').first);
  }

  /// The stream starts when the root itself is watched, so that happens
  /// here: when it fails, the watcher is closed and the engine keeps its
  /// per-pass stat scan. A watcher that dies later is handled by the engine
  /// as on Linux (stat scan, then a bounded restart).
  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) async {
    if (fs is! NativeRootFs) return null;
    final watcher = await LocalWatcher.start(
      fs,
      rootFd,
      rootPath,
      settings: settings,
      waitTimeout: waitTimeout,
      silentVolume: (volume, _) => !trustedVolume(volume),
    );
    if (watcher == null) return null;
    if (debugFailStream) watcher.debugFailAdds('');
    watcher.add(''); // A failure leaves the root unwatched.
    if (!watcher.watching('')) {
      watcher.close();
      return null;
    }
    return watcher;
  }
}
