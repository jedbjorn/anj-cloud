import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../ports/root_filesystem.dart';
import '../state/model.dart';
import '../sync/name_policy.dart';
import '../sync/sync_path_policy.dart';
import '../sync/top_folders.dart';

/// The answer of [RootTree.probeStaging].
enum StagingProbe { inside, otherDevice, unknown }

class _Decider {
  _Decider(this.seen, this.call);
  final Set<String> seen;
  final LocalItem? Function(Map<String, dynamic> item, bool includeExcluded)
  call;
}

String uniqueId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// EBUSY in the boundary's errno numbering (the same on every platform).
const fileBusyErrno = 16;

void validateRelative(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\x00') ||
      path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw const FileSystemException('Invalid relative path');
  }
}

/// Content access is routed through the native root descriptor. Owned private
/// staging is outside the synchronized root. No destructive eviction API yet.
class RootTree {
  RootTree(this.root, this.staging, this.native)
    : fd = native.openRoot(root.path) {
    staging.createSync(recursive: true);
    native.privateDir(staging.path);
    stageFd = native.openRoot(staging.path);
  }
  final Directory root;
  final Directory staging;
  final RootFilesystem native;
  final int fd;
  late final int stageFd;

  /// Creates (or, for a picked folder, reuses) `<parent>/anj-cloud/` with
  /// `Music`, `Videos` and `Documents`, and the profile's private staging.
  ///
  /// [requireNew] (the automatic root, spec #34 P1): an existing
  /// `anj-cloud/` is refused rather than adopted, so another tool's or an
  /// earlier install's folder is never taken over (decision #82).
  /// [profileDir]: staging goes inside it when renames reach the root from
  /// there (spec #34 P3, [stagingFor]); without it (fixtures that have no
  /// profile) staging is the earlier `.anj-cloud-<profileId>` sibling.
  static RootTree setup(
    String parent,
    String profileId,
    RootFilesystem native, {
    List<String> knownRoots = const [],
    String? profileDir,
    bool requireNew = false,
  }) {
    final canonical = Directory(parent).resolveSymbolicLinksSync();
    final root = Directory(p.join(canonical, 'anj-cloud'));
    for (final other in knownRoots) {
      final normalized =
          FileSystemEntity.typeSync(other) == FileSystemEntityType.directory
          ? Directory(other).resolveSymbolicLinksSync()
          : p.normalize(p.absolute(other));
      if (p.equals(root.path, normalized) ||
          p.isWithin(normalized, root.path) ||
          p.isWithin(root.path, normalized)) {
        throw const FileSystemException(
          'Choose a root that does not overlap another synchronizer or profile.',
        );
      }
    }
    final existing = FileSystemEntity.typeSync(root.path, followLinks: false);
    if (existing == FileSystemEntityType.notFound) {
      root.createSync();
    } else if (requireNew) {
      throw FileSystemException(
        '${root.path} already exists, so it was not used: AnJ Cloud never '
        'takes over an existing folder. Use another folder, or move that one '
        'away and restart.',
        root.path,
      );
    }
    final tree = RootTree(
      root,
      profileDir == null
          ? Directory(p.join(canonical, '.anj-cloud-$profileId'))
          : stagingFor(root, profileDir, profileId, native),
      native,
    );
    for (final name in ['Music', 'Videos', 'Documents']) {
      tree.ensureDirectory(name, keptTop: true);
    }
    return tree;
  }

  /// Private staging for a new profile's [root] (spec #34 P3):
  /// `<profileDir>/staging/` when [probeStaging] finds that renames reach the
  /// root from there; otherwise (another volume, or no definite answer) the
  /// dot-named sibling of [root], `.anj-cloud-staging-<first 8 of
  /// profileId>`. Downloads are placed by rename or hard link, so staging
  /// must share the root's filesystem.
  static Directory stagingFor(
    Directory root,
    String profileDir,
    String profileId,
    RootFilesystem native,
  ) => probeStaging(root, profileDir, native) == StagingProbe.inside
      ? Directory(p.join(profileDir, 'staging'))
      : siblingStaging(root, profileId);

