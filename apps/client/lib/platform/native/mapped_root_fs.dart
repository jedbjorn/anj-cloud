import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/local/root_tree.dart' show uniqueId;
import '../../core/ports/phone_folders.dart';
import '../../core/ports/release_guard.dart';
import 'native_root_fs.dart';

/// errno values of the Linux kernel (Android included).
const _exdev = 18, _eacces = 13;

/// A [NativeRootFs] whose top folders Music, Videos and Documents resolve in
/// shared storage (spec #52, [PhoneFolderRouting]). Platform-neutral: the
/// Android adapter extends it, and the Linux tests run it with a temporary
/// folder standing in for shared storage.
///
/// Only the attached private root descriptor and private staging descriptor
/// are routed. For the root, an engine path whose first component is a top
/// folder becomes the phone path beneath the shared volume's descriptor
/// (`Videos/x` -> `Movies/x`); everything else passes through unchanged. For
/// staging, a name starting with [sharedStagingTag] lives in the shared
/// staging folder, on the phone folders' volume, so installs stay atomic
/// same-volume renames (AC0). While paused the three folders are absent
/// from every listing and every operation on them is refused, so nothing
/// can read their absence as a deletion.
class MappedRootFs extends NativeRootFs implements PhoneFolderRouting {
  MappedRootFs(
    this.layout, [
    super.library,
    super.errnoLabel,
    super.fullVerificationInterval,
  ]) : _paused = layout.paused;

  @override
  final PhoneFolderLayout layout;

  bool _paused;
  int? _root, _stage, _base, _shared;
  final Set<String> _media = {};

  @override
  bool get paused => _paused || _base == null && _root != null;

  @override
  void attach(int rootFd, int stageFd) {
    _root = rootFd;
    _stage = stageFd;
    if (!_paused) _openShared();
  }

  @override
  void setPaused(bool paused) {
    _paused = paused;
    if (paused) {
      _closeShared();
    } else if (_root != null && _base == null) {
      _openShared();
    }
  }

  void _openShared() {
    try {
      _base = openRoot(layout.base);
      final staging = Directory(layout.staging)..createSync(recursive: true);
      privateDir(layout.staging);
      // The media library never indexes staged bytes (spec #52 Sync Rules).
      final marker = File('${staging.path}/.nomedia');
      if (!marker.existsSync()) marker.writeAsStringSync('');
      _shared = openRoot(layout.staging);
      // Copies an interrupted install left (decision #130 (4)); no install
      // runs before the engine starts.
      for (final item in super.scan(_shared!)) {
        final name = item['path'] as String;
        if (!name.contains('/') &&
            name.startsWith(_installTemp) &&
            item['kind'] == 'file') {
          try {
            File('${layout.staging}/$name').deleteSync();
          } on FileSystemException {
            // Left for the next start.
          }
        }
      }
    } on FileSystemException {
      // Shared storage unavailable (an OS update, no access): paused.
      _closeShared();
    }
  }

  static const _installTemp = '.anj-install-';

  void _closeShared() {
    for (final fd in [_base, _shared]) {
      if (fd != null) closeFd(fd);
    }
    _base = null;
    _shared = null;
  }

  static String? _topOf(String path) {
    final slash = path.indexOf('/');
    final top = slash < 0 ? path : path.substring(0, slash);
    return phoneFolderNames.containsKey(top) ? top : null;
  }

  Never _refusePaused(String path) => throw FileSystemException(
    'Music, Videos and Documents are paused: allow All files access',
    path,
    const OSError('All files access is missing', _eacces),
  );

  /// The descriptor and path [path] beneath [fd] really is.
  (int, String) _at(int fd, String path) {
    if (fd == _root) {
      final top = _topOf(path);
      if (top == null) return (fd, path);
      final base = _base;
      if (paused || base == null) _refusePaused(path);
      return (base, '${phoneFolderNames[top]}${path.substring(top.length)}');
    }
    if (fd == _stage && path.startsWith(sharedStagingTag)) {
      final shared = _shared;
      if (shared == null) _refusePaused(path);
      return (shared, path);
    }
    return (fd, path);
  }

