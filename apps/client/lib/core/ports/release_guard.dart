/// Port: guarded release of owned local files (cloud-space release, working
/// copies, recovery copies; part of native filesystem access, decision #74).
///
/// `EvictionNative` (lib/platform/native/eviction_native.dart) over the
/// guard compiled into the native library, which reports its
/// [ReleaseGuardStrength]: Linux's F_SETLEASE lease
/// (native/posix/guard_lease.inc).
library;

class NativeFileInfo {
  NativeFileInfo(Map<String, dynamic> value)
    : identity = value['identity'] as String,
      stamp = value['stamp'] as String,
      links = value['links'] as int,
      allocated = value['allocated'] as int,
      size = value['size'] as int,
      owned = value['owned'] == true,
      modifiedMs = value['modifiedMs'] as int? ?? 0;
  final String identity;
  final String stamp;
  final int links;
  final int allocated;
  final int size;
  final bool owned;
  final int modifiedMs;
  Map<String, Object> toJson() => {
    'identity': identity,
    'stamp': stamp,
    'links': links,
    'allocated': allocated,
    'size': size,
    'owned': owned,
    'modifiedMs': modifiedMs,
  };
}

/// How strongly a [ReleaseGuard] excludes other processes during a release.
enum ReleaseGuardStrength {
  /// A kernel write lease: no new open of the file can start while held.
  lease,

  /// Weaker (decision #42): a process can open, read and close inside the
  /// window unseen; a write, a held descriptor or a mapping fails the
  /// release, which the engine retries.
  busyAndUnchanged,

  /// An exclusive open (decision #126, Windows): any data handle refuses the
  /// guard, and every data open during the window fails.
  exclusiveOpen,
}

abstract interface class ReleaseGuard {
  /// The guard mechanism behind this boundary.
  ReleaseGuardStrength get strength;

  NativeFileInfo preview(int directory, String name);
  NativeFileInfo info(int directory, String path);
  NativeFileInfo infoFd(int fd);
  int create(int directory, String name);
  int guard(
    int directory,
    String path,
    NativeFileInfo expected, {
    required int links,
  });
  void valid(int fd);
  void close(int fd);
  String hash(int fd, {String purpose});
  void preserve(int root, String path, int stage, String name);
  void install(int root, String path, int stage, String name);

  /// Renames staging [name] to root [path]; never replaces an existing
  /// path (EEXIST). Both directories are fsynced before it returns.
  void restore(int root, String path, int stage, String name);
  void quarantine(int guardFd, int root, String path, int stage, String name);
  void unlink(int guardFd, int stage, String name);
}