  /// The dot-named staging beside [root] (spec #34 P3, other volume).
  static Directory siblingStaging(
    Directory root,
    String profileId,
  ) => Directory(
    p.join(
      p.dirname(root.path),
      '.anj-cloud-staging-${profileId.length > 8 ? profileId.substring(0, 8) : profileId}',
    ),
  );

  /// Whether `<profileDir>/staging/` can stage for [root] (spec #34 P3):
  /// [StagingProbe.inside] when its volume key equals the root's (equal keys
  /// separate btrfs subvolumes) and an empty probe folder renames into the
  /// root and back (a bind mount of the same volume refuses with EXDEV);
  /// [StagingProbe.otherDevice] only on a definite answer (unequal volume
  /// keys, or EXDEV); [StagingProbe.unknown] on any other failure. Creates
  /// `<profileDir>/staging/` only for an `inside` answer. Stale probes left
  /// in the root by an interrupted earlier probe are removed first.
  static StagingProbe probeStaging(
    Directory root,
    String profileDir,
    RootFilesystem native,
  ) {
    sweepProbes(root);
    final inside = Directory(p.join(profileDir, 'staging'));
    final created = !inside.existsSync();
    StagingProbe answer;
    try {
      if (created) inside.createSync();
      answer = _probe(inside, root, native);
    } on Object {
      answer = StagingProbe.unknown;
    }
    if (answer != StagingProbe.inside && created) {
      try {
        inside.deleteSync();
      } on FileSystemException {
        // Left empty and unused; never anything but our own empty folder.
      }
    }
    return answer;
  }

  /// Removes empty `.anj-cloud-probe-<id>` folders from the top of [root]
  /// (rmdir only: one that gained content is left, and is never synced).
  static void sweepProbes(Directory root) {
    try {
      for (final entry in root.listSync(followLinks: false)) {
        if (entry is Directory &&
            stagingProbeName.hasMatch(p.basename(entry.path))) {
          try {
            entry.deleteSync();
          } on FileSystemException {
            // Not empty or not ours to judge: excluded from sync anyway.
          }
        }
      }
    } on FileSystemException {
      // An unreadable root is reported by the root checks, not here.
    }
  }

  static StagingProbe _probe(
    Directory from,
    Directory root,
    RootFilesystem native,
  ) {
    String volume(String path) {
      final fd = native.openRoot(path);
      try {
        return native.identity(fd).split(':').first;
      } finally {
        native.closeFd(fd);
      }
    }

    if (volume(from.path) != volume(root.path)) return StagingProbe.otherDevice;
    final name = '.anj-cloud-probe-${uniqueId()}';
    final probe = Directory(p.join(from.path, name))..createSync();
    final there = p.join(root.path, name);
    try {
      probe.renameSync(there);
    } on FileSystemException catch (error) {
      probe.deleteSync();
      return error.osError?.errorCode == _exdev
          ? StagingProbe.otherDevice
          : StagingProbe.unknown;
    }
    try {
      Directory(there).renameSync(probe.path);
      probe.deleteSync();
    } on FileSystemException {
      // Not back: remove it from the root (it is excluded from sync, and the
      // next setup sweeps it if this fails too).
      try {
        Directory(there).deleteSync();
      } on FileSystemException {
        // Swept later.
      }
    }
    return StagingProbe.inside;
  }

  /// EXDEV ("Invalid cross-device link") on Linux and macOS.
  static const _exdev = 18;

  /// Files a pass could not read because another program holds them open
  /// without read sharing (EBUSY from the boundary). The engine neither
  /// uploads, downloads over, nor infers a deletion for them, and shows them
  /// as busy; each later pass tries them again. A full scan starts afresh.
  final Set<String> busy = {};

  /// Stored index for a path (set by the engine): the stamp, the hash read
  /// with it, when that read began (wall-clock microseconds) and whether that
  /// read was final (taken at least [confirmMicros] after the last ctime).
  ({String stamp, String hash, int at, bool confirmed})? Function(String path)?
  index;

