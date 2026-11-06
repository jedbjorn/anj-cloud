/// Port: the local change watcher (decision #74).
///
/// A watcher turns platform change notifications for the root into a
/// bounded, debounced queue of root-relative paths the engine re-stats;
/// events are hints, and anything lost asks for a full stat audit. Linux and
/// macOS: `LocalWatcher` (lib/platform/native/local_watcher.dart) over
/// inotify in native/posix/watch_inotify.inc, or one FSEvents stream in
/// native/posix/watch_fsevents.inc.
///
/// The engine holds a [ChangeWatcher] and starts one only through a
/// [ChangeWatcherFactory] (part of `PlatformAdapters`), never through a
/// platform class.
library;

import 'dart:ffi';

import 'root_filesystem.dart';

/// The watcher's tuning, passed in when it starts and carried across a
/// restart (a replacement watcher keeps the values the failed one had).
class WatcherSettings {
  const WatcherSettings({
    this.quiet = const Duration(milliseconds: 1500),
    this.maxDelay = const Duration(seconds: 10),
    this.queueBound = 20000,
    this.unwatchedInterval = const Duration(seconds: 60),
    this.fullAuditOnLimit = false,
  });

  /// Quiet period per path, and the longest a changed path may wait.
  final Duration quiet;
  final Duration maxDelay;

  /// Bound on queued paths; reaching it collapses the queue to one subtree
  /// audit marker (the common ancestor) instead of dropping anything.
  final int queueBound;

  /// Subtrees that cannot be watched are audited at this interval.
  final Duration unwatchedInterval;

  /// A directory that newly cannot be watched (watch limit) also asks for
  /// one full audit. Off on Linux; on Android, where ordinary passes hash
  /// only reported paths, the full pass is the verification (#130 (3)).
  final bool fullAuditOnLimit;

  WatcherSettings withFullAuditOnLimit() => WatcherSettings(
    quiet: quiet,
    maxDelay: maxDelay,
    queueBound: queueBound,
    unwatchedInterval: unwatchedInterval,
    fullAuditOnLimit: true,
  );
}

/// Starts the platform's watcher for a root.
abstract interface class ChangeWatcherFactory {
  /// Whether a watch on the filesystem holding [path] beneath [fd] ('' is
  /// the root itself) reports changes made through any client. False for
  /// filesystems whose changes need not pass through this machine (network
  /// and FUSE on Linux): such a root keeps the per-pass stat scan. Throws a
  /// `FileSystemException` when the filesystem cannot be queried.
  bool watchReportsChanges(RootFilesystem fs, int fd, String path);

  /// Starts watching the root open as [rootFd] at [rootPath] through [fs].
  /// Returns null when the platform, or [fs], has no usable watcher: the
  /// engine then keeps the per-pass stat scan.
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  });
}

/// Work the engine takes from the queue at a pass: a full stat audit, or the
/// paths (stat each) and subtrees (stat everything beneath) whose quiet period
/// ended.
class WatchWork {
  const WatchWork({
    this.full = false,
    this.paths = const {},
    this.subtrees = const {},
  });
  final bool full;
  final Set<String> paths;
  final Set<String> subtrees;
  bool get isEmpty => !full && paths.isEmpty && subtrees.isEmpty;
}

abstract interface class ChangeWatcher {
  /// The tuning in effect now (a restart passes it to the replacement).
  WatcherSettings get settings;

  /// Opaque native handle passed to `RootFilesystem.watchScan`, which adds
  /// watches while it lists directories.
  Pointer<Void> get handle;

  bool get active;

  /// Set when watching stopped unexpectedly: the engine falls back to the
  /// per-pass stat scan.
  String? get failure;

  /// Set by overflow, suspend or a root self event; cleared when the engine
  /// starts the full stat audit.
  bool get fullAuditWanted;
  set fullAuditWanted(bool value);

  /// Called on the worker isolate after events were queued (or on failure).
  void Function()? get onChange;
  set onChange(void Function()? value);

  /// Removes and returns everything due now.
  WatchWork take();

  /// Puts back work whose scan failed.
  void requeue(WatchWork work);

  /// The full audit is starting: everything queued so far is covered by it.
  void beginFullAudit();

  /// Time until the next queued path matures or an unwatched subtree is due.
  Duration? nextDeadline();

  /// Whether [path] is a directory with a working watch.
  bool watching(String path);

  /// Paths (and subtree markers) queued but not yet handed out. A partial
  /// pass may see one side of a rename before the other has matured here;
  /// the engine then defers inferring that removal (SC-054 pairing).
  Iterable<String> get pending;

  /// Records the watches a scan added.
  void applyWatches(List<Map<String, dynamic>> watches);

  /// After a rescan of [path]: drops watches at or beneath it whose
  /// directory is not among [directories].
  void retainUnder(String path, Set<String> directories);

  /// Watches one directory now (after this client created it).
  void add(String path);

  /// A status note when part of the tree is not watched.
  String? get note;

  void close();
}
