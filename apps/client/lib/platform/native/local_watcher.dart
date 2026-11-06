import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/local/path_keys.dart';
import '../../core/ports/change_watcher.dart';
import 'native_root_fs.dart';

// inotify(7) masks used here.
const _inModify = 0x2;
const _inAttrib = 0x4;
const _inCloseWrite = 0x8;
const _inMovedFrom = 0x40;
const _inMovedTo = 0x80;
const _inCreate = 0x100;
const _inDelete = 0x200;
const _inDeleteSelf = 0x400;
const _inMoveSelf = 0x800;
const _inUnmount = 0x2000;
const inQueueOverflow = 0x4000;
const _inIgnored = 0x8000;
const _inIsDir = 0x40000000;

/// Add failures meaning the directory is gone or was replaced by a
/// non-directory (symbolic names, so errno numbering does not matter).
const _vanished = {'notFound', 'notDirectory', 'loop'};

/// Synthetic watch descriptors: a suspend (native wait), a test-only
/// request to fail the watcher isolate, a backlog the isolate could not hold
/// while the worker was busy, and a change of the mount table.
const _suspendRecord = -2;
const _killRecord = -3;
const _backlogRecord = -4;
const _mountRecord = -5;

class _Pending {
  _Pending(this.first, this.last, this.subtree);
  final int first;
  int last;
  bool subtree;
}

String _parentOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// Native watching of one enrolled root (spec #15), over any library that
/// exports the shared `anj_watch_*` ABI: inotify on Linux
/// (native/posix/watch_inotify.inc), one FSEvents stream on macOS
/// (native/posix/watch_fsevents.inc, spec #31 M2), both delivering the same
/// compact records with inotify mask bits. A watcher isolate blocks in the
/// native wait and posts event batches; this object lives on the sync
/// worker isolate, maps watch descriptors to root-relative paths and keeps a
/// bounded, debounced queue of changed paths for the engine's candidate set.
/// Events are hints: every queued path is re-read with a stat (and hashed only
/// under the index rules), and anything lost leads to an audit.
class LocalWatcher implements ChangeWatcher {
  LocalWatcher._(
    this.native,
    this.handle,
    this.rootFd,
    this._rootVolume,
    this.rootPath,
    WatcherSettings settings,
    this._silentVolume,
  ) : quiet = settings.quiet,
      maxDelay = settings.maxDelay,
      queueBound = settings.queueBound,
      unwatchedInterval = settings.unwatchedInterval,
      fullAuditOnLimit = settings.fullAuditOnLimit {
    _mounts = _mountsBeneath();
  }

  final NativeRootFs native;
  @override
  final Pointer<Void> handle;
  final int rootFd;

  /// Stable volume key of the root (see `volume_key` in native/posix/rootfs.cc).
  final String _rootVolume;

  /// The root's absolute path, used only to notice mount-table changes
  /// beneath it (no file is opened through it).
  final String rootPath;

  /// Filesystems whose changes need not pass through this kernel (network
  /// and FUSE): no notification for another client's change is promised, so
  /// such a root uses the per-pass stat scan and such a subtree is audited
  /// periodically.
  static const silentFsMagic = {
    0x6969, // NFS
    0x517B, // SMB
    0xFF534D42, // CIFS
    0xFE534D42, // SMB2
    0x65735546, // FUSE
    0x00C36400, // Ceph
    0x01021997, // 9P
    0x5346414F, // AFS
    0x6B414653, // kAFS
    0x73757245, // Coda
    0x01161970, // GFS2
    0x7461636F, // OCFS2
  };

  /// Quiet period per path and the longest a changed path may wait.
  Duration quiet;
  Duration maxDelay;

  /// Bound on queued paths; reaching it collapses the queue to one subtree
  /// audit marker (the common ancestor) instead of dropping anything.
  int queueBound;

  /// Subtrees that cannot be watched are audited at this interval.
  Duration unwatchedInterval;

  /// See [WatcherSettings.fullAuditOnLimit].
  final bool fullAuditOnLimit;
  final Set<String> _limitAudited = {};

  @override
  WatcherSettings get settings => WatcherSettings(
    quiet: quiet,
    maxDelay: maxDelay,
    queueBound: queueBound,
    unwatchedInterval: unwatchedInterval,
    fullAuditOnLimit: fullAuditOnLimit,
  );

  final Stopwatch _clock = Stopwatch()..start();

