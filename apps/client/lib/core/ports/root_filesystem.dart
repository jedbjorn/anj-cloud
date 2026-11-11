/// Port: native filesystem access to the synchronized root (decision #74).
///
/// Every content and namespace operation in the root and in private staging
/// goes through a descriptor-relative boundary: paths are root-relative, no
/// symlink is followed, and failures surface as [FileSystemException]s.
/// `NativeRootFs` (lib/platform/native/native_root_fs.dart) on Linux,
/// the FFI binding of libanj_rootfs built from native/posix/rootfs.cc.
library;

import 'dart:ffi';
import 'dart:io';

import '../local/hash_meter.dart';
import 'release_guard.dart';
import 'root_identity_source.dart';

/// The kernel's periodic writeback parameters (decision #39): with them an
/// unchanged stamp can be trusted once its pages are written back.
typedef WritebackParameters = ({
  int expireCentisecs,
  int writebackCentisecs,
  int laptopMode,
});

abstract interface class RootFilesystem implements RootIdentitySource {
  /// Writeback parameters, read again at every pass; null when the platform
  /// cannot read them, which turns the stamp fast path off (every file is
  /// hashed, decision #39). [directory] is a test seam holding the same file
  /// names as Linux's /proc/sys/vm.
  WritebackParameters? writeback({String? directory});

  /// Filesystem types ([fsMagic]) whose nanosecond ctime and stable inodes
  /// make an unchanged stamp trustworthy once written back.
  Set<int> get trustedFsMagic;

  /// Whether the boundary can hard-link a staged file into the root. Where
  /// it can (Linux, macOS) an ordinary install links the staged file, which
  /// keeps its staging name as a free alias. Where it cannot (Android: linkat
  /// is refused) an ordinary install renames the staged file into place and
  /// keeps no copy (decision #123 (2)); only installs whose staged copy must
  /// survive pay for a copy.
  bool get hardLinks;

  /// Counts every content read made through this boundary (test seam and
  /// opt-in metrics), by purpose.
  HashMeter get meter;

  int openRoot(String path);
  void checkRoot(int fd, String path);
  void makeDir(int fd, String path);
  void makeDirExclusive(int fd, String path);
  String fileIdentity(int fd, String path);
  String directoryIdentity(int fd, String path);
  void installDirectory(
    int root,
    int stage,
    String staged,
    String path,
    String parentIdentity,
    String identity,
  );
  void removeEmptyDir(int fd, String path, String identity);
  void privateDir(String path);
  void install(int fd, String relative, String stage);
  void quarantine(int fd, String relative, String stage);

  /// Renames the file or directory at [from] (still [identity]) to the
  /// absent [to], both root-relative; an existing [to] is never replaced.
  void renameExclusive(int fd, String from, String to, String identity);

  /// A directory path through which Dart file I/O reaches the entries of the
  /// open staging directory [stageFd] (spec #31 S2). Linux names the
  /// descriptor itself (`/proc/self/fd/N`); platforms without procfs return
  /// the directory's current path after checking it still opens [stageFd]'s
  /// directory. Shared code never builds such a path itself.
  String stagePath(int stageFd);

  /// Closes a descriptor returned by this boundary.
  int Function(int) get closeFd;

  /// statfs f_type of the root (empty [path]) or of an item beneath it.
  int fsMagic(int fd, String path);

  /// Without trusted stamps (no periodic writeback) a pass normally hashes
  /// every file (decision #39). A non-null interval lets a platform whose
  /// watcher reports content changes hash only the paths it reported, with a
  /// full verification pass (every file hashed) at most this often and
  /// whenever the watcher lost events: macOS (FSEvents on APFS, 60 minutes,
  /// decision #135), Windows (60 minutes), Android (#130 (3), 15 minutes).
  /// Null (Linux) keeps the rule unchanged.
  Duration? get fullVerificationInterval;

  /// Called before every destructive change this boundary or its release
  /// guard makes: a quarantine, a rename away from a path, an empty-folder
  /// removal, a preserve move and a guarded unlink (decision #137 (1)). The
  /// engine sets it to `Manifest.commitPoint`, so the record of the change
  /// is durable first and a power loss can never turn it into what reads as
  /// a local delete. Installs, restores and folder creation only add.
  void Function()? beforeDestructiveChange;

  /// Whether [locateIdentity] answers on this platform: the seam of spec
  /// #33 I3 (macOS by file ID, Windows by `OpenFileById`). Where it does, a
  /// synchronized item missing from a partial pass is looked up instead of
  /// held: found inside the root it is a move, otherwise a delete at once.
  /// False until I3 lands, and on Linux and Android, which hold the removal
  /// for the quiet period instead (decision #140).
  bool get locatesIdentity;

  /// The root-relative path of the item whose local identity
  /// (`volume:inode`, the NTFS file ID) is [identity], when it is beneath the
  /// root [fd] and has exactly one link; null when not found, outside the
  /// root, hard-linked or on any error. Bounded; never throws.
  String? locateIdentity(int fd, String identity);

  /// Whether the volume holding [rootPath] treats names that differ only by
  /// case (or Unicode normalization) as one name: NTFS on Windows, APFS and
  /// HFS+ in their default case-insensitive form on macOS. Where it does,
  /// two server items that fold together cannot both be created, and one
  /// written under the other's name would land inside it (decision #120 Q2,
  /// spec #32 W4). False on case-sensitive Linux and Android app storage.
  bool caseInsensitive(String rootPath);

  List<Map<String, dynamic>> scan(int fd);

  /// Stat-only listing of [path] (and, when [recursive], of everything
  /// beneath it), adding watches top-down before each directory is read when
  /// [handle] (an opaque native watch handle) is not null. A missing path
  /// yields no items.
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive);

  String copyAndHash(
    int root,
    String relative,
    File? destination, {
    String purpose,
  });

  /// Reads every byte. The returned stamp was observed before and after the
  /// read on the same descriptor, so it describes exactly these bytes.
  ({String hash, String stamp}) copyAndHashStamped(
    int root,
    String relative,
    File? destination, {
    String purpose,
  });

  /// The guard for owned-file release bound to this same boundary.
  ReleaseGuard releaseGuard();
}