  bool _routed(int fd, String path) =>
      fd == _root && _topOf(path) != null ||
      fd == _stage && path.startsWith(sharedStagingTag);

  /// The engine path of the phone path [phone] (`Movies/x` -> `Videos/x`).
  static String _engine(String phone) {
    final slash = phone.indexOf('/');
    final first = slash < 0 ? phone : phone.substring(0, slash);
    for (final MapEntry(key: top, value: name) in phoneFolderNames.entries) {
      if (name == first) return '$top${phone.substring(first.length)}';
    }
    return phone;
  }

  @override
  String? absolutePath(String relative) {
    final top = _topOf(relative);
    return top == null
        ? null
        : '${layout.folder(top)}${relative.substring(top.length)}';
  }

  @override
  String? get sharedStagePath {
    final shared = _shared;
    return shared == null ? null : stagePath(shared);
  }

  @override
  List<String> drainMediaScans() {
    final paths = _media.toList()..sort();
    _media.clear();
    return paths;
  }

  void _changed(int fd, String path) {
    if (fd == _root && _topOf(path) != null) {
      final absolute = absolutePath(path);
      if (absolute != null) _media.add(absolute);
    }
  }

  /// Phone folder storage compares names case-insensitively (casefolded
  /// shared storage, AC0); the private root does not.
  @override
  bool caseInsensitive(String rootPath) =>
      rootPath == layout.base || rootPath.startsWith('${layout.base}/')
      ? true
      : super.caseInsensitive(rootPath);

  // Listings.

  Map<String, dynamic> _renamed(Map<String, dynamic> item) => {
    ...item,
    'path': _engine(item['path'] as String),
    if (item['stored'] is String) 'stored': _engine(item['stored'] as String),
  };

  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  _area(Pointer<Void>? handle, String top, bool recursive) {
    final listed = super.watchScan(
      handle,
      _base!,
      phoneFolderNames[top]!,
      recursive,
    );
    return (
      items: listed.items.map(_renamed).toList(),
      watches: listed.watches.map(_renamed).toList(),
    );
  }

  bool _privateTop(Map<String, dynamic> item) =>
      _topOf(item['path'] as String) != null;

  @override
  List<Map<String, dynamic>> scan(int fd) {
    if (fd == _root) {
      final items = super.scan(fd).where((i) => !_privateTop(i)).toList();
      if (!paused) {
        for (final top in phoneFolderNames.keys) {
          items.addAll(_area(null, top, true).items);
        }
      }
      return items;
    }
    final shared = _shared;
    if (fd == _stage && shared != null) {
      return [
        ...super.scan(fd),
        for (final item in super.scan(shared))
          if ((item['path'] as String).startsWith(sharedStagingTag)) item,
      ];
    }
    return super.scan(fd);
  }