  /// Monotonic microseconds (test seam).
  int Function()? debugNow;
  int _now() => debugNow?.call() ?? _clock.elapsedMicroseconds;

  final Map<int, String> _wdPath = {};
  final SplayTreeMap<String, int> _pathWd = SplayTreeMap();
  final Set<int> _removing = {};
  final Set<int> _selfDeleted = {};
  final Map<String, _Pending> _queue = {};

  /// Directories without a working watch: path -> next audit (monotonic us).
  final SplayTreeMap<String, int> _unwatched = SplayTreeMap();
  final Map<String, String> _unwatchedReason = {};
  final Map<String, bool> _silentVolumes = {};

  /// Whether a directory on another volume than the root's (volume key,
  /// root-relative path) is on a filesystem whose changes need not be
  /// reported; null uses [silentFsMagic] (Linux statfs magics).
  final bool Function(String volume, String path)? _silentVolume;

  /// Set by overflow, suspend or a root self event; cleared when the engine
  /// starts the full stat audit.
  @override
  bool fullAuditWanted = false;
  bool _closed = false;

  /// Set when the watcher isolate stopped unexpectedly: the engine falls back
  /// to the per-pass stat scan.
  @override
  String? failure;
  @override
  bool get active => !_closed && failure == null;
  bool get closed => _closed;

  /// Called on the worker isolate after events were queued (or on failure).
  @override
  void Function()? onChange;

  // Counters (tests and opt-in metrics).
  int events = 0;
  int overflows = 0;
  int suspends = 0;
  int collapses = 0;
  int exhausted = 0;
  int rootEvents = 0;
  int backlogOverflows = 0;
  int mountChanges = 0;

  ReceivePort? _port;
  ReceivePort? _exitPort;
  ReceivePort? _errorPort;

  /// Mount-table source (test seam).
  static String mountInfoPath = '/proc/self/mountinfo';
  Set<String> _mounts = const {};