  /// Test seams: a fake filesystem type and a coarser stamp view (to model
  /// filesystems whose timestamps cannot separate two writes). The view maps
  /// a `volume:ino:size:mtime_ns:ctime_ns` stamp to another of the same shape.
  int? debugFsMagic;
  String Function(String stamp)? debugStampView;
  int Function() wallMicros = () => DateTime.now().microsecondsSinceEpoch;

  /// A hash read within this margin after the file's ctime is rehashed on the
  /// next pass (a same-tick write may hide behind an identical stamp).
  static const racyMarginMicros = 2000000;

  /// Test seam: a directory holding the writeback sysctls' file names, read
  /// instead of the platform's source ([RootFilesystem.writeback]).
  String? vmDirectory;

  /// Lower bound of the confirmation margin (test seam; 60 s in the product).
  int confirmFloorMicros = 60000000;

  /// Test seam replacing the computed margin (a real-disk test cannot wait
  /// the system's real M).
  int? debugConfirmMicros;

  /// Monotonic microseconds (does not jump with the wall clock; test seam).
  int Function() monoMicros = () => _monotonic.elapsedMicroseconds;
  static final Stopwatch _monotonic = Stopwatch()..start();

  /// Periodic writeback state from the most recent pass. The fast path needs
  /// `dirty_writeback_centisecs` > 0 and `laptop_mode` == 0; an unreadable
  /// value also turns it off. Off means every file is hashed and no stamp is
  /// stored.
  bool writebackEnabled = false;

  /// Confirmation margin M = max(60 s, 2 x (dirty_expire + dirty_writeback))
  /// from the most recent pass. After it, a page dirtied before the last hash
  /// has been written back, so a later write through a shared mapping faults
  /// and moves ctime. Re-read each pass, so a later larger M (e.g. laptop
  /// tools on battery) applies to every hash not yet final.
  int confirmMicros = 60000000;

  void _readWriteback() {
    try {
      final values = native.writeback(directory: vmDirectory);
      if (values == null) throw const FileSystemException('No writeback');
      final expire = values.expireCentisecs;
      final interval = values.writebackCentisecs;
      final laptop = values.laptopMode;
      writebackEnabled = interval > 0 && laptop == 0 && expire >= 0;
      confirmMicros =
          debugConfirmMicros ??
          max(confirmFloorMicros, 2 * (expire + interval) * 10000);
    } on Object {
      writebackEnabled = false;
      confirmMicros = debugConfirmMicros ?? confirmFloorMicros;
    }
  }

  /// When this process first observed each path's current stamp (monotonic).
  /// Not persisted: after a restart observation starts again, which can only
  /// delay finality.
  final Map<String, ({String stamp, int at})> _firstSeen = {};

  String _view(String stamp) => debugStampView?.call(stamp) ?? stamp;

  /// Stat-only enumeration: no file content is read.
  Map<String, LocalItem> scanItems({bool includeExcluded = false}) {
    native.checkRoot(fd, root.path);
    final result = <String, LocalItem>{};
    for (final item in native.scan(fd)) {
      final path = item['path'] as String;
      final kind = ItemKind.values.byName(item['kind'] as String);
      if (isSyncExcluded(path) && !includeExcluded) continue;
      result[path] = LocalItem(
        path,
        kind,
        size: item['size'] as int,
        identity: "${item['volume']}:${item['inode']}",
        links: item['links'] as int?,
        birth: item['birth'] as int?,
        scanStamp: _scanStamp(item),
      );
    }
    native.checkRoot(fd, root.path);
    return result;
  }

  String _scanStamp(Map<String, dynamic> item) =>
      "${item['volume']}:${item['inode']}:${item['size']}:"
      "${item['mtime']}:${item['ctime']}";

  Future<Map<String, LocalItem>> snapshot({
    bool includeExcluded = false,
  }) async {
    native.checkRoot(fd, root.path);
    _readWriteback();
    busy.clear();
    final decide = _decider();
    final result = <String, LocalItem>{};
    for (final item in native.scan(fd)) {
      final value = decide.call(item, includeExcluded);
      if (value != null) result[value.path] = value;
    }
    _pruneSeen(decide.seen);
    native.checkRoot(fd, root.path);
    return result;
  }