  @override
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive) {
    if (root == _root && path.isEmpty) {
      final private = super.watchScan(handle, root, path, recursive);
      final items = private.items.where((i) => !_privateTop(i)).toList();
      final watches = private.watches.where((w) => !_privateTop(w)).toList();
      if (!paused) {
        for (final top in phoneFolderNames.keys) {
          final area = _area(recursive ? handle : null, top, recursive);
          items.addAll(area.items);
          watches.addAll(area.watches);
        }
      }
      return (items: items, watches: watches);
    }
    if (!_routed(root, path)) {
      return super.watchScan(handle, root, path, recursive);
    }
    final (fd, at) = _at(root, path);
    final listed = super.watchScan(handle, fd, at, recursive);
    if (fd != _base) return listed;
    return (
      items: listed.items.map(_renamed).toList(),
      watches: listed.watches.map(_renamed).toList(),
    );
  }

  @override
  ({int wd, String identity}) watchAdd(
    Pointer<Void> handle,
    int root,
    String path,
  ) {
    final (fd, at) = _at(root, path);
    return super.watchAdd(handle, fd, at);
  }

  // Path operations.

  @override
  void makeDir(int fd, String path) {
    final (at, routed) = _at(fd, path);
    super.makeDir(at, routed);
  }

  @override
  void makeDirExclusive(int fd, String path) {
    final (at, routed) = _at(fd, path);
    super.makeDirExclusive(at, routed);
  }

  @override
  String fileIdentity(int fd, String path) {
    final (at, routed) = _at(fd, path);
    return super.fileIdentity(at, routed);
  }

  @override
  String directoryIdentity(int fd, String path) {
    final (at, routed) = _at(fd, path);
    return super.directoryIdentity(at, routed);
  }

  @override
  void installDirectory(
    int root,
    int stage,
    String staged,
    String path,
    String parentIdentity,
    String identity,
  ) {
    final (r, p) = _at(root, path);
    final (s, n) = _at(stage, staged);
    super.installDirectory(r, s, n, p, parentIdentity, identity);
    _changed(root, path);
  }

  @override
  void removeEmptyDir(int fd, String path, String identity) {
    final (at, routed) = _at(fd, path);
    super.removeEmptyDir(at, routed, identity);
    _changed(fd, path);
  }

  @override
  void install(int fd, String relative, String stage) {
    final (at, routed) = _at(fd, relative);
    try {
      super.install(at, routed, stage);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != _exdev || at != _base) rethrow;
      // A staged file in private staging (made before this install mapped
      // the folders): copied to shared staging first, then installed there.
      final temp = '${layout.staging}/$_installTemp${uniqueId()}';
      _copyDurably(File(stage), File(temp));
      try {
        super.install(at, routed, temp);
      } finally {
        _deleteQuietly(temp);
      }
    }
    _changed(fd, relative);
  }

  @override
  void quarantine(int fd, String relative, String stage) {
    final (at, routed) = _at(fd, relative);
    super.quarantine(at, routed, stage);
    _changed(fd, relative);
  }

  @override
  int openRead(int fd, String path) {
    final (at, routed) = _at(fd, path);
    return super.openRead(at, routed);
  }

  @override
  int createExclusive(int fd, String path) {
    final (at, routed) = _at(fd, path);
    return super.createExclusive(at, routed);
  }

  @override
  void renameExclusive(int fd, String from, String to, String identity) {
    final (f, fromAt) = _at(fd, from);
    final (t, toAt) = _at(fd, to);
    if (f != t) {
      throw FileSystemException(
        'Filesystem boundary refused operation',
        from,
        OSError(errnoLabel, _exdev),
      );
    }
    super.renameExclusive(f, fromAt, toAt, identity);
    _changed(fd, from);
    _changed(fd, to);
  }

  @override
  int fsMagic(int fd, String path) {
    if (path.isEmpty) return super.fsMagic(fd, path);
    final (at, routed) = _at(fd, path);
    return super.fsMagic(at, routed);
  }

  @override
  ({String hash, String stamp}) copyAndHashStamped(
    int root,
    String relative,
    File? destination, {
    String purpose = 'content',
  }) {
    final (at, routed) = _at(root, relative);
    return super.copyAndHashStamped(at, routed, destination, purpose: purpose);
  }

  @override
  ReleaseGuard releaseGuard() => _MappedGuard(this, super.releaseGuard());

  void _copyDurably(File from, File to) {
    final input = from.openSync();
    final output = to.openSync(mode: FileMode.writeOnly);
    try {
      final buffer = List<int>.filled(256 * 1024, 0);
      while (true) {
        final n = input.readIntoSync(buffer);
        if (n == 0) break;
        output.writeFromSync(buffer, 0, n);
      }
      output.flushSync();
    } finally {
      input.closeSync();
      output.closeSync();
    }
  }

  static void _deleteQuietly(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Removed at the next start (an `.anj-install-` copy).
    }
  }

  static String _sha(File file) {
    final digest = _Digest();
    final sink = sha256.startChunkedConversion(digest);
    final input = file.openSync();
    try {
      final buffer = List<int>.filled(256 * 1024, 0);
      while (true) {
        final n = input.readIntoSync(buffer);
        if (n == 0) break;
        sink.add(buffer.sublist(0, n));
      }
    } finally {
      input.closeSync();
    }
    sink.close();
    return digest.value!;
  }
}

/// The release guard of [MappedRootFs]: the same guard, with root paths and
/// staging names resolved as the filesystem resolves them.
class _MappedGuard implements ReleaseGuard {
  _MappedGuard(this.fs, this.inner);
  final MappedRootFs fs;
  final ReleaseGuard inner;

