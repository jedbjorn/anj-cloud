import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/local/hash_meter.dart';
import '../../core/ports/documents_filesystem.dart';
import '../../core/ports/release_guard.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/root_identity_source.dart';
import 'eviction_native.dart';

typedef _OpenC = Int32 Function(Pointer<Utf8>);
typedef _OpenD = int Function(Pointer<Utf8>);
typedef _PathC = Int32 Function(Int32, Pointer<Utf8>);
typedef _PathD = int Function(int, Pointer<Utf8>);
typedef _MoveC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _MoveD = int Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _StringC = Pointer<Utf8> Function(Int32);
typedef _StringD = Pointer<Utf8> Function(int);
typedef _DirectoryInstallC = Int32 Function(
  Int32,
  Int32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _DirectoryInstallD = int Function(
  int,
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);

/// Platform-neutral [RootFilesystem]: the FFI binding of the shared `anj_*`
/// C ABI (native/posix/exports.txt), which also serves the watcher, the
/// release guard and the profile lifetime lock. Any native library that
/// exports that ABI can sit behind it: Linux loads libanj_rootfs.so (the
/// default below); another platform passes its library path and its own
/// [errnoLabel]. Android loads the same ABI built with the NDK
/// (`AndroidRootFs`, spec #28 A2); macOS wraps it as `MacosRootFs`.
class NativeRootFs implements RootFilesystem, DocumentsFilesystem {
  NativeRootFs([
    String? library,
    this.errnoLabel = 'Linux errno',
    this.fullVerificationInterval,
  ]) : libraryPath =
           library ??
           Platform.environment['ANJ_ROOTFS_LIBRARY'] ??
           defaultLibrary() {
    lib = DynamicLibrary.open(libraryPath);
  }

  /// Linux: lib/ beside the executable (the installed bundle). Android: the
  /// soname, which the loader finds in the APK's native library directory.
  static String defaultLibrary() => Platform.isAndroid
      ? 'libanj_rootfs.so'
      : p.join(
          File(Platform.resolvedExecutable).parent.path,
          'lib',
          'libanj_rootfs.so',
        );

  /// Filesystems whose nanosecond ctime and stable inodes make an unchanged
  /// stamp trustworthy once their pages are written back: ext2/3/4, btrfs,
  /// xfs, f2fs, bcachefs. tmpfs is excluded: its pages are never written back,
  /// so writes through a shared mapping may never move ctime.
  static const trustedMagic = {
    0xEF53,
    0x9123683E,
    0x58465342,
    0xF2F52010,
    0xCA451A4E,
  };

  @override
  Set<int> get trustedFsMagic => trustedMagic;

  /// Linux and macOS link; Android cannot. `ANJ_ROOTFS_HARDLINKS=0` is a test
  /// seam honoured only together with ANJ_ROOTFS_LIBRARY, naming the host
  /// build of the Android boundary (-DANJ_ANDROID_BOUNDARY), whose installs
  /// cannot link; a shipped build (its bundled library) ignores it.
  @override
  bool get hardLinks {
    if (Platform.isAndroid) return false;
    final environment = Platform.environment;
    return !(environment['ANJ_ROOTFS_LIBRARY'] != null &&
        environment['ANJ_ROOTFS_HARDLINKS'] == '0');
  }

  /// The writeback sysctls from /proc/sys/vm (or the test [directory]);
  /// null when any is unreadable.
  @override
  WritebackParameters? writeback({String? directory}) {
    final source = directory ?? '/proc/sys/vm';
    try {
      int read(String name) =>
          int.parse(File('$source/$name').readAsStringSync().trim());
      return (
        expireCentisecs: read('dirty_expire_centisecs'),
        writebackCentisecs: read('dirty_writeback_centisecs'),
        laptopMode: read('laptop_mode'),
      );
    } on Object {
      return null;
    }
  }

  /// Opened again by the watcher isolate (same process, same handle).
  final String libraryPath;

  /// [OSError] message of boundary failures, naming the platform's errno
  /// space ("Linux errno" on Linux, unchanged).
  final String errnoLabel;

  /// See [RootFilesystem.fullVerificationInterval]: null on Linux; macOS
  /// and Windows pass 60 minutes (decision #135), Android 15 (#130 (3)).
  @override
  final Duration? fullVerificationInterval;

  @override
  void Function()? beforeDestructiveChange;
  late final DynamicLibrary lib;
  late final _open = lib.lookupFunction<_OpenC, _OpenD>('anj_open_root');
  late final _check = lib.lookupFunction<_PathC, _PathD>('anj_check_root');
  late final _readOpen = lib.lookupFunction<_PathC, _PathD>('anj_open_read');
  late final _mkdir = lib.lookupFunction<_PathC, _PathD>('anj_mkdir');
  late final _mkdirExclusive = lib.lookupFunction<_PathC, _PathD>(
    'anj_mkdir_exclusive',
  );
  late final _openDirectory = lib.lookupFunction<_PathC, _PathD>(
    'anj_open_directory',
  );
  late final _installDirectory = lib
      .lookupFunction<_DirectoryInstallC, _DirectoryInstallD>(
        'anj_install_directory',
      );
  late final _rmdir = lib.lookupFunction<_MoveC, _MoveD>('anj_rmdir_empty');
  late final _install = lib.lookupFunction<_MoveC, _MoveD>('anj_install');
  late final _quarantine = lib.lookupFunction<_MoveC, _MoveD>('anj_quarantine');
  late final _rename = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
      >('anj_rename_noreplace');
  late final _scan = lib.lookupFunction<_StringC, _StringD>('anj_scan');
  late final _stamp = lib.lookupFunction<_StringC, _StringD>('anj_stamp');
  late final _rootInfo = lib.lookupFunction<_StringC, _StringD>(
    'anj_root_info',
  );
  late final _debugVolume = lib
      .lookupFunction<
        Void Function(Int64, Int32, Uint64),
        void Function(int, int, int)
      >('anj_debug_volume');
  late final _fsMagic = lib
      .lookupFunction<
        Int64 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('anj_fs_magic');

  late final watchOpen = lib
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'anj_watch_open',
      );
  late final watchStop = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('anj_watch_stop');
  late final watchRelease = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('anj_watch_release');
  late final _watchAdd = lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Utf8>,
          Pointer<Int64>,
          Pointer<Utf8>,
          Int32,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Utf8>,
          Pointer<Int64>,
          Pointer<Utf8>,
          int,
        )
      >('anj_watch_add');
  late final _watchRemove = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('anj_watch_remove');
  late final _watchScan = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Int32, Pointer<Utf8>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int, Pointer<Utf8>, int)
      >('anj_watch_scan');
  late final watchAck = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('anj_watch_ack');

  /// The longest the platform may hold an event back before reporting it
  /// (FSEvents latency on Darwin; inotify has none, so a no-op on Linux).
  late final watchLatency = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int64),
        void Function(Pointer<Void>, int)
      >('anj_watch_latency');
  late final watchDebugInject = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32, Uint32),
        void Function(Pointer<Void>, int, int)
      >('anj_watch_debug_inject');
  late final watchDebugClock = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int64),
        void Function(Pointer<Void>, int)
      >('anj_watch_debug_clock');
  late final _watchDebugFail = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>)
      >('anj_watch_debug_fail_add');

  /// Adds a watch to the directory at [path] beneath [root] ('' is the root),
  /// opened through the descriptor-bound helper. Returns the watch descriptor
  /// and the directory's `dev:ino`, or throws with the errno.
  ({int wd, String identity}) watchAdd(
    Pointer<Void> handle,
    int root,
    String path,
  ) {
    final identity = malloc<Int64>(2);
    // Room for every volume key form (Darwin's APFS key is 33 characters).
    const capacity = 64;
    final volume = malloc<Uint8>(capacity);
    try {
      final wd = _path(
        path,
        (ptr) => _watchAdd(
          handle,
          root,
          ptr,
          identity,
          volume.cast<Utf8>(),
          capacity,
        ),
      );
      // Same volume:ino form as identity() and the scans.
      return (
        wd: wd,
        identity: '${volume.cast<Utf8>().toDartString()}:${identity[1]}',
      );
    } finally {
      malloc.free(identity);
      malloc.free(volume);
    }
  }

  int watchRemove(Pointer<Void> handle, int wd) => _watchRemove(handle, wd);

  /// Stat-only listing of [path] (and, when [recursive], of everything
  /// beneath it), adding watches top-down before each directory is read when
  /// [handle] is not null. A missing path yields no items.
  @override
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive) {
    if (path.contains('\x00')) throw const FileSystemException('NUL in path');
    final ptr = path.toNativeUtf8();
    try {
      final decoded = jsonDecode(
        _string(_watchScan(handle ?? nullptr, root, ptr, recursive ? 1 : 0)),
      ) as Map;
      return (
        items: (decoded['items'] as List).cast<Map<String, dynamic>>(),
        watches: (decoded['watches'] as List).cast<Map<String, dynamic>>(),
      );
    } finally {
      malloc.free(ptr);
    }
  }

  void watchDebugFailAdds(Pointer<Void> handle, String? prefix) {
    if (prefix == null) return _watchDebugFail(handle, nullptr);
    final ptr = prefix.toNativeUtf8();
    try {
      _watchDebugFail(handle, ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Counts every content read made through this boundary (test seam and
  /// opt-in metrics), by purpose.
  @override
  final HashMeter meter = HashMeter();
  late final _error = lib.lookupFunction<Int32 Function(), int Function()>(
    'anj_error',
  );
  late final _free = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('anj_free');
  @override
  late final closeFd = lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('anj_close');
  late final _read = lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('anj_read');
  late final _chmod = lib.lookupFunction<_OpenC, _OpenD>('anj_chmod_private');
  late final _stagePath = lib.lookupFunction<_StringC, _StringD>(
    'anj_stage_path',
  );
  late final _errorName = lib
      .lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('anj_error_name');

  /// Stable symbolic name of an errno value reported by this boundary
  /// (`wouldBlock`, `busy`, `exists`, `notFound`, `escape`, `loop`, …;
  /// spec #31 S2), so callers never compare platform numbers.
  String errorName(int code) => _errorName(code).toDartString();

  @override
  String stagePath(int stageFd) => _string(
    _stagePath(stageFd),
    'Private staging directory is not reachable',
  );
  int _path(String value, int Function(Pointer<Utf8>) action) {
    if (value.contains('\x00')) throw const FileSystemException('NUL in path');
    final ptr = value.toNativeUtf8();
    try {
      final result = action(ptr);
      if (result < 0) {
        throw FileSystemException(
          'Filesystem boundary refused operation',
          value,
          OSError(errnoLabel, _error()),
        );
      }
      return result;
    } finally {
      malloc.free(ptr);
    }
  }

  @override
  int openRoot(String path) => _path(path, _open);
  @override
  void checkRoot(int fd, String path) => _path(path, (ptr) => _check(fd, ptr));
  @override
  void makeDir(int fd, String path) => _path(path, (ptr) => _mkdir(fd, ptr));
  @override
  void makeDirExclusive(int fd, String path) =>
      _path(path, (ptr) => _mkdirExclusive(fd, ptr));
  @override
  String fileIdentity(int fd, String path) {
    final selected = _path(path, (ptr) => _readOpen(fd, ptr));
    try {
      return identity(selected);
    } finally {
      closeFd(selected);
    }
  }

  @override
  String directoryIdentity(int fd, String path) {
    final selected = _path(path, (ptr) => _openDirectory(fd, ptr));
    try {
      return identity(selected);
    } finally {
      closeFd(selected);
    }
  }

  @override
  void installDirectory(
    int root,
    int stage,
    String staged,
    String path,
    String parentIdentity,
    String identity,
  ) => _path(
    staged,
    (s) => _path(
      path,
      (p) => _path(
        parentIdentity,
        (parent) => _path(
          identity,
          (i) => _installDirectory(root, stage, s, p, parent, i),
        ),
      ),
    ),
  );
  @override
  void removeEmptyDir(int fd, String path, String identity) {
    beforeDestructiveChange?.call();
    _move(fd, path, identity, _rmdir);
  }

  @override
  void privateDir(String path) => _path(path, _chmod);
  void _move(int fd, String relative, String stage, _MoveD action) =>
      _path(relative, (rel) => _path(stage, (dst) => action(fd, rel, dst)));
  @override
  void install(int fd, String relative, String stage) =>
      _move(fd, relative, stage, _install);
  @override
  void quarantine(int fd, String relative, String stage) {
    beforeDestructiveChange?.call();
    _move(fd, relative, stage, _quarantine);
  }

  late final _createFile = lib.lookupFunction<_PathC, _PathD>(
    'anj_create_file',
  );
  @override
  int openRead(int fd, String path) => _path(path, (ptr) => _readOpen(fd, ptr));
  @override
  int createExclusive(int fd, String path) =>
      _path(path, (ptr) => _createFile(fd, ptr));
  @override
  void renameExclusive(int fd, String from, String to, String identity) {
    beforeDestructiveChange?.call();
    _path(
      from,
      (f) => _path(to, (t) => _path(identity, (i) => _rename(fd, f, t, i))),
    );
  }

  String _string(
    Pointer<Utf8> ptr, [
    String what = 'Cannot enumerate root completely',
  ]) {
    if (ptr == nullptr) {
      throw FileSystemException(what, '', OSError(errnoLabel, _error()));
    }
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr.cast());
    }
  }

  /// `volume:ino` of an open descriptor. The volume is a stable key for the
  /// filesystem (`f` + statfs f_fsid on ext2/3/4 and btrfs, otherwise the
  /// decimal st_dev as before); see `volume_key` in native/posix/rootfs.cc.
  @override
  String identity(int fd) => _string(_stamp(fd)).split(':').take(2).join(':');

  /// `volume:ino:size:mtime_ns:ctime_ns` of an open descriptor.
  @override
  String stamp(int fd) {
    final parts = _string(_stamp(fd)).split(':');
    final v = parts.skip(1).map(int.parse).toList();
    return '${parts[0]}:${v[0]}:${v[1]}:${v[2] * 1000000000 + v[3]}:'
        '${v[4] * 1000000000 + v[5]}';
  }

  /// Identity of the synchronized root as persisted in `rootIdentity`
  /// ([RootInfo.identity]), the pre-fix `st_dev:st_ino` form
  /// ([RootInfo.legacy], for migration only) and whether the volume key is
  /// an on-disk fsid that survives reboot ([RootInfo.stable]).
  @override
  RootInfo rootInfo(int fd) {
    final value = jsonDecode(_string(_rootInfo(fd))) as Map<String, dynamic>;
    return (
      identity: value['identity'] as String,
      legacy: value['legacy'] as String,
      stable: value['stable'] as bool,
    );
  }

  /// Test seam: [devOffset] is added to every reported st_dev (a reboot
  /// renumbering btrfs anonymous devices); a non-null [fsid] makes every
  /// filesystem report that stable fsid (tmpfs fixtures modelling btrfs or
  /// ext4). Process-wide; reset with no arguments.
  void debugVolume({int devOffset = 0, int? fsid}) =>
      _debugVolume(devOffset, fsid == null ? 0 : 1, fsid ?? 0);

  /// statfs f_type of the root (empty [path]) or of an item beneath it.
  @override
  int fsMagic(int fd, String path) =>
      _path(path.isEmpty ? '' : path, (ptr) => _fsMagic(fd, ptr));

  late final _locate = lib
      .lookupFunction<
        Int32 Function(
          Int32,
          Int32,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Int32,
          Pointer<Int64>,
        ),
        int Function(
          int,
          int,
          Pointer<Utf8>,
          Pointer<Uint8>,
          int,
          Pointer<Int64>,
        )
      >('anj_locate_identity');

  /// Room for a root-relative path in UTF-8 (Windows allows 32,767 UTF-16
  /// units; each takes at most 3 bytes).
  static const _locateCapacity = 3 * 32768;

  bool? _locates;

  /// Whether the library answers `anj_locate_identity` (spec #33 I3): macOS
  /// and Windows; Linux and Android report it unsupported (0), and a library
  /// without the export never looks anything up.
  @override
  bool get locatesIdentity => _locates ??= () {
    try {
      return _locate(-1, -1, nullptr, nullptr, 0, nullptr) != 0;
    } on Object {
      return false;
    }
  }();

  @override
  IdentityLocation locateIdentity(int fd, int stageFd, String identity) {
    // A NUL cannot reach the export intact: malformed, which proves nothing
    // about the item (failing safe, as the export answers one).
    if (!locatesIdentity || identity.contains('\x00')) return identityUncertain;
    final id = identity.toNativeUtf8();
    final out = malloc<Uint8>(_locateCapacity);
    final links = malloc<Int64>();
    try {
      final place = switch (_locate(
        fd,
        stageFd,
        id,
        out,
        _locateCapacity,
        links,
      )) {
        1 => IdentityPlace.inside,
        2 => IdentityPlace.outside,
        3 => IdentityPlace.staging,
        4 => IdentityPlace.notFound,
        _ => IdentityPlace.uncertain,
      };
      if (place == IdentityPlace.notFound) return identityNotFound;
      if (place == IdentityPlace.uncertain) return identityUncertain;
      final path = place == IdentityPlace.inside
          ? out.cast<Utf8>().toDartString()
          : null;
      if (place == IdentityPlace.inside && (path == null || path.isEmpty)) {
        return identityUncertain;
      }
      return (place: place, path: path, links: links.value);
    } on Object {
      return identityUncertain; // Never throws (spec #33 I3).
    } finally {
      malloc.free(id);
      malloc.free(out);
      malloc.free(links);
    }
  }

  /// Windows: true (NTFS in the Win32 namespace; a directory with WSL case
  /// sensitivity turned on is treated as insensitive too, which only keeps a
  /// clash loser in the cloud). macOS: the volume's own answer,
  /// `pathconf(_PC_CASE_SENSITIVE)`, assumed insensitive (the default) when
  /// it cannot be read. Elsewhere false.
  @override
  bool caseInsensitive(String rootPath) {
    if (Platform.isWindows) return true;
    if (!Platform.isMacOS) return false;
    const pcCaseSensitive = 11; // <sys/unistd.h> on Darwin
    final pathconf = DynamicLibrary.process()
        .lookupFunction<
          IntPtr Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('pathconf');
    final path = rootPath.toNativeUtf8();
    try {
      return pathconf(path, pcCaseSensitive) != 1;
    } finally {
      malloc.free(path);
    }
  }

  @override
  List<Map<String, dynamic>> scan(int fd) =>
      (jsonDecode(_string(_scan(fd))) as List).cast<Map<String, dynamic>>();
  @override
  String copyAndHash(
    int root,
    String relative,
    File? destination, {
    String purpose = 'content',
  }) => copyAndHashStamped(root, relative, destination, purpose: purpose).hash;

  @override
  ReleaseGuard releaseGuard() => EvictionNative(this);

  /// Reads every byte. The returned stamp was observed before and after the
  /// read on the same descriptor, so it describes exactly these bytes.
  @override
  ({String hash, String stamp}) copyAndHashStamped(
    int root,
    String relative,
    File? destination, {
    String purpose = 'content',
  }) {
    final fd = _path(relative, (ptr) => _readOpen(root, ptr));
    final memory = malloc<Uint8>(256 * 1024);
    RandomAccessFile? output;
    var total = 0;
    try {
      final before = stamp(fd);
      output = destination?.openSync(mode: FileMode.writeOnly);
      final digest = _DigestResult();
      final sink = sha256.startChunkedConversion(digest);
      while (true) {
        final n = _read(fd, memory, 256 * 1024);
        if (n < 0) throw const FileSystemException('Read failed');
        if (n == 0) break;
        total += n;
        final bytes = memory.asTypedList(n);
        sink.add(bytes);
        output?.writeFromSync(bytes);
      }
      sink.close();
      output?.flushSync();
      if (stamp(fd) != before) {
        throw const FileSystemException('File changed during read; retrying');
      }
      return (hash: digest.value!, stamp: before);
    } finally {
      meter.record(purpose, total);
      output?.closeSync();
      malloc.free(memory);
      closeFd(fd);
    }
  }
}

class _DigestResult implements Sink<Digest> {
  String? value;
  @override
  void add(Digest data) {
    value = data.toString();
  }

  @override
  void close() {}
}