  /// Stamps recorded right after this client's own operations in the root
  /// (installs whose bytes it hashed itself). While a file still shows the
  /// recorded stamp its hash is reused, so the event caused by the operation
  /// reads nothing; the confirmation hash after M still runs (decision #39).
  final Map<String, ({String stamp, String hash, int at})> ownStamps = {};

  /// Stat-only listing of [path] ('' is the whole root) through the
  /// descriptor-bound boundary, with content decided exactly as [snapshot]
  /// does (index reuse, confirmation, untrusted filesystems). With [watch],
  /// each directory is watched before it is read. Excluded items are kept.
  /// [reuse] (event-driven hashing only, decision #130 (3)) supplies hashes
  /// for files whose scan stamp is exactly the one they were hashed at, in
  /// place of a read; it never applies where stamps are trusted.
  ({Map<String, LocalItem> items, List<Map<String, dynamic>> watches}) scanTree(
    String path, {
    required bool recursive,
    Pointer<Void>? watch,
    Map<String, LocalItem>? reuse,
  }) {
    if (path.isNotEmpty) validateRelative(path);
    native.checkRoot(fd, root.path);
    // What this listing reads is decided afresh, as in [snapshot].
    busy.removeWhere(
      (held) =>
          path.isEmpty && recursive ||
          held == path ||
          (recursive
              ? p.posix.isWithin(path, held)
              : p.posix.dirname(held) == (path.isEmpty ? '.' : path)),
    );
    final listed = _exact(path, native.watchScan(watch, fd, path, recursive));
    final decide = _decider(reuse: reuse);
    final items = <String, LocalItem>{};
    for (final item in listed.items) {
      final value = decide.call(item, true);
      if (value != null) items[value.path] = value;
    }
    if (path.isEmpty && recursive) _pruneSeen(decide.seen);
    native.checkRoot(fd, root.path);
    return (items: items, watches: listed.watches);
  }

  /// Whether this filesystem gives a change made after a stat a ctime
  /// distinct from the one that stat returned (Linux multigrain timestamps).
  /// Only then may an own install's recorded stamp stand in for a hash
  /// without the racy-timestamp margin: a user write in the same coarse
  /// tick would otherwise keep the stamp. Probed once in private staging
  /// when it shares the root's filesystem; otherwise assumed coarse.
  bool get fineCtime => debugFineCtime ?? (_fineCtime ??= _probeCtime());
  bool? debugFineCtime;
  bool? _fineCtime;

  bool _probeCtime() {
    File? probe;
    RandomAccessFile? handle;
    try {
      if (native.identity(stageFd).split(':').first !=
          native.identity(fd).split(':').first) {
        return false;
      }
      probe = newStagedFile('ctime-probe')..createSync();
      handle = probe.openSync(mode: FileMode.append);
      final name = p.basename(probe.path);
      int ctime() =>
          native.watchScan(null, stageFd, name, false).items.single['ctime']
              as int;
      var previous = ctime();
      for (var i = 0; i < 20; i++) {
        handle.writeByteSync(i);
        final next = ctime();
        if (next == previous) return false;
        previous = next;
      }
      return true;
    } on Object {
      return false;
    } finally {
      handle?.closeSync();
      try {
        probe?.deleteSync();
      } on FileSystemException {
        // A leftover probe is harmless private staging content.
      }
    }
  }

  /// Re-reads the writeback sysctls (once per pass; [snapshot] does it
  /// itself). Decision #39: M and the fast-path switch follow runtime changes.
  void refreshWriteback() => _readWriteback();

  /// First observation (monotonic) of [path]'s current stamp.
  int _observe(String path, String viewed, int monoNow) {
    final first = _firstSeen[path];
    if (first != null && first.stamp == viewed) return first.at;
    _firstSeen[path] = (stamp: viewed, at: monoNow);
    return monoNow;
  }