  @override
  ReleaseGuardStrength get strength => inner.strength;

  @override
  NativeFileInfo preview(int directory, String name) {
    final (d, n) = fs._at(directory, name);
    return inner.preview(d, n);
  }

  @override
  NativeFileInfo info(int directory, String path) {
    final (d, p) = fs._at(directory, path);
    return inner.info(d, p);
  }

  @override
  NativeFileInfo infoFd(int fd) => inner.infoFd(fd);

  @override
  int create(int directory, String name) {
    final (d, n) = fs._at(directory, name);
    return inner.create(d, n);
  }

  @override
  int guard(
    int directory,
    String path,
    NativeFileInfo expected, {
    required int links,
  }) {
    final (d, p) = fs._at(directory, path);
    return inner.guard(d, p, expected, links: links);
  }

  @override
  void valid(int fd) => inner.valid(fd);

  @override
  void close(int fd) => inner.close(fd);

  @override
  String hash(int fd, {String purpose = 'eviction'}) =>
      inner.hash(fd, purpose: purpose);

  @override
  void preserve(int root, String path, int stage, String name) {
    final (r, p) = fs._at(root, path);
    final (s, n) = fs._at(stage, name);
    inner.preserve(r, p, s, n);
    fs._changed(root, path);
  }

  @override
  void install(int root, String path, int stage, String name) {
    final (r, p) = fs._at(root, path);
    final (s, n) = fs._at(stage, name);
    if (r == fs._base && s != fs._shared) {
      // Private staging bytes for a phone folder (made before the folders
      // were mapped): a durable copy in shared staging is installed instead,
      // and the staged name survives as [install] promises.
      final temp = '${MappedRootFs._installTemp}${uniqueId()}';
      fs._copyDurably(
        File('${fs.stagePath(s)}/$n'),
        File('${fs.layout.staging}/$temp'),
      );
      try {
        inner.restore(r, p, fs._shared!, temp);
      } finally {
        MappedRootFs._deleteQuietly('${fs.layout.staging}/$temp');
      }
    } else {
      inner.install(r, p, s, n);
    }
    fs._changed(root, path);
  }

  @override
  void restore(int root, String path, int stage, String name) {
    final (r, p) = fs._at(root, path);
    final (s, n) = fs._at(stage, name);
    if (r == fs._base && s != fs._shared) {
      _restoreAcross(r, p, s, n);
    } else {
      inner.restore(r, p, s, n);
    }
    fs._changed(root, path);
  }

  /// A rename into a phone folder from private staging cannot be made (the
  /// volumes differ, EXDEV): the bytes are copied durably into shared
  /// staging and renamed into place from there, never replacing a file,
  /// and only then is the private staged file removed. An interrupted run
  /// is finished by the next: a destination holding exactly the staged
  /// bytes is that earlier rename.
  void _restoreAcross(int root, String path, int stage, String name) {
    final source = File('${fs.stagePath(stage)}/$name');
    final target = File('${fs.layout.base}/$path');
    if (target.existsSync() &&
        target.lengthSync() == source.lengthSync() &&
        MappedRootFs._sha(target) == MappedRootFs._sha(source)) {
      source.deleteSync();
      return;
    }
    final temp = '${MappedRootFs._installTemp}${uniqueId()}';
    fs._copyDurably(source, File('${fs.layout.staging}/$temp'));
    try {
      inner.restore(root, path, fs._shared!, temp);
    } catch (_) {
      MappedRootFs._deleteQuietly('${fs.layout.staging}/$temp');
      rethrow;
    }
    source.deleteSync();
  }

  @override
  void quarantine(int guardFd, int root, String path, int stage, String name) {
    final (r, p) = fs._at(root, path);
    final (s, n) = fs._at(stage, name);
    inner.quarantine(guardFd, r, p, s, n);
    fs._changed(root, path);
  }

  @override
  void unlink(int guardFd, int stage, String name) {
    final (s, n) = fs._at(stage, name);
    inner.unlink(guardFd, s, n);
  }
}

class _Digest implements Sink<Digest> {
  String? value;
  @override
  void add(Digest data) => value = data.toString();
  @override
  void close() {}
}