  /// Opens the inotify instance and starts the watcher isolate. Returns null
  /// when inotify is unavailable (the caller keeps the per-pass stat scan).
  ///
  /// The isolate sends at most [inFlight] unprocessed batches; while the
  /// worker is behind it coalesces events by (directory, name), and beyond
  /// [backlogBound] distinct names it drops them for one audit marker.
  ///
  /// The platform may hold events back for at most the quiet period (the
  /// FSEvents latency; inotify holds none), so with the queue's own quiet
  /// period and maximum delay a change reaches a pass within quiet plus the
  /// maximum delay. [silentVolume] says whether a directory on another
  /// volume than the root's goes unreported (default: [silentFsMagic]).
  static Future<LocalWatcher?> start(
    NativeRootFs native,
    int rootFd,
    String rootPath, {
    WatcherSettings settings = const WatcherSettings(),
    Duration waitTimeout = const Duration(seconds: 30),
    int inFlight = 4,
    int backlogBound = 20000,
    bool Function(String volume, String path)? silentVolume,
  }) async {
    final handle = native.watchOpen();
    if (handle == nullptr) return null;
    native.watchLatency(
      handle,
      min(settings.quiet.inMicroseconds, settings.maxDelay.inMicroseconds),
    );
    final watcher = LocalWatcher._(
      native,
      handle,
      rootFd,
      native.identity(rootFd).split(':').first,
      rootPath,
      settings,
      silentVolume,
    );
    final port = ReceivePort();
    final exit = ReceivePort();
    final errors = ReceivePort();
    watcher
      .._port = port
      .._exitPort = exit
      .._errorPort = errors;
    port.listen(watcher._receive);
    errors.listen((error) => watcher._died('Folder watching failed: $error'));
    exit.listen((_) => watcher._died('Folder watching stopped.'));
    try {
      await Isolate.spawn(
        _watchMain,
        [
          port.sendPort,
          native.libraryPath,
          handle.address,
          native.lib
              .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
                'anj_watch_release',
              )
              .address,
          waitTimeout.inMilliseconds,
          inFlight,
          backlogBound,
        ],
        debugName: 'anj-local-watch',
        onError: errors.sendPort,
        onExit: exit.sendPort,
      );
    } catch (_) {
      port.close();
      exit.close();
      errors.close();
      native.watchRelease(handle);
      native.watchRelease(handle);
      return null;
    }
    return watcher;
  }

  /// Stops the watcher isolate (it releases its reference on exit).
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    native.watchStop(handle);
    native.watchRelease(handle);
    _port?.close();
    _exitPort?.close();
    _errorPort?.close();
  }

  /// The watcher isolate ended without [close]: nobody reads inotify now.
  void _died(String reason) {
    if (_closed || failure != null) return;
    failure = reason;
    onChange?.call();
  }

  void _receive(dynamic message) {
    if (_closed) return;
    if (message is Map) {
      _died('Folder watching stopped (errno ${message['error']}).');
      return;
    }
    handleRecords(message as List);
    native.watchAck(handle);
    onChange?.call();
  }

  /// The root's canonical path, as the mount table spells it: the configured
  /// path may pass through a symlink (for example /home -> /var/home).
  String _canonicalRoot() {
    try {
      return Link('/proc/self/fd/$rootFd').targetSync();
    } on FileSystemException {
      try {
        return Directory(rootPath).resolveSymbolicLinksSync();
      } on FileSystemException {
        return rootPath;
      }
    }
  }

  /// Mount points beneath the root, from the mount table.
  Set<String> _mountsBeneath() {
    try {
      final result = <String>{};
      final root = _canonicalRoot();
      final prefix = root.endsWith('/') ? root : '$root/';
      for (final line in File(mountInfoPath).readAsLinesSync()) {
        final fields = line.split(' ');
        if (fields.length < 5) continue;
        // Octal escapes (\040 for space, etc.) as in proc_pid_mountinfo(5).
        final point = fields[4].replaceAllMapped(
          RegExp(r'\\([0-7]{3})'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
        );
        if (point == root) result.add('');
        if (point.startsWith(prefix)) {
          result.add(point.substring(prefix.length));
        }
      }
      return result;
    } on Object {
      return const {};
    }
  }

  /// The mount table changed: audit the subtrees whose mounts came or went.
  void _mountsChanged() {
    final now = _mountsBeneath();
    final changed = {...now.difference(_mounts), ..._mounts.difference(now)};
    _mounts = now;
    if (changed.isEmpty) return;
    mountChanges++;
    for (final path in changed) {
      if (path.isEmpty) {
        rootEvents++;
        fullAuditWanted = true;
      } else {
        enqueue(path, subtree: true);
      }
    }
  }

  /// Applies one batch of `[wd, mask, cookie, name, ...]` records.
  void handleRecords(List records) {
    final moves = <int, String>{};
    for (var i = 0; i + 3 < records.length; i += 4) {
      events++;
      final wd = records[i] as int;
      final mask = records[i + 1] as int;
      final cookie = records[i + 2] as int;
      final name = records[i + 3] as String;
      if (wd == _suspendRecord) {
        suspends++;
        fullAuditWanted = true;
        continue;
      }
      if (wd == _backlogRecord) {
        backlogOverflows++;
        fullAuditWanted = true;
        continue;
      }
      if (wd == _mountRecord) {
        _mountsChanged();
        continue;
      }
      if (mask & inQueueOverflow != 0) {
        overflows++;
        fullAuditWanted = true;
        continue;
      }
      final directory = _wdPath[wd];
      if (directory == null) continue;
      if (mask & _inIgnored != 0) {
        _wdPath.remove(wd);
        if (_pathWd[directory] == wd) _pathWd.remove(directory);
        final expected = _removing.remove(wd) | _selfDeleted.remove(wd);
        if (!expected) _lost(directory);
        continue;
      }
      if (mask & _inUnmount != 0) {
        _lost(directory);
        continue;
      }
      if (name.isEmpty) {
        if (mask & (_inDeleteSelf | _inMoveSelf) != 0) {
          if (mask & _inDeleteSelf != 0) _selfDeleted.add(wd);
          if (directory.isEmpty) {
            rootEvents++;
            fullAuditWanted = true;
          } else {
            enqueue(directory, subtree: true);
          }
        } else if (directory.isNotEmpty) {
          enqueue(directory);
        } else if (mask & _inCreate != 0 && mask & _inIsDir != 0) {
          // A subtree record for the root itself (the Windows translation of
          // a name it cannot re-read, at the top): a stat audit of the root,
          // which reads only files whose stamp changed. inotify never sends it.
          enqueue('', subtree: true);
        }
        continue;
      }
      final path = directory.isEmpty ? name : '$directory/$name';
      final isDirectory = mask & _inIsDir != 0;
      if (isDirectory && mask & _inMovedFrom != 0) moves[cookie] = path;
      if (isDirectory && mask & _inMovedTo != 0) {
        final from = moves.remove(cookie);
        if (from != null) _remap(from, path);
      }
      if (isDirectory &&
          mask & (_inCreate | _inMovedTo | _inMovedFrom | _inDelete) != 0) {
        // A new, replaced or removed tree: everything beneath is a candidate.
        enqueue(path, subtree: true);
      } else if (mask &
              (_inCreate |
                  _inCloseWrite |
                  _inModify |
                  _inAttrib |
                  _inMovedFrom |
                  _inMovedTo |
                  _inDelete) !=
          0) {
        enqueue(path);
      }
    }
  }

  /// An unexpectedly removed watch: audit what it covered.
  void _lost(String directory) {
    if (directory.isEmpty) {
      rootEvents++;
      fullAuditWanted = true;
    } else {
      enqueue(directory, subtree: true);
    }
  }

  /// A paired directory rename: watches move with their inodes.
  void _remap(String from, String to) {
    for (final old in keysUnder(_pathWd, from)) {
      final wd = _pathWd.remove(old)!;
      final moved = '$to${old.substring(from.length)}';
      _pathWd[moved] = wd;
      _wdPath[wd] = moved;
    }
  }

  /// Queues [path] (idempotent). A [subtree] entry stands for everything
  /// beneath it and absorbs later events there.
  void enqueue(String path, {bool subtree = false}) {
    if (fullAuditWanted) return;
    final t = _now();
    for (var a = path; ; a = _parentOf(a)) {
      final pending = _queue[a];
      if (pending != null && (pending.subtree || a == path)) {
        pending.last = t;
        if (a == path && subtree) pending.subtree = true;
        return;
      }
      if (a.isEmpty) break;
    }
    if (_queue.length >= queueBound) {
      _collapse(path, subtree, t);
      return;
    }
    _queue[path] = _Pending(t, t, subtree);
  }

  void _collapse(String path, bool subtree, int t) {
    collapses++;
    List<String> parts(String key, bool whole) {
      final directory = whole ? key : _parentOf(key);
      return directory.isEmpty ? const [] : directory.split('/');
    }

    var common = parts(path, subtree);
    var first = t;
    for (final entry in _queue.entries) {
      first = min(first, entry.value.first);
      final other = parts(entry.key, entry.value.subtree);
      var n = 0;
      while (n < common.length && n < other.length && common[n] == other[n]) {
        n++;
      }
      common = common.sublist(0, n);
    }
    _queue.clear();
    if (common.isEmpty) {
      fullAuditWanted = true;
    } else {
      _queue[common.join('/')] = _Pending(first, t, true);
    }
  }

  bool _ready(_Pending p, int t) =>
      t - p.last >= quiet.inMicroseconds ||
      t - p.first >= maxDelay.inMicroseconds;

  /// Removes and returns everything due now. A wanted full audit is reported
  /// without clearing it (see [beginFullAudit]).
  @override
  WatchWork take() {
    if (fullAuditWanted) return const WatchWork(full: true);
    final t = _now();
    final paths = <String>{};
    final subtrees = <String>{};
    _queue.removeWhere((path, pending) {
      if (!_ready(pending, t)) return false;
      (pending.subtree ? subtrees : paths).add(path);
      return true;
    });
    for (final entry in _unwatched.entries) {
      if (entry.value <= t) subtrees.add(entry.key);
    }
    for (final path in subtrees) {
      if (_unwatched.containsKey(path)) {
        _unwatched[path] = t + unwatchedInterval.inMicroseconds;
      }
    }
    return WatchWork(paths: paths, subtrees: subtrees);
  }

  /// Puts back work whose scan failed (it is retried after a quiet period).
  @override
  void requeue(WatchWork work) {
    if (work.full) {
      fullAuditWanted = true;
      return;
    }
    for (final path in work.paths) {
      enqueue(path);
    }
    for (final path in work.subtrees) {
      enqueue(path, subtree: true);
    }
  }

  /// The full audit is starting: everything queued so far is covered by it.
  @override
  void beginFullAudit() {
    fullAuditWanted = false;
    _queue.clear();
  }

  /// Time until the next queued path matures or an unwatched subtree is due.
  @override
  Duration? nextDeadline() {
    if (fullAuditWanted) return Duration.zero;
    final t = _now();
    int? best;
    for (final p in _queue.values) {
      final due = min(
        p.last + quiet.inMicroseconds,
        p.first + maxDelay.inMicroseconds,
      );
      if (best == null || due < best) best = due;
    }
    for (final due in _unwatched.values) {
      if (best == null || due < best) best = due;
    }
    return best == null ? null : Duration(microseconds: max(0, best - t));
  }

  int get queued => _queue.length;

  @override
  Iterable<String> get pending => _queue.keys;

  /// Whether [path] is a directory with a working watch.
  @override
  bool watching(String path) =>
      _pathWd.containsKey(path) && !_unwatched.containsKey(path);

  /// Records the watches a scan added (see `RootTree.scanTree`).
  @override
  void applyWatches(List<Map<String, dynamic>> watches) {
    final t = _now();
    for (final watch in watches) {
      final path = watch['path'] as String;
      final wd = watch['wd'] as int;
      if (wd < 0) {
        final error = watch['error'] as int;
        if (_vanished.contains(native.errorName(error))) continue;
        // ENOSPC (watch limit), ENOMEM, EACCES: audited on a timer.
        exhausted++;
        _unwatched.putIfAbsent(
          path,
          () => t + unwatchedInterval.inMicroseconds,
        );
        _unwatchedReason[path] = 'limit';
        // Once per directory, so the audit's own failed adds do not repeat it.
        if (fullAuditOnLimit && _limitAudited.add(path)) {
          fullAuditWanted = true;
        }
        continue;
      }
      final old = _wdPath[wd];
      if (old != null && old != path && _pathWd[old] == wd) {
        _pathWd.remove(old);
      }
      final previous = _pathWd[path];
      if (previous != null && previous != wd && _wdPath[previous] == path) {
        // Another directory used to be here; its watch no longer applies.
        _forgetWd(previous);
      }
      _wdPath[wd] = path;
      _pathWd[path] = wd;
      final volume = watch['volume'] as String;
      if (volume != _rootVolume && _silent(volume, path)) {
        _unwatched.putIfAbsent(
          path,
          () => t + unwatchedInterval.inMicroseconds,
        );
        _unwatchedReason[path] = 'filesystem';
      } else if (_unwatched.remove(path) != null) {
        _unwatchedReason.remove(path);
      }
    }
  }

  bool _silent(String volume, String path) =>
      _silentVolumes.putIfAbsent(volume, () {
        try {
          return _silentVolume?.call(volume, path) ??
              silentFsMagic.contains(native.fsMagic(rootFd, path));
        } on Object {
          return true;
        }
      });

  /// Watches one directory now (after this client created it).
  @override
  void add(String path) {
    try {
      final added = native.watchAdd(handle, rootFd, path);
      applyWatches([
        {
          'path': path,
          'wd': added.wd,
          'error': 0,
          'volume': added.identity.split(':').first,
        },
      ]);
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode ?? -1;
      applyWatches([
        {'path': path, 'wd': -1, 'error': code, 'volume': _rootVolume},
      ]);
    }
  }

  void _forgetWd(int wd) {
    final path = _wdPath.remove(wd);
    if (path != null && _pathWd[path] == wd) _pathWd.remove(path);
    // Its IN_IGNORED is then expected; a watch already gone sends none.
    if (!_removing.contains(wd) && native.watchRemove(handle, wd) == 0) {
      _removing.add(wd);
    }
  }

  /// After a rescan of [path]: drops watches at or beneath it whose
  /// directory is not among [directories] (removed or moved away).
  @override
  void retainUnder(String path, Set<String> directories) {
    for (final key in keysUnder(_pathWd, path)) {
      if (key.isEmpty || directories.contains(key)) continue;
      _forgetWd(_pathWd[key]!);
    }
    for (final key in keysUnder(_unwatched, path)) {
      if (!directories.contains(key)) {
        _unwatched.remove(key);
        _unwatchedReason.remove(key);
      }
    }
  }

  /// A status note when part of the tree is not watched.
  @override
  String? get note {
    if (_unwatched.isEmpty) return null;
    return _unwatchedReason.values.contains('limit')
        ? 'Some folders are checked periodically: the system limit on watched folders was reached.'
        : 'Some folders are checked periodically: their filesystem does not report changes.';
  }

  int get unwatched => _unwatched.length;
  int get watches => _pathWd.length;

  /// Test seams.
  void debugOverflow() => native.watchDebugInject(handle, -1, inQueueOverflow);
  void debugKill() => native.watchDebugInject(handle, _killRecord, 0);
  void debugMountsChanged() => native.watchDebugInject(handle, _mountRecord, 0);
  void debugClockJump(Duration by) =>
      native.watchDebugClock(handle, by.inMicroseconds * 1000);
  void debugFailAdds(String? prefix) =>
      native.watchDebugFailAdds(handle, prefix);

  /// macOS only: an FSEvents event with [flags] (FSEventStreamEventFlags) at
  /// the watched directory [path], translated as a real one is.
  void debugFsEvent(String path, int flags) =>
      native.watchDebugInject(handle, debugWatchDescriptor(path)!, flags);

  /// The watch descriptor of the watched directory [path], if any.
  int? debugWatchDescriptor(String path) => _pathWd[path];
}