  void _pruneSeen(Set<String> seen) =>
      _firstSeen.removeWhere((path, _) => !seen.contains(path));

  /// Forgets per-path observation state of a path that no longer exists.
  void forget(String path) {
    _firstSeen.remove(path);
    ownStamps.remove(path);
  }

  /// Monotonic time at which a non-final hash of [scanStamp] at [path]
  /// becomes confirmable: M after its ctime (converted from the wall clock
  /// now) and M after this process first observed the stamp (#39). A wall
  /// clock step can only make the scan at that time reuse once more and
  /// reschedule, never finalize early.
  int confirmDueMono(String path, String scanStamp) {
    final monoNow = monoMicros();
    final first = _observe(path, _view(scanStamp), monoNow);
    final byWall =
        monoNow + changedAtMicros(scanStamp) + confirmMicros - wallMicros();
    return max(first + confirmMicros, byWall) + 1;
  }

  /// One item's type and stamp without reading content (null when absent).
  LocalItem? statItem(String path) {
    validateRelative(path);
    final listed = _exact(path, native.watchScan(null, fd, path, false)).items;
    if (listed.isEmpty) return null;
    final item = listed.single;
    return LocalItem(
      path,
      ItemKind.values.byName(item['kind'] as String),
      size: item['size'] as int,
      identity: "${item['volume']}:${item['inode']}",
      links: item['links'] as int?,
      birth: item['birth'] as int?,
      scanStamp: _scanStamp(item),
    );
  }

  /// Stored spellings met by [scanTree] or [statItem] since the engine last
  /// took them: the new side of a case- or normalization-only rename, which
  /// the engine rescans in the same pass (PR #68 review), so the pair never
  /// depends on the watcher delivering it in time.
  final Set<String> storedSpellings = {};

  /// Decision #137 (2): a listing whose [path] resolved to an entry stored
  /// under a spelling that differs only by case or normalization (a rename
  /// on APFS) is the old path gone; the stored spelling is kept in
  /// [storedSpellings]. Any other difference (a hard-linked file whose
  /// stored name is another link's, PR #68 review) leaves [path] present as
  /// asked.
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  _exact(
    String path,
    ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
    listed,
  ) {
    if (listed.items.isEmpty) return listed;
    final stored = listed.items.first['stored'] as String?;
    if (stored == null || stored == path) return listed;
    if (!sameSpelling(stored, path)) return listed;
    storedSpellings.add(stored);
    return (items: const [], watches: const []);
  }

  /// Whether two root-relative paths differ only by case or Unicode
  /// normalization, component by component.
  static bool sameSpelling(String a, String b) {
    final x = a.split('/'), y = b.split('/');
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i] &&
          NamePolicy.foldKey(x[i]) != NamePolicy.foldKey(y[i])) {
        return false;
      }
    }
    return true;
  }

  /// Whether a stamp on [volume] (holding [path]) may be stored and reused.
  bool trustsStamps(String volume, String path) =>
      writebackEnabled && _trustedVolume({}, volume, path);

  /// Whether stamps on the root's own volume are trusted, as of the last
  /// writeback read (#39); false when the volume cannot be identified.
  bool get rootStampsTrusted {
    if (!writebackEnabled) return false;
    try {
      return trustsStamps(native.identity(fd).split(':').first, '');
    } on FileSystemException {
      return false;
    }
  }

  bool _trustedVolume(Map<String, bool> cache, String volume, String path) =>
      cache.putIfAbsent(volume, () {
        try {
          final rootVolume = native.identity(fd).split(':').first;
          return native.trustedFsMagic.contains(
            debugFsMagic ??
                native.fsMagic(fd, volume == rootVolume ? '' : path),
          );
        } on FileSystemException {
          return false;
        }
      });

  /// Wall-clock microseconds of the last change (ctime) of a stamp, as the
  /// index rules see it (through [debugStampView]).
  int changedAtMicros(String scanStamp) =>
      int.parse(_view(scanStamp).split(':')[4]) ~/ 1000;

  _Decider _decider({Map<String, LocalItem>? reuse}) {
    // Any item on another mounted filesystem is judged by its own type.
    // An unknown type disables reuse: every such file is hashed as before.
    final trusted = <String, bool>{};
    final now = wallMicros();
    final monoNow = monoMicros();
    final seen = <String>{};
    return _Decider(seen, (item, includeExcluded) {
      final path = item['path'] as String;
      final kind = ItemKind.values.byName(item['kind'] as String);
      final excluded = isSyncExcluded(path);
      if (excluded && !includeExcluded) return null;
      final scanStamp = _scanStamp(item);
      String? hash;
      String? stamp;
      int? stampedAt;
      var stampFinal = false;
      if (kind == ItemKind.file && !excluded) {
        // Where stamps cannot be trusted every pass hashes and nothing is
        // stored, so an idle pass writes no rows.
        final trusted0 =
            writebackEnabled &&
            _trustedVolume(trusted, item['volume'] as String, path);
        final viewed = _view(scanStamp);
        final first = _observe(path, viewed, monoNow);
        seen.add(path);
        // M must have passed on both clocks: since the last ctime (wall) and
        // since this process first saw the stamp (monotonic), so a forward
        // wall-clock step cannot finalize a hash before writeback (#39).
        final observedFor = monoNow - first;
        // ctime only: the kernel sets it on every change, while mtime may be
        // set to any value (a future mtime must not defeat reuse).
        final changedAt = int.parse(viewed.split(':')[4]) ~/ 1000;
        final own = trusted0 ? ownStamps[path] : null;
        if (own != null &&
            own.stamp == scanStamp &&
            (changedAt >= now - confirmMicros || observedFor < confirmMicros)) {
          // Our own operation's result, unchanged since: no read until the
          // confirmation hash is due.
          return LocalItem(
            path,
            kind,
            hash: own.hash,
            size: item['size'] as int,
            identity: "${item['volume']}:${item['inode']}",
            links: item['links'] as int?,
            birth: item['birth'] as int?,
            scanStamp: scanStamp,
            stamp: scanStamp,
            stampedAt: own.at,
          );
        }
        if (own != null) ownStamps.remove(path);
        final stored = trusted0 ? index?.call(path) : null;
        if (stored != null &&
            _view(stored.stamp) == _view(scanStamp) &&
            changedAt < stored.at - racyMarginMicros &&
            stored.at <= now &&
            // Not final yet: reuse only until the change is older than M,
            // then read once more (the confirmation hash).
            (stored.confirmed ||
                changedAt >= now - confirmMicros ||
                observedFor < confirmMicros)) {
          hash = stored.hash;
          stamp = stored.stamp;
          stampedAt = stored.at;
          stampFinal = stored.confirmed;
        } else if (!trusted0 &&
            reuse?[path]?.hash != null &&
            reuse![path]!.kind == ItemKind.file &&
            reuse[path]!.scanStamp == scanStamp) {
          hash = reuse[path]!.hash;
        } else {
          final began = wallMicros();
          final ({String hash, String stamp}) read;
          try {
            read = native.copyAndHashStamped(fd, path, null, purpose: 'scan');
          } on FileSystemException catch (error) {
            // Another program holds the file without read sharing (Windows
            // sharing modes; SC-048 F5): this pass leaves it out and the
            // engine changes nothing for it; a later pass reads it again.
            if (error.osError?.errorCode != fileBusyErrno) rethrow;
            busy.add(path);
            return null;
          }
          busy.remove(path);
          hash = read.hash;
          // Record the stamp only when the read proves it matches the scan.
          if (trusted0 && read.stamp == scanStamp) {
            stamp = scanStamp;
            stampedAt = began;
            stampFinal =
                began - changedAt >= confirmMicros &&
                observedFor >= confirmMicros;
          }
        }
      }
      return LocalItem(
        path,
        kind,
        hash: hash,
        size: item['size'] as int,
        identity: "${item['volume']}:${item['inode']}",
        links: item['links'] as int?,
        birth: item['birth'] as int?,
        scanStamp: scanStamp,
        stamp: stamp,
        stampedAt: stampedAt,
        stampFinal: stampFinal,
      );
    });
  }

  /// Validate an existing directory without materializing or enrolling content.
  String directoryLocation(String relative) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    final path = p.join(root.path, relative);
    final selected = native.openRoot(
      path,
    ); // Rejects symlinks in every component.
    try {
      native.checkRoot(fd, root.path);
      return path;
    } finally {
      native.closeFd(selected);
    }
  }

  /// Called after each of this client's own changes in the root, with the
  /// content hash when the change installed known bytes (set by the engine).
  /// [stagedStamp] is the staged file's stamp (`dev:ino:size:mtime_s:
  /// mtime_ns:...`) recorded when [hash] was taken.
  void Function(String path, {String? hash, String? stagedStamp})? onOwn;

  /// Reports an own change at [path] (see [onOwn]).
  void own(String path, {String? hash, String? stagedStamp}) =>
      onOwn?.call(path, hash: hash, stagedStamp: stagedStamp);

  /// Creates [relative] and any missing folders above it. `Documents`,
  /// `Music` and `Videos` themselves are created only with [keptTop] (root
  /// setup, the engine's per-pass check): anything else that finds one gone
  /// fails rather than bring it back half-empty, so the engine sees the
  /// deletion and restores the whole folder (spec #34 P7).
  void ensureDirectory(String relative, {bool keptTop = false}) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    var current = '';
    for (final segment in relative.split('/')) {
      current = current.isEmpty ? segment : '$current/$segment';
      if (!keptTop && isTopFolder(current)) {
        try {
          native.directoryIdentity(fd, current);
        } on FileSystemException catch (error) {
          throw FileSystemException(
            '$current is missing on this device; it is re-created and '
            'restored from the cloud by the next pass',
            current,
            error.osError,
          );
        }
        continue;
      }
      native.makeDir(fd, current);
      own(current);
    }
  }

  void removeEmptyDirectory(String relative, String identity) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    try {
      native.removeEmptyDir(fd, relative, identity);
    } finally {
      own(relative);
    }
  }

  File newStagedFile([String label = 'transfer']) =>
      File(p.join(staging.path, '$label-${uniqueId()}'));
  String snapshotFile(
    String relative,
    File target, {
    String purpose = 'content',
  }) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    return native.copyAndHash(fd, relative, target, purpose: purpose);
  }

  void installAbsent(String relative, File stage) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    final parent = p.posix.dirname(relative);
    if (parent != '.') ensureDirectory(parent);
    try {
      native.install(fd, relative, stage.path);
    } finally {
      own(relative);
    }
  }

  /// Kept bytes are deliberately retained. This is preservation, not disk-space
  /// release; a later qualified eviction finalizer may reclaim clean copies.
  File preserve(String relative) {
    validateRelative(relative);
    native.checkRoot(fd, root.path);
    final copy = newStagedFile('preserved');
    try {
      native.quarantine(fd, relative, copy.path);
    } finally {
      own(relative);
    }
    return copy;
  }

  File stagedFile(String path) {
    final name = p.basename(path);
    validateRelative(name);
    final through = native.stagePath(stageFd);
    if (p.dirname(path) != staging.path && p.dirname(path) != through) {
      throw const FileSystemException(
        'File is outside this private staging directory.',
      );
    }
    return File('$through/$name');
  }

  String durablePath(File file) => p.join(staging.path, p.basename(file.path));
  void close() {
    native.closeFd(stageFd);
    native.closeFd(fd);
  }
}

/// The modification time in a `volume:ino:size:mtime_ns:ctime_ns` scan
/// stamp, as Unix seconds; null when there is none.
int? modifiedSeconds(String? scanStamp) {
  if (scanStamp == null) return null;
  final parts = scanStamp.split(':');
  if (parts.length < 5) return null;
  final nanoseconds = int.tryParse(parts[parts.length - 2]);
  return nanoseconds == null ? null : nanoseconds ~/ 1000000000;
}