/// Watcher isolate: blocks in the native poll and posts compact batches.
/// At most `inFlight` batches the worker has not processed are outstanding;
/// beyond that, events are coalesced by (watch, name) with their masks
/// merged, and past `backlogBound` names they are replaced by one backlog
/// record (the worker then audits the whole root).
@pragma('vm:entry-point')
void _watchMain(List<Object?> args) {
  final port = args[0] as SendPort;
  final handle = Pointer<Void>.fromAddress(args[2] as int);
  // The release is resolved by the worker, so the isolate's reference is
  // dropped even when opening the library or a lookup below fails.
  final release =
      Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
        args[3] as int,
      ).asFunction<void Function(Pointer<Void>)>();
  final timeout = args[4] as int;
  final inFlight = args[5] as int;
  final backlogBound = args[6] as int;
  Pointer<Uint8> buffer = nullptr;
  try {
    _watchLoop(
      port,
      DynamicLibrary.open(args[1] as String),
      handle,
      timeout,
      inFlight,
      backlogBound,
      buffer = malloc<Uint8>(_watchCapacity),
    );
  } finally {
    if (buffer != nullptr) malloc.free(buffer);
    release(handle);
  }
}

const _watchCapacity = 80 * 1024;

void _watchLoop(
  SendPort port,
  DynamicLibrary lib,
  Pointer<Void> handle,
  int timeout,
  int inFlight,
  int backlogBound,
  Pointer<Uint8> buffer,
) {
  final wait = lib
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Int32),
        int Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('anj_watch_wait');
  final acked = lib
      .lookupFunction<
        Int64 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('anj_watch_acked');
  final error = lib.lookupFunction<Int32 Function(), int Function()>(
    'anj_error',
  );
  const capacity = _watchCapacity;
  var sent = 0;
  // Coalesced backlog: key -> [wd, mask, cookie, name].
  final backlog = <String, List<Object>>{};
  var overflowed = false;
  while (true) {
    final behind = backlog.isNotEmpty || overflowed;
    // While holding a backlog, wake often enough to hand it over.
    final n = wait(handle, buffer, capacity, behind ? 50 : timeout);
    if (n == -2) break;
    if (n < 0) {
      port.send({'error': error()});
      break;
    }
    final records = <Object>[];
    if (n > 0) {
      final bytes = Uint8List.fromList(buffer.asTypedList(n));
      final data = ByteData.sublistView(bytes);
      for (var at = 0; at + 16 <= n;) {
        final wd = data.getInt32(at, Endian.host);
        final length = data.getUint32(at + 12, Endian.host);
        if (wd == _killRecord) throw StateError('watcher failure (test)');
        records
          ..add(wd)
          ..add(data.getUint32(at + 4, Endian.host))
          ..add(data.getUint32(at + 8, Endian.host))
          ..add(
            utf8.decode(
              bytes.sublist(at + 16, at + 16 + length),
              allowMalformed: true,
            ),
          );
        at += 16 + length;
      }
    }
    final room = sent - acked(handle) < inFlight;
    if (room && !behind) {
      if (records.isNotEmpty) {
        port.send(records);
        sent++;
      }
      continue;
    }
    for (var i = 0; i + 3 < records.length && !overflowed; i += 4) {
      final key = '${records[i]}\u0000${records[i + 3]}';
      final held = backlog[key];
      if (held == null) {
        backlog[key] = records.sublist(i, i + 4);
      } else {
        held[1] = (held[1] as int) | (records[i + 1] as int);
        held[2] = records[i + 2];
      }
      if (backlog.length > backlogBound) {
        backlog.clear();
        overflowed = true;
      }
    }
    if (room) {
      port.send(
        overflowed
            ? <Object>[_backlogRecord, 0, 0, '']
            : [for (final record in backlog.values) ...record],
      );
      sent++;
      backlog.clear();
      overflowed = false;
    }
  }
}
