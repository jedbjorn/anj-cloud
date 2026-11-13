import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../gateway/cloud_api.dart';
import 'bulk_targets.dart';
import 'case_moves.dart';
import 'artifacts.dart';
import 'evictions.dart';
import 'open_documents.dart';
import 'edit_completion.dart';
import 'excluded_tracking.dart';
import 'file_adder.dart';
import 'folder_creation.dart';
import 'name_policy.dart';
import 'cloud_names.dart';
import 'name_rule.dart';
import '../../platform/watchers.dart';
import '../ports/change_watcher.dart';
import '../ports/root_filesystem.dart';
import 'pass_metrics.dart';
import 'recovery_copies.dart';
import 'device_trash.dart';
import '../gateway/trash_api.dart';
import 'sync_path_policy.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/path_keys.dart';
import '../local/root_tree.dart';
import '../gateway/sharing.dart';
import 'staging_release.dart';
import 'sync_activity.dart';
import 'top_folders.dart';
import 'upload_backoff.dart';

/// Whether a pass may list and change the cloud: always, only when local
/// work is waiting, or never (offline backoff).
enum RemotePolicy { always, ifLocalWork, never }

class SyncEngine {
  SyncEngine(
    this.manifest,
    this.tree,
    this.cloud, {
    SyncActivity? activity,
    CloudNames? names,
    this._watchers,
  }) : activity = activity ?? SyncActivity(),
       names = names ?? CloudNames() {
    // A name recorded with its row answers before the first listing.
    this.names.recorded = (path) => manifest.entries[path]?.cloudName;
    final root = tree.root.resolveSymbolicLinksSync();
    final profile = manifest.profile.resolveSymbolicLinksSync();
    if (p.equals(root, profile) ||
        p.isWithin(root, profile) ||
        p.isWithin(profile, root)) {
      throw const FileSystemException(
        'The synchronized root must be separate from private profile state.',
      );
    }
    tree.index = (path) {
      final entry = manifest.entries[path];
      final stamp = entry?.localStamp;
      final hash = entry?.stampHash;
      final at = entry?.stampedAt;
      return stamp == null || hash == null || at == null
          ? null
          : (stamp: stamp, hash: hash, at: at, confirmed: entry!.stampFinal);
    };
    // The first save compares every row once, repairing any drift.
    manifest.markAllRows();
    // Decision #137 (1): every destructive root change waits for a durable
    // record of it (a commit point), never only an ordered one.
    tree.native.beforeDestructiveChange = manifest.commitPoint;
    interruptedInstalls = artifacts.removeInterruptedInstalls();
    artifacts.finishInterruptedMoves();
    // An add copy the process did not finish (spec #43 Interruption).
    FileAdder.sweep(this);
  }

  /// Leftovers of interrupted installs removed at start (test seam).
  late final List<String> interruptedInstalls;
  final Manifest manifest;
  final RootTree tree;
  final CloudApi cloud;

  /// Cloud path <-> local path (spec #49, decision #199). The worker's
  /// [NamedCloud], inside [cloud], maps every request through the same one.
  final CloudNames names;

  /// Files shown as syncing. The pass plans its transfer queue here; an
  /// [ActivityCloud] wrapping [cloud] records transfers in flight.
  final SyncActivity activity;
  late final FolderCreation folders = FolderCreation(manifest, tree);
  final Set<String> localDirectories = {};
  final Map<String, String?> localIdentities = {};
  late final Artifacts artifacts = Artifacts(manifest, tree);
  late final Evictions evictions = Evictions(manifest, tree, cloud, artifacts);
  late final EditCompletion editing = EditCompletion(
    manifest,
    tree,
    cloud,
    artifacts,
  );
  late final StagingRelease releases = StagingRelease(
    manifest,
    tree,
    artifacts,
  );

  /// Recover and Dismiss of retained recovery copies (spec #25).
  late final RecoveryCopies recovery = RecoveryCopies(
    manifest,
    tree,
    artifacts,
    recordsFor: _artifactsFor,
    restored: markDirty,
    localIdentities: localIdentities,
  );

  /// The device trash (spec #44): deletion-produced copies, purged after
  /// the server's `trash_days`.
  late final DeviceTrash deviceTrash = DeviceTrash(
    manifest,
    tree,
    recovery,
    clock: () => wallClock(),
    restored: markDirty,
  );
  late final ExcludedTracking exclusions = ExcludedTracking(
    manifest,
    tree,
    cloud,
    artifacts,
  );
  String message = 'Ready';
  int passes = 0;

  /// Per-file upload backoff and size refusals (SC-028). Replaceable so
  /// tests can supply a clock and jitter source.
  UploadBackoff uploads = UploadBackoff();

  /// Paths to reconcile on the next pass (local or remote change, failure,
  /// unsettled result, blocked by an ancestor, or touched by a command).
  final Set<String> _dirty = {};

  /// Paths touched by a command during the running pass; reconciled next pass
  /// against fresh scans, exactly as if the command had arrived between passes.
  final Set<String> _deferred = {};
  final Map<String, String> _seenLocal = {};
  final Map<String, String> _seenRemote = {};
  bool _fullPending = true;
  bool _rowsAudited = false;

  /// Whole-manifest row comparisons started by audits (test seam).
  int rowAudits = 0;
  bool _inPass = false;
  final Stopwatch _clock = Stopwatch()..start();

  /// The engine clock now, and when the cloud was last listed (null before
  /// the first listing). Background runs judge a listing's age by them.
  Duration get clockNow => _clock.elapsed;
  Duration? lastListedAt;
  Duration? _lastAudit;

  /// Every path is reconciled at startup and after this interval.
  Duration auditInterval = const Duration(minutes: 5);

  /// Rows that only record the cloud share one commit, at most this many
  /// (flag SC-057); any other row's commit, and the pass end, takes them too.
  static const listingOnlyCommit = 256;

  /// A row that only records the cloud: nothing on disk ([here] is null and
  /// nothing is expected there), nothing in flight (no operation), no
  /// conflict, and its visit did not fail. A crash that loses it loses
  /// nothing the next listing does not record again, so it may share a
  /// commit (flag SC-057). Any other row is committed on its own.
  bool listingOnlyRow(
    Entry entry, {
    required LocalItem? here,
    required bool failed,
  }) =>
      !failed &&
      here == null &&
      !entry.expectedPresent &&
      entry.conflict == null &&
      manifest.operationsAt(entry.path).isEmpty;

  /// Set to end the running pass at the next path boundary.
  bool stopRequested = false;

  /// Local work (a changed path or a command) not yet covered by a cloud
  /// listing. Lets the worker list the cloud early when something changed.
  bool _localWork = true;
  bool get localWork => _localWork;

  /// Whether the last pass listed the cloud, and whether that listing failed.
  bool remoteListed = false;
  bool remoteFailed = false;

  /// Wi-Fi only on mobile data (Android, decision #108 Q4; spec #28 R3):
  /// file bytes wait, listings, deletions and folder creation do not. While
  /// set, no upload or download starts; each path that wanted one shows
  /// [waitingForWifiStatus] and is revisited when [releaseTransfers] runs.
  /// The cloud gate refuses byte transfers too ([PausableCloud.bytesHeld]),
  /// so a path not checked here still moves nothing.
  bool transfersHeld = false;

  /// Paths whose upload or download waits for Wi-Fi.
  final Set<String> waitingForNetwork = {};

  /// Wi-Fi returned or mobile data was allowed: every waiting path is
  /// reconciled again.
  void releaseTransfers() {
    transfersHeld = false;
    for (final path in waitingForNetwork) {
      if (manifest.entries.containsKey(path)) markDirty(path);
    }
    waitingForNetwork.clear();
  }

  void _waitForNetwork(Entry entry) {
    entry.status = waitingForWifiStatus;
    waitingForNetwork.add(entry.path);
  }

  /// Metrics of the most recent pass (test seam and opt-in output).
  PassMetrics? lastPass;
  int _visited = 0;

  /// Candidate paths reconciled so far in the running pass (test seam).
  int get visitedThisPass => _visited;

  /// Test seam: called at durable-intent/dispatch boundaries.
  void Function(String phase, Operation op)? barrier;

  /// Native change notifications (spec #15). Without them (null, or no
  /// longer [ChangeWatcher.active]) every pass stat-scans the whole root.
  ChangeWatcher? watcher;

  /// Where watchers come from: the running platform's factory unless the
  /// constructor was given another one.
  ChangeWatcherFactory get watchers => _watchers ??= platformWatchers();
  ChangeWatcherFactory? _watchers;

  /// Tuning for the watcher [startWatching] starts; a restart keeps the
  /// failed watcher's settings instead.
  WatcherSettings watcherSettings = const WatcherSettings();

  /// Notifications were wanted but are unavailable here (status note).
  bool watchUnavailable = false;

  /// With a watcher: the local view kept current by events, own-operation
  /// records and audits, instead of a per-pass full scan.
  SplayTreeMap<String, LocalItem>? _view;
  final Set<String> _unstamped = {};

  /// Paths reconciled with a change (or failure) or touched by a command
  /// since the last local scan.
  final Set<String> _touched = {};

  /// Monotonic due time -> paths whose confirmation hash is due then.
  final SplayTreeMap<int, Set<String>> _confirmations = SplayTreeMap();
  final Map<String, int> _dueOf = {};

  /// Schedules (or with null, cancels) [path]'s confirmation hash.
  void _schedule(String path, int? due) {
    // Exact: a deadline is never later than the rule requires.
    final at = due;
    final old = _dueOf[path];
    if (old == at) return;
    if (old != null) {
      final set = _confirmations[old];
      set?.remove(path);
      if (set != null && set.isEmpty) _confirmations.remove(old);
      _dueOf.remove(path);
    }
    if (at != null) {
      _confirmations.putIfAbsent(at, () => {}).add(path);
      _dueOf[path] = at;
    }
  }

  Duration? _lastStatAudit;

  /// With a watcher, the full stat-only audit (no hashing of unchanged
  /// stamps) runs at startup, after an overflow, suspend, root event or
  /// watcher failure, and at this interval (decision #51: 5 minutes, so a
  /// change inotify cannot report, such as a shared-mmap write to a
  /// confirmed file or a new mount beneath the root, is found within it).
  Duration statAuditInterval = const Duration(minutes: 5);

  /// Full stat scans of the root since start (test seam and metrics).
  int fullScans = 0;

  /// Event-driven hashing (decisions #135 macOS, #130 (3) Android): with a
  /// working watcher, no trusted stamps and a platform verification interval
  /// ([RootFilesystem.fullVerificationInterval]: 60 minutes on macOS), an
  /// ordinary pass hashes only the paths the watcher reported (and new
  /// entries beneath them). A full verification pass hashes every file at
  /// start, after lost events (a drop or MustScanSubDirs at the root,
  /// RootChanged, a suspend), when the watcher restarts after a failure, on
  /// [requestFullVerification] and at most every interval. While the watcher
  /// is dead every pass is full, as without it. Off on Linux (no interval).
  bool get eventDriven =>
      tree.native.fullVerificationInterval != null &&
      !tree.writebackEnabled &&
      (watcher?.active ?? false);

  /// Decision #146: whether the last pass's local scan read every file of
  /// the root because no stamp is trusted (#39) while no change watcher was
  /// reporting changes for the root (none, as watchReportsChanges was false,
  /// or the watcher has failed). The worker then caps the cadence of every
  /// scheduled pass (see WorkerLoop.wholeRootCap). Never set while a watcher
  /// is active, event-driven or not.
  bool lastPassReadWholeRoot = false;

  /// How long the last pass's local scan (stat and hashing) took.
  Duration lastLocalScan = Duration.zero;

  /// Test seam: maps the measured local-scan duration to the one recorded
  /// (a fake clock for the #146 cadence).
  Duration Function(Duration measured)? debugLocalScanDuration;

  /// Full verification passes since start (event-driven hashing only).
  int fullVerifications = 0;
  bool _verifyWanted = false;
  bool _eventDrivenPass = false;

  /// Asks for a full verification pass next (the app opened, a background
  /// run). Only event-driven hashing has one; elsewhere every pass already
  /// is.
  void requestFullVerification() => _verifyWanted = true;

  /// The last full verification (event-driven hashing only).
  Duration? _lastVerification;
  String _localScan = 'full';
  int _statted = 0;

  /// Starts native watching of the root; keeps the per-pass stat scan (with
  /// a status note) where the platform or the root filesystem cannot notify.
  Future<void> startWatching({
    Duration waitTimeout = const Duration(seconds: 30),
  }) async {
    final factory = watchers;
    bool reports;
    try {
      reports = factory.watchReportsChanges(tree.native, tree.fd, '');
    } on FileSystemException {
      watchUnavailable = true;
      return;
    }
    final started = !reports
        ? null
        : await factory.changeWatcher(
            tree.native,
            tree.fd,
            tree.root.path,
            watcherSettings,
            waitTimeout: waitTimeout,
          );
    _waitTimeout = waitTimeout;
    if (started == null) {
      watchUnavailable = true;
    } else {
      attachWatcher(started);
    }
  }

  Duration _waitTimeout = const Duration(seconds: 30);

  /// A watcher that died is replaced at most [watchRestartLimit] times, the
  /// first attempt [watchRestartDelay] after the failure was noticed. In
  /// between, every pass stat-scans the root (with the status note).
  int watchRestartLimit = 3;
  Duration watchRestartDelay = const Duration(seconds: 30);
  int watchRestarts = 0;
  Duration? _watchFailedAt;

  Future<void> _restartWatching() async {
    final failed = watcher;
    if (failed == null || failed.active || failed.failure == null) return;
    final now = _clock.elapsed;
    _watchFailedAt ??= now;
    if (watchRestarts >= watchRestartLimit) {
      // The budget is spent: release its kernel watches and descriptors now.
      // The closed watcher stays attached for the status note.
      failed.close();
      return;
    }
    if (now - _watchFailedAt! < watchRestartDelay) return;
    watchRestarts++;
    _watchFailedAt = now;
    failed.close();
    final next = await watchers.changeWatcher(
      tree.native,
      tree.fd,
      tree.root.path,
      failed.settings,
      waitTimeout: _waitTimeout,
    );
    if (next == null) return;
    _watchFailedAt = null;
    attachWatcher(next); // The next scan is a full audit with new watches.
  }

  /// Called when watched local work arrives (set by the worker loop).
  void Function()? onLocalChange;

  void attachWatcher(ChangeWatcher value) {
    watcher = value;
    value.onChange = () => onLocalChange?.call();
    watchUnavailable = false;
    _view = null;
    tree.onOwn = _recordOwn;
  }

  bool get _watching => watcher?.active ?? false;

  /// A status note about how local changes are found, if not all by events.
  String? get localNote {
    if (watchUnavailable || (watcher != null && !watcher!.active)) {
      return 'Folder watching is unavailable; the whole folder is checked on every pass.';
    }
    return watcher?.note;
  }

  /// True while the local folder could not be read (moved away, unmounted,
  /// replaced, or a scan error): set by a pass whose local scan failed and
  /// cleared by the next one that succeeds.
  bool localUnavailable = false;

  /// Time until local work is due (a queued change, a confirmation hash, an
  /// unwatched subtree or the audit), or null without a watcher. Null while
  /// [localUnavailable]: a failed scan never brings a pass forward, so the
  /// retry keeps the worker's base interval and the audit runs on the first
  /// pass after the folder returns.
  Duration? nextLocalDeadline() {
    final w = watcher;
    if (w == null || localUnavailable) return null;
    if (!w.active) {
      // A dead watcher: audit at once, then retry it when allowed.
      if (w.failure == null || _view != null) {
        return w.failure == null ? null : Duration.zero;
      }
      final failedAt = _watchFailedAt;
      if (watchRestarts >= watchRestartLimit || failedAt == null) return null;
      final left = failedAt + watchRestartDelay - _clock.elapsed;
      return left < Duration.zero ? Duration.zero : left;
    }
    if (_view == null) return Duration.zero;
    var best = w.nextDeadline();
    void consider(Duration value) {
      if (value < Duration.zero) value = Duration.zero;
      if (best == null || value < best!) best = value;
    }

    if (_confirmations.isNotEmpty) {
      consider(
        Duration(microseconds: _confirmations.firstKey()! - tree.monoMicros()),
      );
    }
    if (eventDriven && _verifyWanted) consider(Duration.zero);
    if (tree.busy.isNotEmpty) {
      // A busy file is read again without waiting for an event.
      final last = _busyRetriedAt;
      consider(
        last == null
            ? busyRetryInterval
            : last + busyRetryInterval - _clock.elapsed,
      );
    }
    final audit = _lastStatAudit;
    if (audit != null) consider(audit + statAuditInterval - _clock.elapsed);
    final held = _nextHeldRemoval(w);
    if (held != null) consider(held);
    if (_heldDeletionDue() case final due?) consider(due);
    final verified = _lastVerification;
    if (eventDriven && verified != null) {
      consider(
        verified + tree.native.fullVerificationInterval! - _clock.elapsed,
      );
    }
    return best;
  }

  /// How often a partial pass reads the busy files again
  /// ([RootTree.busy]). Test seam.
  Duration busyRetryInterval = const Duration(seconds: 10);

  /// When a partial pass last read the busy files again, or first found
  /// one waiting.
  Duration? _busyRetriedAt;

  bool _busyRetryDue(Duration elapsed) {
    final last = _busyRetriedAt;
    if (last == null) {
      // First seen waiting: the interval starts now.
      _busyRetriedAt = elapsed;
      return busyRetryInterval == Duration.zero;
    }
    if (elapsed - last < busyRetryInterval) return false;
    _busyRetriedAt = elapsed;
    return true;
  }

  /// The local view for this pass: the full scan without a watcher, else
  /// the kept view refreshed for queued, due and engine-touched paths.
  Future<Map<String, LocalItem>> _localSnapshot() async {
    await _restartWatching();
    final w = watcher;
    _statted = 0;
    lastPassReadWholeRoot = false;
    if (w == null || !w.active) {
      _view = null;
      _localScan = 'full';
      fullScans++;
      final items = await tree.snapshot(includeExcluded: true);
      lastPassReadWholeRoot = !tree.rootStampsTrusted;
      return items;
    }
    tree.refreshWriteback();
    final work = w.take();
    final elapsed = _clock.elapsed;
    if (tree.busy.isEmpty) _busyRetriedAt = null;
    final wasEventDriven = _eventDrivenPass;
    _eventDrivenPass = eventDriven;
    // Without periodic writeback no stamp is trusted: every pass reads every
    // file, as before (spec #13 rule 4, decision #39), unless the platform
    // verifies by events (decisions #135, #130 (3)).
    final verify =
        _eventDrivenPass &&
        (_view == null ||
            _eventDrivenPass != wasEventDriven ||
            _verifyWanted ||
            work.full ||
            _lastVerification == null ||
            elapsed - _lastVerification! >=
                tree.native.fullVerificationInterval!);
    if (verify ||
        _view == null ||
        (!tree.writebackEnabled && !_eventDrivenPass) ||
        _eventDrivenPass != wasEventDriven ||
        work.full ||
        _lastStatAudit == null ||
        elapsed - _lastStatAudit! >= statAuditInterval) {
      if (verify) {
        _verifyWanted = false;
        _lastVerification = elapsed;
        fullVerifications++;
      }
      // Everything queued so far is covered by the full scan. Between
      // verifications an event-driven stat audit (decision #137 (3), every
      // statAuditInterval) reads only files whose stat stamp changed.
      w.beginFullAudit();
      try {
        final scan = tree.scanTree(
          '',
          recursive: true,
          watch: w.handle,
          reuse: _eventDrivenPass && !verify ? _view : null,
        );
        _view = SplayTreeMap();
        _unstamped.clear();
        _confirmations.clear();
        _dueOf.clear();
        for (final item in scan.items.values) {
          _put(item);
        }
        w.applyWatches(scan.watches);
        w.retainUnder('', {
          for (final item in scan.items.values)
            if (item.kind == ItemKind.directory) item.path,
        });
        _statted = scan.items.length;
      } catch (_) {
        w.fullAuditWanted = true;
        rethrow;
      }
      _lastStatAudit = elapsed;
      _localScan = 'full';
      fullScans++;
      // A watcher is reporting changes for the root: no cap (decision #146),
      // whether or not this audit read every file.
      return _view!;
    }
    _localScan = 'partial';
    final due = _dueConfirmations();
    // A file left out because another program held it open: releasing it
    // need not raise an event, so it is read again here, at most once per
    // [busyRetryInterval] (a full scan tries every file anyway).
    final retry = tree.busy.isNotEmpty && _busyRetryDue(elapsed)
        ? tree.busy.toSet()
        : const <String>{};
    // Paths the engine or a command acted on since the last scan are
    // re-stat-ed too, so the view never lags its own changes.
    final paths = {...work.paths, ...due, ..._unstamped, ..._touched, ...retry};
    _touched.clear();
    try {
      _rescan(paths, work.subtrees);
    } catch (_) {
      w.requeue(
        WatchWork(paths: {...work.paths, ...due}, subtrees: work.subtrees),
      );
      rethrow;
    }
    return _view!;
  }

  Set<String> _dueConfirmations() {
    final now = tree.monoMicros();
    final due = <String>{};
    while (_confirmations.isNotEmpty && _confirmations.firstKey()! <= now) {
      final paths = _confirmations.remove(_confirmations.firstKey())!;
      due.addAll(paths);
      paths.forEach(_dueOf.remove);
    }
    due.removeWhere((path) {
      final item = _view![path];
      return item == null || item.stamp == null || item.stampFinal;
    });
    return due;
  }

  /// Keeps [item] in the view and its confirmation/untrusted bookkeeping.
  void _put(LocalItem item) {
    _view![item.path] = item;
    if (item.kind != ItemKind.file || isSyncExcluded(item.path)) {
      _unstamped.remove(item.path);
      _schedule(item.path, null);
      return;
    }
    if (item.stamp == null) {
      // Untrusted filesystem or unproven stamp: re-read every pass (#13),
      // or, with event-driven hashing, when an event or verification says.
      if (_eventDrivenPass) {
        _unstamped.remove(item.path);
        _schedule(item.path, null);
        return;
      }
      _unstamped.add(item.path);
      _schedule(item.path, null);
      return;
    }
    _unstamped.remove(item.path);
    // Time-driven, not event-driven: the confirmation hash is due M after
    // the ctime and M after first observation (decision #39).
    _schedule(
      item.path,
      item.stampFinal ? null : tree.confirmDueMono(item.path, item.scanStamp!),
    );
  }

  /// Removes [path] and everything beneath it from the view. Observation
  /// state (#39 first-seen times, own stamps) is forgotten only for paths
  /// not in [keep], so a rescan never restarts the confirmation clock.
  void _drop(String path, {Map<String, LocalItem> keep = const {}}) {
    final view = _view!;
    for (final key in keysUnder(view, path)) {
      view.remove(key);
      _unstamped.remove(key);
      _schedule(key, null);
      if (!keep.containsKey(key)) tree.forget(key);
    }
  }

  void _replace(
    String path,
    ({Map<String, LocalItem> items, List<Map<String, dynamic>> watches}) scan,
  ) {
    _drop(path, keep: scan.items);
    for (final item in scan.items.values) {
      _put(item);
    }
    watcher!.applyWatches(scan.watches);
    watcher!.retainUnder(path, {
      for (final item in scan.items.values)
        if (item.kind == ItemKind.directory) item.path,
    });
    _statted += max(1, scan.items.length);
  }

  /// Re-stats [paths] and everything beneath [subtrees] into the view.
  void _rescan(Set<String> paths, Set<String> subtrees) {
    final w = watcher!;
    final view = _view!;
    final roots = <String>{};
    bool covered(String path) {
      if (roots.contains('')) return true; // the root's own stat audit
      for (var a = path; ; a = p.posix.dirname(a)) {
        if (roots.contains(a)) return true;
        if (a == '.' || !a.contains('/')) break;
      }
      return false;
    }

    for (final subtree
        in subtrees.toList()..sort((a, b) => a.length.compareTo(b.length))) {
      if (covered(subtree)) continue;
      roots.add(subtree);
      // A subtree rescan (a moved-in folder, an unwatched-subtree audit)
      // reads only files whose stat changed when hashing is event-driven.
      _replace(
        subtree,
        tree.scanTree(
          subtree,
          recursive: true,
          watch: w.handle,
          reuse: _eventDrivenPass ? view : null,
        ),
      );
    }
    for (final path in paths) {
      if (covered(path)) continue;
      final cached = view[path];
      if (cached?.kind == ItemKind.directory && w.watching(path)) {
        // A watched directory reports its own entries; re-stat only itself.
        final item = tree.statItem(path);
        _statted++;
        if (item != null &&
            item.kind == ItemKind.directory &&
            item.identity == cached!.identity) {
          _put(item);
          continue;
        }
      }
      // A hinted file is read (event-driven hashing reads what the watcher
      // names). Beneath a hinted directory that is not watched itself (on
      // Windows only the root is: one recursive watch), files whose stat
      // stamp is unchanged keep their hash when hashing is event-driven, as
      // in a subtree rescan; each changed file reports its own event.
      _replace(
        path,
        tree.scanTree(
          path,
          recursive: true,
          watch: w.handle,
          reuse: _eventDrivenPass && cached?.kind != ItemKind.file
              ? view
              : null,
        ),
      );
    }
    // The new side of a case- or normalization-only rename, met as the
    // stored spelling of an old one: rescanned in this pass, so the pair is
    // planned now and never waits for the watcher (PR #68 review).
    for (var round = 0; tree.storedSpellings.isNotEmpty && round < 8; round++) {
      final stored = tree.storedSpellings.toList()
        ..sort((a, b) => a.length.compareTo(b.length));
      tree.storedSpellings.clear();
      for (final path in stored) {
        if (covered(path)) continue;
        roots.add(path);
        _replace(
          path,
          tree.scanTree(
            path,
            recursive: true,
            watch: w.handle,
            reuse: _eventDrivenPass ? view : null,
          ),
        );
      }
    }
    tree.storedSpellings.clear();
  }

  /// Records the result of this client's own change at [path] so the event
  /// it causes finds the same stamp and changes nothing (spec #15 rule 8).
  void _recordOwn(String path, {String? hash, String? stagedStamp}) {
    final w = watcher;
    if (w == null || !w.active || _view == null) return;
    final LocalItem? item;
    try {
      item = tree.statItem(path);
    } on FileSystemException {
      return; // The event (or the dirty-path rescan) settles it.
    }
    if (item == null) {
      _drop(path);
      w.retainUnder(path, const {});
      tree.ownStamps.remove(path);
      return;
    }
    final cached = _view![path];
    if (item.kind == ItemKind.directory) {
      if (cached?.kind != ItemKind.directory ||
          cached!.identity != item.identity) {
        _drop(path);
        w.add(path);
      }
      _put(item);
      return;
    }
    if (item.kind != ItemKind.file ||
        hash == null ||
        stagedStamp == null ||
        !_sameBytes(stagedStamp, item.scanStamp!) ||
        !tree.trustsStamps(item.identity!.split(':').first, path) ||
        // Racy-timestamp rule: with coarse ctimes a user write in the same
        // tick keeps this stamp, so the event's rescan must read the file.
        !tree.fineCtime) {
      _touched.add(path); // Unknown or racy content: the next pass reads it.
      return;
    }
    final at = tree.wallMicros();
    tree.ownStamps[path] = (stamp: item.scanStamp!, hash: hash, at: at);
    _put(
      LocalItem(
        path,
        ItemKind.file,
        hash: hash,
        size: item.size,
        identity: item.identity,
        links: item.links,
        scanStamp: item.scanStamp,
        stamp: item.scanStamp,
        stampedAt: at,
      ),
    );
  }

  /// Same inode, size and mtime as the staged stamp
  /// (`volume:ino:size:mtime_s:mtime_ns:ctime_s:ctime_ns`).
  static bool _sameBytes(String staged, String scan) {
    final a = staged.split(':');
    final b = scan.split(':');
    if (a.length < 5 || b.length < 4) return false;
    final mtime = int.parse(a[3]) * 1000000000 + int.parse(a[4]);
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && '$mtime' == b[3];
  }

  /// Remember paths changed by a command so a later pass reconciles them.
  void markDirty(String path, {bool descendants = false}) {
    final paths = <String>{path};
    if (descendants) {
      paths.addAll(
        manifest.entries.keys.where((v) => p.posix.isWithin(path, v)),
      );
    }
    _dirty.addAll(paths);
    _localWork = true;
    _touched.addAll(paths);
    if (_inPass) _deferred.addAll(paths);
  }

  Retention get defaultRetention => Retention.local;

  /// A file's own storage choice when it has one (spec #45 R1), otherwise
  /// its nearest folder's.
  Retention retention(String path) {
    if (path.isEmpty || path == '.') return defaultRetention;
    validateRelative(path);
    final entry = manifest.entries[path];
    if (entry?.kind == ItemKind.file && entry?.override != null) {
      return entry!.override!;
    }
    return folderRetention(path);
  }

  /// The choice the folders give [path]: its own when it is a folder, else
  /// its nearest folder's. A file's own choice is not consulted.
  Retention folderRetention(String path) {
    if (path.isEmpty || path == '.') return defaultRetention;
    validateRelative(path);
    var current = path;
    while (current != '.') {
      final entry = manifest.entries[current];
      final own = entry?.kind == ItemKind.directory ? entry?.override : null;
      // Documents, Music and Videos themselves are never Cloud-only (spec #34
      // P7), whatever a row still holds; what is inside follows their row
      // like any folder's (decision #163: the first-sync choice).
      if (own != null && !(isTopFolder(current) && current == path)) {
        return own;
      }
      current = p.posix.dirname(current);
    }
    return defaultRetention;
  }

  Operation? operation(String path, String kind) =>
      manifest.operationsAt(path).where((o) => o.kind == kind).firstOrNull;
  Map<String, String>? excludedRemoteVersions() {
    final value = manifest.setting('excludedRemoteVersionsV1');
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value) as Map;
      final result = decoded.cast<String, String>();
      if (result.entries.any((v) => !isSyncExcluded(v.key) || v.value == '*')) {
        return null;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Operation intent(
    String path,
    String kind, {
    String? etag,
    bool persist = true,
  }) {
    final existing = operation(path, kind);
    if (existing != null) return existing;
    final op = Operation(uniqueId(), kind, path, expectedEtag: etag);
    if (kind == 'delete' &&
        manifest.entries[path]?.kind == ItemKind.directory) {
      final known = excludedRemoteVersions();
      if (known != null) {
        op.data['excludedSubtreeVersions'] = Map<String, String>.fromEntries(
          known.entries.where((v) => p.posix.isWithin(path, v.key)),
        );
      }
    }
    if (kind == 'upload' || kind == 'delete') {
      op.data['dispatchState'] = 'not-started';
    }
    manifest.operations[op.id] = op;
    if (persist) manifest.save();
    return op;
  }

  void finish(Operation op) {
    manifest.operations.remove(op.id);
    manifest.save();
  }

  void conflict(Entry entry, String reason) {
    entry.conflict = reason;
    entry.status = 'conflict';
    manifest.save();
  }

  bool rootAvailable() {
    try {
      tree.native.checkRoot(tree.fd, tree.root.path);
      return true;
    } on FileSystemException {
      message =
          'Paused: root moved, replaced or unavailable. No deletions inferred.';
      return false;
    }
  }

  Future<String> fileHash(File file, [String purpose = 'content']) =>
      tree.native.meter.hashFile(file, purpose);
  Future<File> remoteCopy(RemoteItem remote, String purpose) async {
    tree.native.checkRoot(tree.fd, tree.root.path);
    final file = artifacts.reserve(remote.path, purpose);
    await cloud.download(remote.path, file, etag: remote.etag);
    tree.native.checkRoot(tree.fd, tree.root.path);
    artifacts.complete(
      file,
      hash: await fileHash(file, purpose),
      etag: remote.etag,
    );
    tree.native.checkRoot(tree.fd, tree.root.path);
    return file;
  }

  /// One reconcile pass. [between] runs at each candidate-path boundary so
  /// queued commands are serviced mid-pass; it returns whether it changed
  /// state. A full pass (startup, audit) reconciles every path; otherwise
  /// only candidates and their ancestors are reconciled. Local content is
  /// stat-scanned every pass and hashed only when its stamp is not trusted.
  /// [remote] decides whether this pass may list and change the cloud; a
  /// pass that does not stops after recording local state (no network).
  Future<void> tick({
    Future<bool> Function()? between,
    RemotePolicy remote = RemotePolicy.always,
  }) async {
    final watch = Stopwatch()..start();
    final meter = tree.native.meter;
    final files = meter.files, bytes = meter.bytes;
    final filesBy = Map<String, int>.of(meter.filesBy);
    final rows = manifest.rowsPersisted, transactions = manifest.transactions;
    final audit =
        _fullPending ||
        _lastAudit == null ||
        _clock.elapsed - _lastAudit! >= auditInterval;
    final startedPasses = passes;
    _visited = 0;
    _inPass = true;
    remoteListed = false;
    remoteFailed = false;
    var candidates = 0;
    try {
      // Rows are compared once per audit cycle; the full path reconcile stays
      // due until a pass completes it (an offline or paused pass cannot).
      if (audit && !_rowsAudited) {
        manifest.markAllRows();
        _rowsAudited = true;
        rowAudits++;
      }
      candidates = await _tick(audit, between, remote);
      _recordMountIdentities();
    } finally {
      _inPass = false;
      // Every pass ends at a commit point (flag SC-051): grouped manifest
      // commits are flushed once here, not once each.
      manifest.commitPoint();
      _deferred.clear();
      activity.clearPlan();
      stopRequested = false;
      lastPass = PassMetrics(
        full: audit,
        completed: passes > startedPasses,
        candidates: candidates,
        pathsVisited: _visited,
        filesHashed: meter.files - files,
        bytesHashed: meter.bytes - bytes,
        filesHashedBy: {
          for (final v in meter.filesBy.entries)
            if (v.value != (filesBy[v.key] ?? 0))
              v.key: v.value - (filesBy[v.key] ?? 0),
        },
        rowsWritten: manifest.rowsPersisted - rows,
        transactions: manifest.transactions - transactions,
        durationMicros: watch.elapsedMicroseconds,
        localScan: _localScan,
        pathsStatted: _statted,
        fullScans: fullScans,
      );
    }
  }

  static const _passiveOperations = {
    'artifact',
    'retained',
    'excluded-entry',
    'excluded-operation',
    // A device-trash copy (spec #44): no work, never a reason to visit.
    'trash',
  };
  static String _localSignature(LocalItem item) =>
      '${item.kind.name}|${item.identity}|${item.scanStamp}|${item.hash}';

  bool _blocks(Entry? entry) =>
      entry != null &&
      entry.kind == ItemKind.directory &&
      (entry.conflict != null ||
          entry.awaitingFolderUpload ||
          (entry.etag == null && isCantSyncName(entry.status)) ||
          operation(entry.path, 'delete') != null);

  /// This device's operating system for the per-device local names
  /// (spec #49 R3). Test seam.
  NameOs nameOs = NameRule.current;

  /// Whether a row says its full path is over [win32MaxPath] characters
  /// ([longPathNote]; Windows). Test seam.
  bool notesLongPaths = Platform.isWindows;

  /// The residual row of a never-synchronized local item whose name no rule
  /// resolves (spec #49 Error States), else null.
  String? _residualStatus(Entry entry) {
    if (entry.etag != null) return null;
    final problem = NameRule.cloudCheck(p.posix.basename(entry.path));
    return problem == null ? null : cantSyncNameStatus(problem);
  }

  /// Mirrors the reconcile branches below that upload or download a file's
  /// bytes. Presentation only: a wrong guess shows a file as syncing until
  /// the pass reaches it, and never changes what the pass does.
  bool _expectsTransfer(
    String path,
    Map<String, LocalItem> local,
    Map<String, RemoteItem> remote,
  ) {
    final entry = manifest.entries[path];
    final here = local[path];
    final current = remote[path];
    if (entry == null) {
      return current?.kind == ItemKind.file &&
          retention(path) == Retention.local;
    }
    if (entry.kind != ItemKind.file ||
        entry.conflict != null ||
        operation(path, 'delete') != null ||
        (current != null && current.kind != ItemKind.file) ||
        (current == null && entry.etag != null) ||
        (here == null && current == null)) {
      return false;
    }
    if (here != null && here.hash != entry.baselineHash) {
      if (current == null && _residualStatus(entry) != null) return false;
      return !_uploadWaits(here);
    }
    if (current == null ||
        (current.etag == entry.etag && !entry.refreshRemote && here != null)) {
      return false;
    }
    return !(retention(path) == Retention.cloud && here == null);
  }

  /// Whether the upload of [here] waits: refused for its size, over the
  /// limit the server reported, or backing off after an interruption.
  bool _uploadWaits(LocalItem here) {
    final limit = cloud.uploadLimit;
    return (limit != null && here.size > limit) ||
        uploads.waiting(
          here.path,
          _localSignature(here),
          size: here.size,
          limit: limit,
        );
  }

  /// Whether [op]'s staged snapshot still holds exactly [here]'s bytes: the
  /// same content hash, and the staged file unchanged since it was written.
  bool _snapshotCurrent(Operation op, LocalItem here) {
    final staged = op.staged;
    return staged != null &&
        op.hash != null &&
        op.hash == here.hash &&
        _stagedIntact(staged, op.hash!);
  }

  /// The staged file at [staged] is the completed copy recorded with [hash]
  /// and has not changed since: same identity and stamp as recorded.
  bool _stagedIntact(String staged, String hash) {
    final Operation? record;
    try {
      record = artifacts.record(artifacts.resolve(staged));
    } on FileSystemException {
      return false;
    }
    if (record == null ||
        record.phase != 'complete' ||
        record.hash != hash ||
        record.data['identity'] == null) {
      return false;
    }
    try {
      final info = artifacts.native.info(
        tree.stageFd,
        record.data['name'] as String,
      );
      return info.identity == record.data['identity'] &&
          info.stamp == record.data['stamp'];
    } on FileSystemException {
      return false;
    }
  }

  /// A file this client never synchronized left the root, and the listing
  /// shows the cloud does not have it. Existing rules decide the outcome:
  /// an entry without a version that is removed locally becomes the
  /// terminal "removed locally" (see the local scan), and a staging copy
  /// the server does not provably hold is retained as a recovery copy,
  /// never queued (decision #37). So the pending upload is cancelled; its
  /// complete snapshot, the only remaining copy of those bytes, is kept as
  /// a recovery copy; without one the row simply ends.
  void _settleUnsyncedRemoval(Entry entry) {
    uploads.forget(entry.path);
    final op = operation(entry.path, 'upload');
    if (op != null) {
      final staged = op.staged;
      if (staged != null &&
          op.hash != null &&
          artifacts.resolve(staged).existsSync() &&
          !manifest.operations.values.any(
            (o) => o.kind == 'retained' && o.staged == staged,
          )) {
        final retained = Operation(
          uniqueId(),
          'retained',
          entry.path,
          staged: staged,
          hash: op.hash,
        )..data = {'unsyncedRemoval': true};
        manifest.operations[retained.id] = retained;
      }
      manifest.operations.remove(op.id);
    }
    entry.expectedPresent = false;
    entry.status = 'removed locally';
    manifest.save();
  }

  /// Gateway added times seen by this process (file ID -> Unix seconds) and
  /// the cursor after the last page (spec #24, decision #56). The first
  /// fetch of a run starts from 0, so a restart rebuilds the map.
  final Map<int, int> _added = {};
  int _addedCursor = 0;

  /// A listing changed since metadata was last applied. Survives a pass that
  /// ends early, so the next listing applies it even if nothing changes then.
  bool _metadataDue = true;

  /// Copies listing metadata (file ID, and for files the cloud modification
  /// time) onto entries and fetches new added times. Runs only when the listing changed,
  /// so a steady state adds no request; never while paused (no pass lists).
  /// A failed or unsupported fetch leaves New ordered, with the dates known.
  Future<void> _listingMetadata(Map<String, RemoteItem> remote) async {
    for (final item in remote.values) {
      final entry = manifest.entries[item.path];
      if (entry == null || entry.kind != item.kind) continue;
      // Every row keeps its cloud file ID, folders too: a cloud move pairs
      // by it (spec #33 I2).
      entry.fileId = item.fileId;
      entry.cloudName = names.listedCloudNames[item.path];
      if (item.kind == ItemKind.file) entry.remoteModified = item.modified;
    }
    try {
      // Bounded: a page holds at most 1000 rows; the next change resumes.
      for (var page = 0; page < 200; page++) {
        final result = await cloud.addedSince(_addedCursor);
        if (result == null) break;
        if (result.reset) {
          _added.clear();
          _addedCursor = 0;
          continue;
        }
        _added.addAll(result.added);
        _addedCursor = result.cursor;
        if (!result.more) break;
      }
    } on Exception {
      // Kept: dates already applied; the next listing change retries.
    }
    if (_added.isEmpty) return;
    for (final entry in manifest.entries.values) {
      final id = entry.kind == ItemKind.file ? entry.fileId : null;
      final at = id == null ? null : _added[id];
      if (at != null) entry.addedAt = at;
    }
  }

  // Directory sharing (spec #26).

  /// Incoming shares as last listed, by mount path (`Shared/<folder>`, or
  /// `Documents/<folder>` and the like for a placed share, spec #34 P6).
  /// Persisted, so rows keep "Shared by" offline and a disabled owner's
  /// folder stays paused across restarts.
  Map<String, IncomingShare> get incoming {
    if (_incoming == null) {
      try {
        _incoming = {
          for (final row
              in jsonDecode(manifest.setting(_incomingKey) ?? '[]') as List)
            (row as Map)['path'] as String: IncomingShare.fromJson(row),
        };
      } on Object {
        _incoming = {};
      }
    }
    return _incoming!;
  }

  Map<String, IncomingShare>? _incoming;
  static const _incomingKey = 'incomingSharesV1';

  /// Recipient names of this account's shared folders, by path: the shared
  /// indicator's tooltip. Fetched only when the set of shared folders changes
  /// (or after Manage sharing saves), never on every pass.
  Map<String, List<String>> get outgoingNames {
    if (_outgoingNames == null) {
      try {
        _outgoingNames = {
          for (final row in (jsonDecode(
            manifest.setting(_outgoingKey) ?? '{}',
          ) as Map).entries)
            row.key as String: (row.value as List).cast<String>(),
        };
      } on Object {
        _outgoingNames = {};
      }
    }
    return _outgoingNames!;
  }

  Map<String, List<String>>? _outgoingNames;
  static const _outgoingKey = 'outgoingNamesV1';
  Set<String>? _outgoingFetchedFor;

  /// Incoming mounts paused this pass: the owner's account is disabled, or
  /// the incoming list could not be read while the mount vanished. Nothing
  /// under them is uploaded, downloaded, deleted or inferred deleted.
  Set<String> _heldMounts = {};
  bool _held(String path) {
    // A file another program holds open (SC-048 F5): nothing is inferred
    // or transferred for it this pass.
    if (tree.busy.contains(path)) return true;
    final mount = mountOf(path);
    return (mount != null && _heldMounts.contains(mount)) ||
        _heldTargets.any((target) => withinOrAt(target, path));
  }

  /// The folder holding [path] where an incoming share may be mounted: the
  /// `Shared/<folder>` above it (a mount or the recipient's own folder, see
  /// [isIncomingMountPath]), or a share placed in `Documents`, `Music` or
  /// `Videos` (spec #34 P6) that the incoming list names; null otherwise.
  String? mountOf(String path) {
    final shared = incomingMountOf(path);
    if (shared != null) return shared;
    final parts = path.split('/');
    if (parts.length < 2 || !placementFolders.contains(parts.first)) {
      return null;
    }
    final mount = '${parts[0]}/${parts[1]}';
    return incoming.containsKey(mount) ? mount : null;
  }

  /// Whether [path] is an incoming mount or lies inside one.
  bool inIncomingShare(String path) {
    final mount = mountOf(path);
    return mount != null && isIncomingMountPath(mount);
  }

  void _holdUnavailable() {
    _heldMounts = {
      for (final share in incoming.values)
        if (share.ownerUnavailable) share.path,
    };
  }

  /// The incoming list, at most once per listing pass and never while
  /// paused (no pass lists then). False when it could not be read.
  Future<bool> _refreshIncoming() async {
    final api = cloud;
    if (api is! SharingApi) return true;
    try {
      final shares = await (api as SharingApi).incomingShares();
      _incoming = {for (final share in shares ?? const []) share.path: share};
      manifest.setSetting(
        _incomingKey,
        jsonEncode([for (final share in _incoming!.values) share.toJson()]),
      );
      return true;
    } on Exception {
      return false;
    }
  }

  /// Replaces the shared indicator's names (after Manage sharing loads or
  /// saves, or when the set of shared folders changed).
  void applyOutgoing(List<OutgoingShare> shares) {
    final names = <String, List<String>>{};
    for (final share in shares) {
      (names[share.path] ??= []).add(share.recipientName);
    }
    for (final list in names.values) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    _outgoingNames = names;
    manifest.setSetting(_outgoingKey, jsonEncode(names));
  }

  /// A share was created, changed or removed here: refetch the names.
  void outgoingChanged() => _outgoingFetchedFor = null;

  Future<void> _refreshOutgoing() async {
    final shared = {
      for (final entry in manifest.entries.values)
        if (entry.sharedOut) entry.path,
    };
    final previous = _outgoingFetchedFor;
    if (previous != null &&
        previous.length == shared.length &&
        previous.containsAll(shared)) {
      return;
    }
    final api = cloud;
    if (shared.isEmpty || api is! SharingApi) {
      if (outgoingNames.isNotEmpty) applyOutgoing(const []);
      _outgoingFetchedFor = shared;
      return;
    }
    try {
      applyOutgoing(await (api as SharingApi).outgoingShares());
      _outgoingFetchedFor = shared;
    } on Exception {
      // Kept: the names already known; the next change retries.
    }
  }

  /// Inside an incoming share where this account may not write (spec #26):
  /// a file without write permission, a folder without create permission,
  /// or a new item whose nearest listed folder is such a folder.
  bool viewOnly(String path) {
    final mount = mountOf(path);
    if (mount == null) return false;
    final own = manifest.entries[path];
    final permissions = own?.permissions;
    if (own != null && permissions != null) {
      return permissionsViewOnly(
        permissions,
        directory: own.kind == ItemKind.directory,
      );
    }
    for (
      var parent = p.posix.dirname(path);
      withinOrAt(mount, parent);
      parent = p.posix.dirname(parent)
    ) {
      final listed = manifest.entries[parent]?.permissions;
      if (listed != null) return permissionsViewOnly(listed, directory: true);
    }
    return incoming[mount]?.permission == SharePermission.view;
  }

  /// The top folder of an incoming share is gone locally: deleting it would
  /// leave the share (out of scope), so it and its contents are restored.
  bool _mountRemoved(String path, Map<String, LocalItem> local) {
    final mount = mountOf(path);
    return mount != null &&
        isIncomingMountPath(mount) &&
        manifest.entries[mount]?.etag != null &&
        !local.containsKey(mount);
  }

  /// What removing an incoming share's folder here means, asked for any
  /// path under a removed mount (decisions #150, #154, #155):
  /// - null: restored, nothing is sent: its top folder (or `Shared`) is gone
  ///   or replaced, the owner is unavailable, a conflict is inside, the
  ///   share is View only, the folder was moved into another folder (the
  ///   moved copy is this account's own), or sharing is unavailable;
  /// - `to` null: deleted for everyone once the removal has settled
  ///   ([_leaveRemovedMounts]);
  /// - `to` set: renamed for everyone, to the folder beside it that has its
  ///   file identity ([_renameRemovedMounts]).
  ({String mount, String? to})? _mountChange(
    String path,
    Map<String, LocalItem> local,
  ) {
    final mount = mountOf(path);
    if (mount == null || cloud is! SharingApi || !_mountRemoved(path, local)) {
      return null;
    }
    // A whole top folder deleted restores everything in it (#150).
    if (restoredWithTopFolder(mount, local)) return null;
    if (local[p.posix.dirname(mount)]?.kind != ItemKind.directory) return null;
    final share = incoming[mount];
    if (share == null || share.ownerUnavailable) return null;
    // Asked once per removed row: the subtree is scanned once per pass.
    return _mountChanges.putIfAbsent(mount, () {
      if (manifest.entries.values.any(
        (entry) => withinOrAt(mount, entry.path) && entry.conflict != null,
      )) {
        return null;
      }
      // Never "deleted for everyone" without its identity on record (a
      // rename could not be told apart): restored instead (review F-H2).
      final inode = _inode(_knownIdentity(mount));
      if (inode == null) return null;
      for (final item in local.values) {
        // By file number, like the top folders (review F-L1), and only
        // with a known file of the share inside under the same name and
        // file number: ext4 and XFS give a freed number to the next new
        // folder, so a number alone never makes a rename (review G-H1).
        // Without that, the removal is a leave, never a rename. A renamed
        // folder keeps its birth time too, where one is recorded (SC-074).
        if (!_sameFolder(mount, item) ||
            item.path == mount ||
            item.kind != ItemKind.directory ||
            !_holdsKnownItem(mount, item.path)) {
          continue;
        }
        // Renamed in place: for everyone. Moved into another folder: the
        // share stays where it is and the moved copy is this account's.
        return p.posix.dirname(item.path) == p.posix.dirname(mount)
            ? (mount: mount, to: item.path)
            : null;
      }
      return (mount: mount, to: null);
    });
  }

  /// Per pass: what a removed incoming mount's removal means.
  final Map<String, ({String mount, String? to})?> _mountChanges = {};

  /// Row wording while a folder shared out comes back (decision #162).
  static const sharedOutRestoring =
      'Moved, renamed or replaced on this device without proof that it is '
      'the same folder, and a shared folder is involved: restored from the '
      'cloud. The new folder is uploaded as a new folder.';

  /// The local identity (volume and file number) last recorded for the
  /// synchronized item at [path]: its row's, the one the identity index
  /// keeps (spec #33 I1), so top folders, `Shared` and incoming mounts are
  /// recognised from the same record as every moved item.
  String? _knownIdentity(String path) => manifest.entries[path]?.localIdentity;

  /// Per-folder identity records of versions before rows carried identities
  /// (spec #34 P6/P7 builds). [_migrateLegacyIdentities] moves them onto
  /// their rows once and deletes them.
  static const _legacyTopIdentityKey = 'topFolderInodesV1';
  static const _legacySharedIdentityKey = 'sharedFolderInodeV1';
  static const _legacyMountIdentityKey = 'mountIdentitiesV1';
  static const _legacyMountFilesKey = 'mountFilesV1';
  bool _legacyMigrated = false;

  /// Once per engine, before anything reads an identity: each legacy record
  /// becomes its row's identity where the row has none, then the four keys
  /// are deleted, so nothing reads a record frozen at the upgrade again.
  /// File numbers recorded alone (no volume) stay that way on the row: the
  /// top folder, share and sample checks compare file numbers, identity
  /// pairing never matches them, and the next scan of the item replaces them
  /// with its full identity.
  void _migrateLegacyIdentities() {
    if (_legacyMigrated) return;
    final keys = [
      _legacyTopIdentityKey,
      _legacySharedIdentityKey,
      _legacyMountIdentityKey,
      _legacyMountFilesKey,
    ];
    if (keys.every((key) => manifest.setting(key) == null)) {
      _legacyMigrated = true;
      return;
    }
    void adopt(String path, Object? identity) {
      final row = manifest.entries[path];
      if (row != null && row.localIdentity == null && identity is String) {
        row.localIdentity = identity;
      }
    }

    Map<dynamic, dynamic> map(String key) {
      try {
        return jsonDecode(manifest.setting(key) ?? '{}') as Map;
      } on Object {
        return const {};
      }
    }

    for (final MapEntry(:key, :value) in map(_legacyTopIdentityKey).entries) {
      adopt(key as String, value);
    }
    adopt(sharedFolder, manifest.setting(_legacySharedIdentityKey));
    for (final MapEntry(:key, :value) in map(_legacyMountIdentityKey).entries) {
      adopt(key as String, value);
    }
    for (final MapEntry(key: mount, value: files) in map(
      _legacyMountFilesKey,
    ).entries) {
      if (files is! Map) continue;
      for (final MapEntry(key: inside, value: inode) in files.entries) {
        adopt('$mount/$inside', inode);
      }
    }
    manifest.save();
    for (final key in keys) {
      manifest.deleteSetting(key);
    }
    // Only now: a failed save or delete is retried on the next pass (#78
    // delta review D-L1).
    _legacyMigrated = true;
  }

  /// How many of a shared folder's items are checked to tell a rename of it
  /// apart.
  static const _mountFileSamples = 8;

  /// A few items of the shared folder [folder] (an incoming mount, or a
  /// folder shared out), by path inside it, with their kinds and file
  /// numbers from their rows (the identity index's record). Only items
  /// still expected on disk (no deletion pending), files and folders alike
  /// (decision #162): a folder that holds one of them under the same name,
  /// kind and number is that folder moved or renamed (review G-H1).
  Map<String, ({ItemKind kind, String inode})> _knownSamples(String folder) {
    final samples = <String, ({ItemKind kind, String inode})>{};
    for (final entry
        in manifest.entries.values
            .where(
              (e) =>
                  (e.kind == ItemKind.file || e.kind == ItemKind.directory) &&
                  e.localIdentity != null &&
                  e.expectedPresent &&
                  e.conflict == null &&
                  p.posix.isWithin(folder, e.path),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path))) {
      if (samples.length == _mountFileSamples) break;
      samples[entry.path.substring(folder.length + 1)] = (
        kind: entry.kind,
        inode: _inode(entry.localIdentity)!,
      );
    }
    return samples;
  }

  /// Whether [candidate] holds a known item of [folder] under the same name,
  /// kind and file number ([_knownSamples]).
  bool _holdsKnownItem(String folder, String candidate) {
    for (final MapEntry(key: inside, value: known) in _knownSamples(
      folder,
    ).entries) {
      try {
        final fresh = tree.statItem('$candidate/$inside');
        if (fresh?.kind == known.kind &&
            _inode(fresh!.identity) == known.inode) {
          return true;
        }
      } on Object {
        continue;
      }
    }
    return false;
  }

  /// Records on their rows, from a fresh stat, the identity of each incoming
  /// mount and of its first files ([_mountSamples]) that have none yet: at
  /// the end of every pass, so a share folder (and its files) this pass's
  /// downloads created is on record at once (review F-H2), with or without a
  /// listing. Every later pass's scan keeps those rows current; a mount gone
  /// from disk keeps its last identity on its row.
  void _recordMountIdentities() {
    for (final mount in incoming.keys) {
      final row = manifest.entries[mount];
      if (row == null || row.etag == null) continue;
      try {
        if (row.localIdentity == null) {
          final fresh = tree.statItem(mount);
          if (fresh?.kind != ItemKind.directory) continue;
          _recordFolder(mount, fresh!);
        }
        var files = 0;
        for (final entry
            in manifest.entries.values
                .where(
                  (e) =>
                      e.kind == ItemKind.file &&
                      e.etag != null &&
                      p.posix.isWithin(mount, e.path),
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path))) {
          if (files == _mountFileSamples) break;
          if (entry.localIdentity == null) {
            final file = tree.statItem(entry.path);
            if (file?.kind != ItemKind.file) continue;
            entry.localIdentity = _recordedIdentity(file!);
          }
          if (entry.localIdentity != null) files++;
        }
      } on Object {
        continue;
      }
    }
  }

  /// When each removed mount was first found gone (not durable: a restart
  /// waits again, the safe direction).
  final Map<String, Duration> _mountMissingSince = {};

  /// Paths held this pass besides held mounts: the new name of a mount
  /// whose rename for everyone is waiting (never uploaded meanwhile).
  final Set<String> _heldTargets = {};

  /// Renames each incoming share whose folder was renamed in place here, for
  /// everyone (decision #155). On success the rows, the listing and the
  /// incoming list take the new name. A name the owner already has there
  /// is refused: the folder here gets its old name back. Any other failure
  /// holds both names (nothing uploaded, restored or deleted) and retries.
  Future<void> _renameRemovedMounts(
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
    Map<String, RemoteItem> rawRemote,
  ) async {
    final api = cloud;
    if (api is! SharingApi) return;
    for (final share in incoming.values.toList()) {
      final mount = share.path;
      if (_heldMounts.contains(mount) ||
          !remote.containsKey(mount) ||
          manifest.entries[mount]?.status != renamingForEveryone) {
        continue;
      }
      final to = _mountChange(mount, local)?.to;
      if (to == null) continue;
      if (NamePolicy.sameInCloud(mount, to)) {
        // One name in the cloud (decision #138): only the rows follow.
        _rekey(mount, to, local);
        _renameIncoming(mount, to);
        continue;
      }
      String? renamed;
      try {
        renamed = await (api as SharingApi).renameForEveryone(
          share.shareId,
          p.posix.basename(to),
        );
      } on CloudFailure catch (error) {
        // A name the owner has, or a View only share made earlier (403):
        // refused for good, so the old name comes back (review G-L2).
        if ((error.status == 409 && error.message.contains('already has')) ||
            error.status == 403) {
          _undoMountRename(mount, to, local, rawLocal, error.message);
        } else {
          _heldMounts.add(mount);
          _heldTargets.add(to);
          manifest.entries[mount]?.status =
              'Waiting to rename this shared folder for everyone: ${error.message}';
          _dirty.add(mount);
        }
        continue;
      } on Exception catch (error) {
        _heldMounts.add(mount);
        _heldTargets.add(to);
        manifest.entries[mount]?.status =
            'Waiting to rename this shared folder for everyone: $error';
        _dirty.add(mount);
        continue;
      }
      final at = renamed ?? to;
      if (at != to) {
        // This account's mount kept another name: the folder here follows.
        try {
          tree.native.renameExclusive(tree.fd, to, at, local[to]!.identity!);
        } on Object {
          _heldMounts.add(mount);
          _heldTargets.add(to);
          continue;
        }
        local.removeWhere((path, _) => withinOrAt(to, path));
        rawLocal.removeWhere((path, _) => withinOrAt(to, path));
        markDirty(at);
      }
      _rekey(mount, at, local);
      _renameIncoming(mount, at);
      for (final listing in [rawRemote, remote]) {
        for (final path
            in listing.keys.where((v) => withinOrAt(mount, v)).toList()) {
          final old = listing.remove(path)!;
          final moved = renamedPath(mount, at, path);
          listing[moved] = RemoteItem(
            moved,
            old.kind,
            old.etag,
            size: old.size,
            fileId: old.fileId,
            modified: old.modified,
            permissions: old.permissions,
            shared: old.shared,
          );
        }
      }
      _mountMissingSince.remove(mount);
    }
  }

  /// The owner already has the new name: the folder here takes its old name
  /// back (by its file identity), and says why.
  void _undoMountRename(
    String mount,
    String to,
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    String reason,
  ) {
    try {
      tree.native.renameExclusive(tree.fd, to, mount, local[to]!.identity!);
    } on Object {
      _heldMounts.add(mount);
      _heldTargets.add(to);
      return;
    }
    for (final path
        in manifest.entries.keys
            .where(
              (v) => withinOrAt(to, v) && manifest.entries[v]!.etag == null,
            )
            .toList()) {
      manifest.entries.remove(path);
      uploads.forget(path);
    }
    local.removeWhere((path, _) => withinOrAt(to, path));
    rawLocal.removeWhere((path, _) => withinOrAt(to, path));
    _seenLocal.removeWhere((path, _) => withinOrAt(to, path));
    // Back on disk; the next scan sees it in place (nothing restored now).
    _heldMounts.add(mount);
    manifest.entries[mount]?.status =
        '$reason. This shared folder keeps its name.';
    markDirty(mount, descendants: true);
    manifest.save();
  }

  /// Leaves each incoming share whose folder was removed here (decision
  /// #157: a recipient's delete ends the share for this account and never
  /// changes the owner's folder), once its removal was inferred (after the
  /// SC-054 delay on event-driven passes) and has settled: the folder has
  /// been gone, and nothing else under it, its top folder or `Shared` has
  /// gone missing, for [topDeleteSettle], and a fresh check finds the folder
  /// still gone and its top folder (or `Shared`) still the same folder. A
  /// recursive delete removes contents first, so a pass caught in between
  /// never decides; a whole top folder or `Shared` deleted restores
  /// everything instead (#150). On success the folder leaves this pass's
  /// listing (the rows end, nothing is sent for them); a failure holds it
  /// (nothing restored or deleted) and retries.
  Future<void> _leaveRemovedMounts(
    Map<String, LocalItem> local,
    Map<String, RemoteItem> remote,
    Map<String, RemoteItem> rawRemote,
  ) async {
    final api = cloud;
    if (api is! SharingApi) return;
    for (final share in incoming.values.toList()) {
      final mount = share.path;
      if (_heldMounts.contains(mount) ||
          !remote.containsKey(mount) ||
          manifest.entries[mount]?.status != leavingShare) {
        _mountMissingSince.remove(mount);
        continue;
      }
      final change = _mountChange(mount, local);
      if (change == null || change.to != null) continue;
      final now = _elapsed;
      final since = _mountMissingSince.putIfAbsent(mount, () => now);
      if (now - _settledSince(mount, since) < topDeleteSettle) {
        _heldMounts.add(mount);
        _deletesHeld = true;
        _localWork = true;
        continue;
      }
      if (!_goneUnderSameParent(mount)) {
        _heldMounts.add(mount);
        continue;
      }
      try {
        await (api as SharingApi).leaveShare(share.shareId);
      } on Exception catch (error) {
        _heldMounts.add(mount);
        manifest.entries[mount]?.status =
            'Could not leave this shared folder yet: ${error is CloudFailure ? error.message : error}. Retrying; nothing was deleted.';
        _dirty.add(mount);
        continue;
      }
      _mountMissingSince.remove(mount);
      _incoming!.remove(mount);
      manifest.setSetting(
        _incomingKey,
        jsonEncode([for (final share in _incoming!.values) share.toJson()]),
      );
      _listedMounts.remove(mount);
      remote.removeWhere((path, _) => withinOrAt(mount, path));
      rawRemote.removeWhere((path, _) => withinOrAt(mount, path));
      _dirty.addAll(
        manifest.entries.keys.where((path) => withinOrAt(mount, path)),
      );
    }
  }

  /// The latest of [since] and the last loss under [path]'s top folder or
  /// share folder.
  Duration _settledSince(String path, Duration since) {
    var settled = since;
    for (final key in [
      ?topFolderOf(path),
      ?_shareFolderOf(path),
      if (inSharedFolder(path)) sharedFolder,
    ]) {
      final loss = _topLastLoss[key];
      if (loss != null && loss.compareTo(settled) > 0) settled = loss;
    }
    return settled;
  }

  /// The incoming mount holding [path] (or [path] itself), when it is one.
  String? _shareFolderOf(String path) {
    final mount = mountOf(path);
    return mount != null && isIncomingMountPath(mount) ? mount : null;
  }

  /// A fresh check at send time: [mount] is gone from disk, and the folder
  /// it was in is still a folder (for a top folder, the same one).
  bool _goneUnderSameParent(String mount) {
    try {
      if (tree.statItem(mount) != null) return false;
      final parent = p.posix.dirname(mount);
      final fresh = tree.statItem(parent);
      if (fresh == null || fresh.kind != ItemKind.directory) return false;
      if ((isTopFolder(parent) || parent == sharedFolder) &&
          !_sameFolder(parent, fresh)) {
        return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Never merges an incoming share into a folder of the same name that
  /// exists only on this device (no synchronized history): the gateway sees
  /// only the server's names, so it can place a share where this device has
  /// a folder not uploaded yet (spec #34 P6 review H1). That folder is
  /// renamed to `<name> (this device)` and uploaded later as this account's
  /// own; the share arrives at its own name. Same for a mount in `Shared/`.
  /// A folder is a share here when the incoming list names it, or when this
  /// listing marks it with Nextcloud's `S` (shared with this account), so an
  /// unreadable incoming list, or a share placed after this pass read the
  /// list, still never merges (review D-H1).
  void _setAsideUnsyncedAtMounts(
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
  ) {
    for (final mount in remote.keys.where(isMountPlace).toList()) {
      final here = rawLocal[mount];
      if (here == null ||
          here.kind != ItemKind.directory ||
          !(_listedAsShare(remote[mount]) || isIncomingMountPath(mount)) ||
          manifest.entries.values.any(
            (entry) => withinOrAt(mount, entry.path) && entry.etag != null,
          )) {
        continue;
      }
      final identity = here.identity;
      final aside = _asideName(mount, rawLocal, remote);
      var moved = false;
      if (identity != null && aside != null) {
        try {
          tree.native.renameExclusive(tree.fd, mount, aside, identity);
          moved = true;
        } on FileSystemException {
          // Changed meanwhile: held as a conflict below, never merged.
        }
      }
      if (!moved) {
        conflict(
          manifest.entries.putIfAbsent(
            mount,
            () => Entry(mount, ItemKind.directory),
          ),
          'A folder shared with you has the name of a folder here that was never synchronized. Rename this folder to receive the share.',
        );
        continue;
      }
      for (final op
          in manifest.operations.values
              .where((o) => withinOrAt(mount, o.path))
              .toList()) {
        manifest.operations.remove(op.id);
      }
      for (final path
          in manifest.entries.keys
              .where((v) => withinOrAt(mount, v))
              .toList()) {
        manifest.entries.remove(path);
        uploads.forget(path);
      }
      local.removeWhere((path, _) => withinOrAt(mount, path));
      rawLocal.removeWhere((path, _) => withinOrAt(mount, path));
      _seenLocal.removeWhere((path, _) => withinOrAt(mount, path));
      // Found by the next scan and uploaded as an ordinary new folder.
      markDirty(aside!);
      _dirty.addAll(remote.keys.where((path) => withinOrAt(mount, path)));
      manifest.save();
    }
  }

  /// Nextcloud marks a folder shared with this account with `S` in its
  /// listed permissions; a mount-shaped folder carrying it is a share
  /// whatever the incoming list says.
  static bool _listedAsShare(RemoteItem? item) =>
      item != null &&
      isMountPlace(item.path) &&
      (item.permissions?.contains('S') ?? false);

  /// `<name> (this device)`, then `(this device 2)`… free here and in the
  /// cloud; null when none is.
  String? _asideName(
    String path,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
  ) {
    for (var n = 1; n < 100; n++) {
      final candidate = '$path (this device${n == 1 ? '' : ' $n'})';
      if (!rawLocal.containsKey(candidate) &&
          !remote.containsKey(candidate) &&
          !manifest.entries.containsKey(candidate) &&
          FileSystemEntity.typeSync(
                '${tree.root.path}/$candidate',
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    return null;
  }

  /// A case-only rename of a placed share's folder moves the mount in the
  /// cloud (it stays a direct child of the same folder); the incoming list
  /// follows at once so the share keeps its rules under the new name.
  void _renameIncoming(String from, String to) {
    final share = incoming[from];
    if (share == null) return;
    _incoming!
      ..remove(from)
      ..[to] = IncomingShare(
        share.shareId,
        to,
        share.ownerName,
        share.permission,
        ownerUnavailable: share.ownerUnavailable,
      );
    manifest.setSetting(
      _incomingKey,
      jsonEncode([for (final share in _incoming!.values) share.toJson()]),
    );
    if (_listedMounts.remove(from) case final listed?) {
      _listedMounts[to] = listed;
    }
  }

  /// Whether the folder directly under `Shared/` at [path] is an incoming
  /// share's mount, decided from the incoming list, else from Nextcloud's
  /// permissions (an incoming mount carries `S`, shared with this account);
  /// a recipient's own folder there has neither and syncs normally. While
  /// the incoming list has never been read, it counts as a mount: restored
  /// and protected rather than risk leaving a share.
  bool isIncomingMountPath(String path) {
    // In Documents, Music or Videos only the incoming list names a mount
    // (spec #34 P6), and fresh permissions without `S` still overrule it.
    if (isPlacedMountPlace(path)) {
      if (!incoming.containsKey(path)) return false;
      if (_listedMounts[path] case final listed?) return listed.contains('S');
      return true;
    }
    if (!isIncomingMount(path)) return false;
    // Fresh permissions win: the latest listing says what the folder is now,
    // even if an incoming list kept from an earlier pass still names it.
    if (_listedMounts[path] case final listed?) return listed.contains('S');
    if (incoming.containsKey(path)) return true;
    final permissions = manifest.entries[path]?.permissions;
    if (permissions != null) return permissions.contains('S');
    return manifest.setting(_incomingKey) == null;
  }

  /// `oc:permissions` of each folder directly under `Shared/` in the latest
  /// listing (empty until this process lists).
  Map<String, String> _listedMounts = {};

  /// A local removal that must not reach the cloud, and why; null otherwise.
  /// A deleted top folder decides first: everything in it, shares included,
  /// is restored (#150). Then an incoming share's folder removed here: for
  /// everyone (deleted or renamed, decisions #154, #155) or restored.
  String? _restoreReason(String path, Map<String, LocalItem> local) {
    if (_keptTopRemoval(path, local)) {
      final status = manifest.entries[path]?.status;
      // A share folder kept because it changed, `Shared` restored, or a
      // folder shared out kept (decision #162).
      if (status == sharedFolderRestoring || status == sharedOutRestoring) {
        return status;
      }
      return topFolderRestoring;
    }
    if (_mountChange(path, local) case final change?) {
      return change.to == null ? leavingShare : renamingForEveryone;
    }
    if (viewOnly(path)) return viewOnlyRestoring;
    if (_mountRemoved(path, local)) return sharedFolderRestoring;
    return null;
  }

  /// Top folders deleted on this device whose notice is still owed: shown
  /// while they are restored and once when they are back.
  final Set<String> _topNotices = {};
  bool _topNoticesResumed = false;

  /// Spec #34 P7 (decision #150), each pass before the scan is read: each of
  /// `Documents`, `Music` and `Videos` is a real folder in the root. One
  /// that is gone (deleted or renamed away) is created again; a file or
  /// link holding its name is first moved aside as
  /// `<name> (conflict copy)`, never deleted. When one was gone, replaced,
  /// or is a different folder than the last pass saw (deleted and created
  /// again, by the user or by a transfer during a pass), every synchronized
  /// item of it that is now missing here is marked restoring: it comes back
  /// from the cloud and its absence is never a deletion. Throws when a top
  /// folder cannot be made a folder; the pass then infers nothing.
  void _keepTopFolders(Map<String, LocalItem> rawLocal) {
    _topsRestoredThisPass.clear();
    for (final top in topFolders) {
      // Renamed in case only (on a case-insensitive volume the folder is
      // then listed only under the new spelling): renamed back.
      var item = rawLocal[top] ?? _respellTop(top, rawLocal);
      var restore = false;
      if (item == null || item.kind != ItemKind.directory) {
        if (item != null) {
          final aside = topFolderAsideName(
            top,
            (name) =>
                rawLocal.containsKey(name) ||
                manifest.entries.containsKey(name) ||
                tree.statItem(name) != null,
          );
          try {
            tree.native.renameExclusive(tree.fd, top, aside, item.identity!);
          } on FileSystemException {
            // A FIFO, socket, device node or Windows junction: never removed.
            throw TopFolderBlocked(top);
          }
          // Found and uploaded (or held) as an ordinary new item.
          tree.own(aside);
          markDirty(aside);
        }
        tree.ensureDirectory(top, keptTop: true);
        item = tree.statItem(top);
        if (item == null || item.kind != ItemKind.directory) {
          throw FileSystemException('$top could not be created again', top);
        }
        rawLocal[top] = item;
        restore = true;
      } else if (!_sameFolder(top, item)) {
        restore = true;
      }
      // On the row, the record the identity index keeps (spec #33 I1);
      // even before the folder is synchronized, so a replacement is seen.
      _recordFolder(top, item);
      if (restore) _restoreTop(top, rawLocal);
    }
  }

  /// The file number of an identity (`<volume>:<inode>`): a folder deleted
  /// and created again gets a new one, while a change of the volume key
  /// alone (a legacy root migrated, a btrfs device change) keeps it.
  /// Whether [item] is still the folder recorded at [path] (top folders,
  /// `Shared`, incoming mounts): the same file number and, where both are
  /// known, the same birth time. ext4 and f2fs give a folder deleted and
  /// created again its old number (flag SC-074); its birth time differs.
  /// Without a record it counts as the same (nothing to compare).
  bool _sameFolder(String path, LocalItem item) {
    final known = _inode(_knownIdentity(path));
    if (known == null) return true;
    if (_inode(item.identity) != known) return false;
    final birth = manifest.entries[path]?.localBirth;
    return birth == null || item.birth == null || birth == item.birth;
  }

  /// Whether [item] is a folder whose identity [_sameFolder] checks: a top
  /// folder, `Shared` or an incoming share's folder. Only these record a
  /// birth time.
  bool _birthTracked(LocalItem item) =>
      item.kind == ItemKind.directory &&
      (isTopFolder(item.path) ||
          item.path == sharedFolder ||
          _shareFolderOf(item.path) == item.path);

  /// Records [item] as the folder at [path] (its row's identity and birth).
  void _recordFolder(String path, LocalItem item) {
    final row = manifest.entries[path];
    if (row == null || item.identity == null) return;
    row
      ..localIdentity = item.identity
      ..localBirth = item.birth;
  }

  static String? _inode(String? identity) =>
      identity?.substring(identity.lastIndexOf(':') + 1);

  /// The top folder [top] listed only under another spelling of the same
  /// name (a case- or normalization-only rename): renamed back to [top],
  /// the scan's items re-keyed, and returned; null without one.
  LocalItem? _respellTop(String top, Map<String, LocalItem> rawLocal) {
    final key = NamePolicy.foldKey(top);
    final variants = [
      for (final item in rawLocal.values)
        if (item.kind == ItemKind.directory &&
            !item.path.contains('/') &&
            item.path != top &&
            NamePolicy.foldKey(item.path) == key)
          item,
    ];
    if (variants.length != 1 || variants.single.identity == null) return null;
    final from = variants.single.path;
    try {
      tree.native.renameExclusive(
        tree.fd,
        from,
        top,
        variants.single.identity!,
      );
    } on FileSystemException {
      return null;
    }
    for (final path
        in rawLocal.keys.where((v) => withinOrAt(from, v)).toList()) {
      final old = rawLocal.remove(path)!;
      final moved = renamedPath(from, top, path);
      rawLocal[moved] = old.movedTo(moved);
    }
    if (_watching && _view != null) {
      _drop(from);
      watcher!.retainUnder(from, const {});
      _rescan(const {}, {top});
    }
    _touched.addAll({from, top});
    return rawLocal[top];
  }

  /// Global cleanup (spec #49 R1, R2): a local item whose name the cloud
  /// cannot or must not hold, where the rule has a cheap fix (whitespace at
  /// either end, `\` and control characters, too long, a folder ending in
  /// `.part`), is renamed in place under the fixed name: the same item, no
  /// transfer, and a folder carries its subtree. The pass then reads it as
  /// a move of a synchronized item (sent as a cloud rename) or as a new item
  /// under the clean name. Shallowest first, the scan's items re-keyed. A
  /// rename that fails leaves the item as it is ([_residualStatus] shows it).
  /// A name equal to a sibling's by Unicode normalization only (one cloud
  /// name, decision #138) takes R1's ` (n)` the same way
  /// ([_normalizationTwins]).
  void _cleanUpNames(Map<String, LocalItem> rawLocal) {
    int depth(String path) => '/'.allMatches(path).length;
    final twins = _normalizationTwins(rawLocal);
    final candidates = [
      for (final item in rawLocal.values)
        if (_cleanable(item, twin: twins.contains(item.path))) item.path,
    ]..sort((a, b) => depth(a) - depth(b));
    if (candidates.isEmpty) return;
    Map<String, Set<String>>? names;
    Set<String> namesIn(String folder) => (names ??= () {
      final index = <String, Set<String>>{};
      for (final path in [...rawLocal.keys, ...manifest.entries.keys]) {
        index
            .putIfAbsent(p.posix.dirname(path), () => {})
            .add(p.posix.basename(path));
      }
      return index;
    }()).putIfAbsent(folder, () => {});
    final renames = <(String, String)>[];
    for (final listed in candidates) {
      var from = listed;
      for (final (old, now) in renames) {
        if (withinOrAt(old, from)) from = renamedPath(old, now, from);
      }
      final item = rawLocal[from];
      if (item == null || item.identity == null) continue;
      final folder = p.posix.dirname(from), name = p.posix.basename(from);
      final siblings = namesIn(folder);
      final others = siblings.where((v) => v != name);
      final directory = item.kind == ItemKind.directory;
      var clean = NameRule.cleanup(name, siblings: others, folder: directory);
      if (clean == name && twins.contains(listed)) {
        clean = NameRule.suffixed(name, others, folder: directory) ?? name;
      }
      if (clean == name) continue;
      final to = folder == '.' ? clean : '$folder/$clean';
      try {
        tree.native.renameExclusive(tree.fd, from, to, item.identity!);
      } on FileSystemException {
        continue; // Left as it is; its row says why it cannot sync.
      }
      renames.add((from, to));
      siblings
        ..remove(name)
        ..add(clean);
      for (final path
          in rawLocal.keys.where((v) => withinOrAt(from, v)).toList()) {
        final old = rawLocal.remove(path)!;
        final moved = renamedPath(from, to, path);
        rawLocal[moved] = old.movedTo(moved);
      }
      if (_watching && _view != null) {
        _drop(from);
        watcher!.retainUnder(from, const {});
        _rescan(const {}, {to});
      }
      _touched.addAll({from, to});
      // The rows left at the old name are reconciled this pass, even when
      // it is not an audit (a row never synchronized there is settled).
      _dirty.addAll(manifest.entries.keys.where((v) => withinOrAt(from, v)));
    }
  }

  /// A `.part` or `.filepart` file: a download still in progress
  /// (decision #195), never uploaded and shown with no row.
  static bool _temporary(LocalItem item) =>
      item.kind == ItemKind.file &&
      NameRule.isTemporary(p.posix.basename(item.path));

  /// Local items whose name equals a sibling's on disk by Unicode
  /// normalization only: both would be one cloud name (decision #138). The
  /// spelling the cloud item keeps (the synchronized one, else the NFC one,
  /// else the first) stays; every other spelling never synchronized is
  /// renamed with R1's ` (n)` (spec #49: never held). Cheap: nothing to do
  /// while every local name is NFC.
  Set<String> _normalizationTwins(Map<String, LocalItem> rawLocal) {
    bool respelled(String path) => NamePolicy.nfc(path) != path;
    if (!rawLocal.keys.any(respelled)) return const {};
    final groups = <(String, String), List<String>>{};
    for (final path in rawLocal.keys) {
      groups
          .putIfAbsent((
            p.posix.dirname(path),
            NamePolicy.nfc(p.posix.basename(path)),
          ), () => [])
          .add(path);
    }
    bool synced(String path) => manifest.entries[path]?.etag != null;
    bool composed(String path) {
      final name = p.posix.basename(path);
      return NamePolicy.nfc(name) == name;
    }

    final result = <String>{};
    for (final spellings in groups.values) {
      if (spellings.length < 2) continue;
      spellings.sort();
      final keeper = spellings.firstWhere(
        synced,
        orElse: () =>
            spellings.firstWhere(composed, orElse: () => spellings.first),
      );
      result.addAll(spellings.where((v) => v != keeper && !synced(v)));
    }
    return result;
  }

  /// Whether [item] is one [_cleanUpNames] may rename: its name changes
  /// under the rule (or it is a normalization [twin]), and it is not a top
  /// folder, `Shared`, an incoming share's folder, excluded, view-only or a
  /// local temporary.
  bool _cleanable(LocalItem item, {bool twin = false}) {
    final name = p.posix.basename(item.path);
    final folder = item.kind == ItemKind.directory;
    if (!folder && item.kind != ItemKind.file) return false;
    if (!folder && NameRule.isTemporary(name)) return false;
    if (!twin && NameRule.cleanup(name, folder: folder) == name) return false;
    return !isTopFolder(item.path) &&
        item.path != sharedFolder &&
        _shareFolderOf(item.path) != item.path &&
        !isSyncExcluded(item.path) &&
        !viewOnly(item.path);
  }

  /// How long losses under a top folder must have stopped before an
  /// inferred deletion there is sent: the watcher's longest delay plus its
  /// quiet period (about 12 s). A recursive delete of the top folder
  /// removes its contents first; the folder itself goes last (H1).
  Duration get topDeleteSettle =>
      debugTopDeleteSettle ??
      debugTopDeleteSettleAll ??
      watcherSettings.maxDelay + watcherSettings.quiet;
  Duration? debugTopDeleteSettle;

  /// Test seam for every engine of an isolate (suites whose deletions under
  /// Documents are not about the settle time).
  static Duration? debugTopDeleteSettleAll;

  /// Test seam: deletion-produced copies stay Recovery rows as before spec
  /// #44, for tests of the release rules and the Recover and Dismiss
  /// primitives that conflict and eviction copies still use.
  static bool debugDeletionRecoveryRows = false;

  /// When a pass last found an item of each top folder newly missing.
  final Map<String, Duration> _topLastLoss = {};

  /// When each held deletion was first held (not durable: a restart holds
  /// again, the safe direction).
  final Map<String, Duration> _deleteHeldSince = {};

  /// Whether the inferred deletion [op] under a top folder waits, or was
  /// taken back because its top folder is gone or replaced (fresh stat, not
  /// the view). Explicit Delete everywhere and deletions elsewhere are sent
  /// as before.
  ///
  /// The same rule holds deletions inside an incoming share's folder
  /// (spec #34 P6, decision #154): they wait for the same settle, and while
  /// the share folder itself is gone at send time they are never sent; that
  /// folder's own removal decides (deleted for everyone, or restored).
  bool _holdTopDeletion(Operation op, Entry entry) {
    // `Shared` counts as a top folder here (review F-M2).
    final top =
        topFolderOf(op.path) ??
        (inSharedFolder(op.path) && op.path != sharedFolder
            ? sharedFolder
            : null);
    final share = _shareFolderOf(op.path);
    final inShare = share != null && share != op.path;
    if (top == null ||
        op.data['inferred'] != true ||
        op.data['dispatchState'] != 'not-started') {
      return false;
    }
    final now = _elapsed;
    LocalItem? fresh;
    try {
      fresh = tree.statItem(top);
    } on FileSystemException {
      fresh = null;
    }
    if (fresh == null ||
        fresh.kind != ItemKind.directory ||
        !_sameFolder(top, fresh)) {
      finish(op);
      _deleteHeldSince.remove(op.id);
      entry
        ..expectedPresent = true
        ..restoring = true
        ..status = top == sharedFolder
            ? sharedFolderRestoring
            : topFolderRestoring;
      _dirty.add(op.path);
      _localWork = true;
      return true;
    }
    if (inShare) return _holdShareDeletion(op, entry, share, now);
    final since = _deleteHeldSince.putIfAbsent(op.id, () => now);
    _topLastLoss.putIfAbsent(top, () => since);
    if (now - _settledSince(op.path, since) < topDeleteSettle) {
      entry.status = 'delete queued';
      _dirty.add(op.path);
      _localWork = true;
      _deletesHeld = true;
      return true;
    }
    _deleteHeldSince.remove(op.id);
    return false;
  }

  /// A deletion inside the incoming share folder [share]: held for the
  /// settle, and while the share folder itself is gone (fresh stat).
  bool _holdShareDeletion(
    Operation op,
    Entry entry,
    String share,
    Duration now,
  ) {
    final since = _deleteHeldSince.putIfAbsent(op.id, () => now);
    bool gone;
    try {
      gone = tree.statItem(share)?.kind != ItemKind.directory;
    } on FileSystemException {
      gone = true;
    }
    if (gone || now - _settledSince(op.path, since) < topDeleteSettle) {
      entry.status = 'delete queued';
      _dirty.add(op.path);
      _localWork = true;
      _deletesHeld = true;
      return true;
    }
    _deleteHeldSince.remove(op.id);
    return false;
  }

  /// A held deletion is waiting (see [_holdTopDeletion]).
  bool _deletesHeld = false;

  /// When the earliest held deletion may be sent, from now; null without.
  Duration? _heldDeletionDue() {
    if (!_deletesHeld) return null;
    Duration? best;
    void consider(String path, Duration since) {
      final left = _settledSince(path, since) + topDeleteSettle - _elapsed;
      if (best == null || left < best!) best = left;
    }

    for (final MapEntry(key: id, value: since) in _deleteHeldSince.entries) {
      final op = manifest.operations[id];
      if (op != null) consider(op.path, since);
    }
    // Share folders removed here, waiting to be deleted for everyone.
    for (final MapEntry(key: mount, value: since)
        in _mountMissingSince.entries) {
      consider(mount, since);
    }
    return best;
  }

  /// A top folder the listing has only under another spelling of the same
  /// name: moved back to its own name in the cloud (a conditional MOVE),
  /// and the listing re-keyed, so the folder here keeps its name and no
  /// item of it reads as deleted in the cloud (M1).
  Future<void> _respellRemoteTops(
    Map<String, RemoteItem> rawRemote,
    Map<String, RemoteItem> remote,
  ) async {
    for (final top in topFolders) {
      if (rawRemote.containsKey(top) || manifest.entries[top]?.etag == null) {
        continue;
      }
      final key = NamePolicy.foldKey(top);
      final variants = [
        for (final item in rawRemote.values)
          if (item.kind == ItemKind.directory &&
              !item.path.contains('/') &&
              NamePolicy.foldKey(item.path) == key &&
              manifest.entries[item.path]?.etag == null)
            item,
      ];
      if (variants.length != 1) continue;
      final from = variants.single.path;
      await cloud.move(from, top, etag: variants.single.etag);
      for (final listing in [rawRemote, remote]) {
        for (final path
            in listing.keys.where((v) => withinOrAt(from, v)).toList()) {
          final old = listing.remove(path)!;
          final moved = renamedPath(from, top, path);
          listing[moved] = RemoteItem(
            moved,
            old.kind,
            old.etag,
            size: old.size,
            fileId: old.fileId,
            modified: old.modified,
            permissions: old.permissions,
            shared: old.shared,
          );
        }
      }
      _dirty.add(top);
      _metadataDue = true;
    }
  }

  /// Top folders found gone or replaced by this pass's check.
  final Set<String> _topsRestoredThisPass = {};

  /// Whether the absence of [path] is part of its top folder's restore
  /// (spec #34 P7), never a deletion: `Documents`, `Music` or `Videos`
  /// itself, an item marked restoring, an item of a top folder found gone
  /// or replaced by this pass, or one whose top folder is not a folder in
  /// [local]. The one predicate other removal rules consult (a share
  /// placed inside a top folder is restored, not left, when the top folder
  /// itself was deleted: spec #34 P6 ruling).
  bool restoredWithTopFolder(
    String path, [
    Map<String, LocalItem> local = const {},
  ]) {
    if (isTopFolder(path)) return true;
    if (manifest.entries[path]?.restoring ?? false) return true;
    final top = topFolderOf(path);
    if (top == null) return false;
    if (_topsRestoredThisPass.contains(top)) return true;
    return local.isNotEmpty && local[top]?.kind != ItemKind.directory;
  }

  /// Paths whose loss was noted ([_noteLoss]) while they stay missing.
  final Set<String> _lossNoted = {};

  /// A loss of [path] seen now: the settle of its top folder, its incoming
  /// share's folder and `Shared` starts again ([_holdTopDeletion]).
  void _stampLoss(String path) {
    final now = _elapsed;
    if (topFolderOf(path) case final top?) _topLastLoss[top] = now;
    if (_shareFolderOf(path) case final share?) _topLastLoss[share] = now;
    if (inSharedFolder(path)) _topLastLoss[sharedFolder] = now;
  }

  void _noteLoss(String path) {
    final now = _elapsed;
    if (topFolderOf(path) case final top?) _topLastLoss[top] = now;
    if (inSharedFolder(path)) _topLastLoss[sharedFolder] = now;
  }

  /// `Shared` is tracked like the top folders for share decisions (review
  /// F-M2): deleted, or replaced (another file number, e.g. deleted and
  /// created again empty), everything of it that is missing here is marked
  /// restoring and its unsent inferred deletions are taken back, so no share
  /// in it is ever deleted for everyone that way. Unlike the top folders it
  /// is not created again here; restoring its contents brings it back.
  void _keepSharedFolder(Map<String, LocalItem> rawLocal) {
    if (manifest.entries[sharedFolder]?.etag == null) return;
    final item = rawLocal[sharedFolder];
    if (item == null ||
        item.kind != ItemKind.directory ||
        !_sameFolder(sharedFolder, item)) {
      _takeBackUnsentDeletes(
        (path) => withinOrAt(sharedFolder, path),
        inferredOnly: true,
      );
      for (final entry in manifest.entries.values) {
        if (!withinOrAt(sharedFolder, entry.path) ||
            rawLocal.containsKey(entry.path) ||
            !entry.expectedPresent ||
            entry.etag == null ||
            entry.conflict != null) {
          continue;
        }
        entry
          ..restoring = true
          ..status = sharedFolderRestoring;
        _dirty.add(entry.path);
      }
      _localWork = true;
      manifest.save();
    }
    // The scan records the folder's new identity on its row (spec #33 I1).
  }

  /// Marks every synchronized item of [top] missing from [rawLocal] as
  /// restoring (see [_keepTopFolders]), and takes back every inferred
  /// deletion under it that was never sent: a recursive delete removes the
  /// contents first, so an earlier pass may have queued them (H1).
  void _restoreTop(String top, Map<String, LocalItem> rawLocal) {
    _topsRestoredThisPass.add(top);
    _takeBackUnsentDeletes(
      (path) => p.posix.isWithin(top, path),
      inferredOnly: true,
    );
    for (final entry in manifest.entries.values) {
      if (!p.posix.isWithin(top, entry.path) ||
          rawLocal.containsKey(entry.path) ||
          !entry.expectedPresent ||
          entry.etag == null ||
          entry.conflict != null) {
        continue;
      }
      entry.restoring = true;
      entry.status = topFolderRestoring;
      _dirty.add(entry.path);
    }
    _dirty.add(top);
    _localWork = true;
    _topNotices.add(top);
    manifest.save();
  }

  /// One-time notes from the legacy Cloud-root migration: a top folder's
  /// files directly in it download (L3).
  final List<String> _topLocalNotes = [];

  void _topNowLocal(String top, int files, int bytes) {
    _topLocalNotes.add(
      '$top always stays on this device now: its folders keep Cloud-only'
      '${files == 0 ? '.' : ', and the ${files == 1 ? 'file' : '$files files'} directly in it (${formatBytes(bytes)}) ${files == 1 ? 'downloads' : 'download'}.'}',
    );
  }

  /// The status-line notice for top folders deleted here (one per
  /// deletion: while restoring, and once when back); null without one.
  String? _topFolderNote() {
    final once = _topLocalNotes.join(' ');
    _topLocalNotes.clear();
    final deleted = _topDeletionNote();
    final notes = [?deleted, if (once.isNotEmpty) once];
    return notes.isEmpty ? null : notes.join(' ');
  }

  String? _topDeletionNote() {
    if (_topNotices.isEmpty && _topNoticesResumed) return null;
    final restoring = <String>{
      for (final entry in manifest.entries.values)
        if (entry.restoring &&
            entry.status != sharedOutRestoring &&
            topFolderOf(entry.path) != null)
          topFolderOf(entry.path)!,
    };
    // After a restart in the middle of a restore, its notice resumes.
    _topNoticesResumed = true;
    _topNotices.addAll(restoring);
    final done = _topNotices.where((top) => !restoring.contains(top)).toList();
    _topNotices.removeAll(done);
    return topFolderNotice(restoring, done);
  }

  /// Spec #34 P7: `Documents`, `Music` or `Videos` itself, an item marked
  /// as restoring when its top folder was found gone or replaced
  /// ([_keepTopFolders]), or an item whose top folder is not a folder in
  /// this scan.
  bool _keptTopRemoval(String path, Map<String, LocalItem> local) =>
      restoredWithTopFolder(path, local);

  /// A synchronized item that is no longer here: a delete intent, unless it
  /// must be restored instead or its owner is unavailable.
  void _inferRemoval(Entry entry, Map<String, LocalItem> local) {
    // A disabled owner's folder: nothing is inferred (decision #80 (2)).
    if (_held(entry.path)) return;
    // View only, or the top of an incoming share: restored, not deleted.
    final restore = entry.etag == null
        ? null
        : _restoreReason(entry.path, local);
    if (restore != null) {
      if (restore == topFolderRestoring) entry.restoring = true;
      // A new loss (not one already being restored or decided) extends the
      // settle under its top folder and under `Shared` (review F-M2).
      if (_lossNoted.add(entry.path)) _noteLoss(entry.path);
      entry.status = restore;
      _dirty.add(entry.path);
      return;
    }
    if (entry.etag != null) {
      final explicit = operation(entry.path, 'delete') != null;
      final op = intent(entry.path, 'delete', etag: entry.etag);
      if (!explicit) op.data['inferred'] = true;
      // A loss under a top folder: its deletions wait until losses there
      // have settled (H1). Likewise inside an incoming share's folder.
      _stampLoss(entry.path);
    }
    entry.status = entry.etag == null ? 'removed locally' : 'delete queued';
    entry.expectedPresent = false;
  }

  /// Pending case- or normalization-only renames (SC-054): an operation at
  /// the old path whose `to` is the new one.
  Iterable<Operation> get _moves =>
      manifest.operations.values.where((o) => o.kind == 'move');

  static String _moveTarget(Operation op) => op.data['to'] as String;

  /// Nothing under [path] is in flight or in conflict, apart from removals
  /// never sent ([ignoreUnsentDeletes]), so the whole subtree can move.
  bool _quietSubtree(String path, {bool ignoreUnsentDeletes = false}) =>
      !manifest.entries.values.any(
        (e) => withinOrAt(path, e.path) && e.conflict != null,
      ) &&
      !manifest.operations.values.any(
        (o) =>
            withinOrAt(path, o.path) &&
            !_passiveOperations.contains(o.kind) &&
            !(ignoreUnsentDeletes && _unsentDelete(o)),
      );

  /// A partial pass (any platform with a watcher) sees a path vanish when it
  /// is rescanned, which can happen before the other side of its rename has
  /// reached the view: inotify can split a MOVED_FROM/MOVED_TO pair across
  /// batches (SC-058), and FSEvents reports each side on its own (#133 (2)).
  /// A synchronized item is never deleted in the cloud on one such pass
  /// (decision #140). Where the platform looks identities up
  /// ([RootFilesystem.locatesIdentity], spec #33 I3) and the lookup is
  /// switched on ([identityLookup]) a certain answer decides at once
  /// ([_lookUpVanished]). Elsewhere, and after an uncertain
  /// answer, the removal is held until the path has been missing for the
  /// watcher's quiet period, longer only while the watcher still has
  /// unprocessed paths, and never longer than its maximum delay. Full scans
  /// and the stat audit decide at once; an uncertain hold that ends asks for
  /// one ([_uncertain]).
  final Map<String, Duration> _missingSince = {};

  /// Synchronized paths the identity lookup did not find this pass: their
  /// removal is not held.
  final Set<String> _lookedUpGone = {};

  /// Whether a new engine uses the platform's identity lookup (spec #33 I3).
  /// Off: the lookup ships disabled until it is verified on macOS and
  /// Windows, so a platform build that answers it does not switch it on.
  static const bool identityLookupByDefault = false;

  /// The kill switch for the identity lookup ([identityLookupByDefault]).
  /// Off, the engine never calls [RootFilesystem.locateIdentity] and behaves
  /// exactly as on a platform that does not support it: every unpaired
  /// removal on a partial pass is held (decision #140).
  bool identityLookup = identityLookupByDefault;

  /// At most this many lookups in one pass ([_lookUpVanished]); beyond it the
  /// rest is uncertain (held, then a full scan decides).
  static const int maxLookupsPerPass = 512;

  /// Synchronized paths whose lookup this pass was uncertain (an error, a
  /// staging answer, an inside answer the rescan did not confirm): held as on
  /// Linux, and when the hold ends they are never deleted on a partial pass.
  /// The full scan they ask for decides at once.
  final Set<String> _uncertain = {};

  bool _deferRemoval(String path, ChangeWatcher? w) {
    if (_localScan != 'partial' ||
        w == null ||
        !w.active ||
        _lookedUpGone.contains(path)) {
      return false;
    }
    final now = _elapsed;
    final since = _missingSince.putIfAbsent(path, () {
      // A loss is a loss when first seen, held or not: deletions already
      // waiting under the same top folder, `Shared` or share folder keep
      // waiting for the settle (flag SC-075). Otherwise a delete that
      // pauses longer than the quiet period would send the earlier losses
      // while the rest is still on its way, and the folder still exists.
      // Once per loss ([_lossNoted], cleared when the path is back): a row
      // kept for a restore or a leave is held again on later passes, and
      // that is no new loss.
      if (_lossNoted.add(path)) _stampLoss(path);
      return now;
    });
    final missing = now - since;
    // Never longer than the maximum delay, even while the watcher stays busy.
    if (missing < w.settings.maxDelay &&
        (missing < w.settings.quiet || w.pending.isNotEmpty)) {
      return true;
    }
    _missingSince.remove(path);
    return false;
  }

  /// An uncertain lookup's hold ended ([_deferRemoval] returned false) on a
  /// partial pass: the removal is not inferred here. One full scan is asked
  /// for instead ([ChangeWatcher.fullAuditWanted], the audit path), which
  /// decides at once on the next pass; a full scan clears every hold, so
  /// this never keeps the worker due at once (the wake loop a stale hold
  /// would cause).
  bool _auditUncertain(String path, ChangeWatcher? w) {
    if (_localScan != 'partial' ||
        w == null ||
        !w.active ||
        !_uncertain.contains(path)) {
      return false;
    }
    if (!w.fullAuditWanted) {
      w.fullAuditWanted = true;
      uncertainAudits++;
    }
    return true;
  }

  /// Full scans asked for by uncertain lookups ([_auditUncertain]).
  int uncertainAudits = 0;

  /// When the next held removal is due (see [_deferRemoval]).
  Duration? _nextHeldRemoval(ChangeWatcher w) {
    if (_missingSince.isEmpty) return null;
    final now = _elapsed;
    Duration? best;
    for (final since in _missingSince.values) {
      final quiet = since + w.settings.quiet;
      final due = (quiet > now ? quiet : since + w.settings.maxDelay) - now;
      if (best == null || due < best) best = due;
    }
    return best;
  }

  /// Monotonic time for the removal deferral (test seam: [debugElapsed]).
  Duration Function()? debugElapsed;
  Duration get _elapsed => debugElapsed?.call() ?? _clock.elapsed;

  /// Spec #33 I3, on a partial pass where the platform looks identities up
  /// and [identityLookup] is on: each synchronized item missing from [view]
  /// is looked up by its recorded identity. A folder found inside covers
  /// what is beneath it (it moves with the folder); a folder found gone does
  /// not, so each missing item beneath it is looked up on its own (at most
  /// [maxLookupsPerPass] lookups a pass, the rest uncertain).
  ///
  /// Certain answers decide at once (decisions #140 and #143):
  /// * inside the root, confirmed: the path is rescanned into this pass and
  ///   the item there is the recorded one (identity, kind) and names its
  ///   file alone ([_alone]: an effective link count of 1, the engine's own
  ///   staging links discounted), so the pair is planned as a move;
  /// * outside the root (the Trash) or not found: a delete, not held; for a
  ///   folder only when every missing item beneath it is certainly gone too,
  ///   otherwise the folder is held (uncertain) with what is not.
  ///
  /// Every other answer is uncertain ([_uncertain]): an error or a thrown
  /// lookup, an inside answer the rescan does not confirm (nothing there,
  /// another item, a second link), and a staging answer (macOS names one
  /// link of a hard-linked file). The removal is held as on Linux and never
  /// deleted on a partial pass; when the hold ends a full scan decides.
  void _lookUpVanished(Map<String, LocalItem> view) {
    _lookedUpGone.clear();
    _uncertain.clear();
    final w = watcher;
    if (_localScan != 'partial' ||
        !identityLookup ||
        !tree.native.locatesIdentity ||
        w == null ||
        !w.active ||
        _view == null) {
      return;
    }
    final missing = <String>{
      for (final entry in manifest.entries.values)
        if (entry.etag != null &&
            entry.expectedPresent &&
            entry.conflict == null &&
            entry.localIdentity != null &&
            !view.containsKey(entry.path))
          entry.path,
    };
    bool beneathMissing(String path) {
      for (
        var at = p.posix.dirname(path);
        at != '.';
        at = p.posix.dirname(at)
      ) {
        if (missing.contains(at)) return true;
      }
      return false;
    }

    var lookups = 0;

    /// The answer for [path], an inside answer only when the rescan confirms
    /// it (the recorded item, alone at that path); otherwise uncertain.
    IdentityPlace look(String path) {
      if (lookups >= maxLookupsPerPass) return IdentityPlace.uncertain;
      lookups++;
      final entry = manifest.entries[path]!;
      final identity = entry.localIdentity!;
      try {
        final found = tree.native.locateIdentity(
          tree.fd,
          tree.stageFd,
          identity,
        );
        if (found.place != IdentityPlace.inside) return found.place;
        final at = found.path!;
        if (!view.containsKey(at)) _rescan({at}, const {});
        final item = view[at];
        final confirmed =
            item != null &&
            item.identity == identity &&
            item.kind == entry.kind &&
            _alone(item);
        return confirmed ? IdentityPlace.inside : IdentityPlace.uncertain;
      } on Object {
        return IdentityPlace.uncertain; // Any failure (spec #33 I3).
      }
    }

    bool gone(IdentityPlace place) =>
        place == IdentityPlace.outside || place == IdentityPlace.notFound;

    for (final top in missing.where((v) => !beneathMissing(v)).toList()) {
      final place = look(top);
      final under = missing.where((v) => withinOrAt(top, v)).toList();
      if (place == IdentityPlace.inside) {
        continue; // Paired below as a move; what is beneath moves with it.
      }
      if (!gone(place)) {
        _uncertain.addAll(under);
        continue;
      }
      // A certain answer for a folder is no answer for what was beneath it:
      // an item may have left the folder (moved elsewhere in the root) before
      // the folder went. Each missing item beneath is looked up on its own,
      // shallowest first; one found inside is a move, and everything above
      // an item not certainly gone is held with it (uncertain), so the
      // folder's deletion never takes it along.
      final below = under.where((v) => v != top).toList()
        ..sort((a, b) => '/'.allMatches(a).length - '/'.allMatches(b).length);
      final moved = <String>[];
      final kept = <String>[];
      for (final path in below) {
        if (moved.any((m) => withinOrAt(m, path))) continue;
        final answer = look(path);
        if (answer == IdentityPlace.inside) {
          moved.add(path);
        } else if (!gone(answer)) {
          kept.add(path);
        }
      }
      for (final path in under) {
        if (moved.any((m) => withinOrAt(m, path))) continue;
        final holds = [...moved, ...kept].any((k) => withinOrAt(path, k));
        (holds ? _uncertain : _lookedUpGone).add(path);
      }
    }
  }

  static bool _unsentDelete(Operation op) =>
      op.kind == 'delete' && op.data['dispatchState'] == 'not-started';

  /// Local moves whose new path cannot sync (spec #33 I1 step 5: a name
  /// decision #120 blocks, an exclusion, a held folder), old path -> new
  /// path. For the pass nothing is inferred, sent or downloaded for the old
  /// path: the cloud item stays where it was and the item stays local at its
  /// new name, whose row shows the reason. Planned again every pass.
  final Map<String, String> _parked = {};

  /// New paths whose pairing waits for an enclosing move to be applied (a
  /// child moved out of a folder that moves too): never created meanwhile.
  final Set<String> _waiting = {};

  /// A local rename or move (spec #33 I1, decision #139): a synchronized
  /// item is gone from its path and one new item, the same one, is at
  /// another. Paired by local identity (`volume:inode`, the NTFS file ID)
  /// at any depth and across folders, files and folders alike, never for a
  /// file with more than one link; rows without a recorded identity still
  /// pair as before when the names differ only by case or normalization
  /// (SC-054). Each pair becomes one cloud MOVE of its top item: everything
  /// beneath a moved folder moves with it, and is planned again under the
  /// new path once that move is applied ([_rekey]). A rename that changes
  /// only normalization is one name in the cloud (decision #138), so its
  /// rows simply take the new spelling. A rename already stalled (its
  /// deletion never sent) is picked up too. [under] limits the rows to a
  /// subtree ([inclusive]: with its top, for a move re-planned after it was
  /// abandoned); [raw] (the unfiltered scan, top level only) finds items
  /// moved to an excluded name.
  void _planLocalMoves(
    Map<String, LocalItem> local, {
    String? under,
    bool inclusive = false,
    Map<String, LocalItem>? raw,
  }) {
    final parkedBefore = under == null ? {..._parked.keys} : const <String>{};
    if (under == null) {
      _parked.clear();
      _waiting.clear();
    }
    try {
      _pairLocalMoves(local, under: under, inclusive: inclusive, raw: raw);
    } finally {
      // A row parked last pass and not now: back to ordinary reconciliation.
      for (final path in parkedBefore.where((v) => !_parked.containsKey(v))) {
        for (final entry in manifest.entries.values) {
          if (withinOrAt(path, entry.path) && isMovedHereStatus(entry.status)) {
            entry.status = 'queued';
            _dirty.add(entry.path);
          }
        }
      }
    }
  }

  void _pairLocalMoves(
    Map<String, LocalItem> local, {
    String? under,
    bool inclusive = false,
    Map<String, LocalItem>? raw,
  }) {
    bool inScope(String path) =>
        under == null ||
        (inclusive ? withinOrAt(under, path) : p.posix.isWithin(under, path));
    final moving = [for (final op in _moves) op.path];
    // Paths another pending move will fill. In a re-plan under a move's new
    // path ([_rekey]), that path itself is where the children now are.
    final targets = [
      for (final op in _moves)
        if (_moveTarget(op) != under) _moveTarget(op),
    ];
    final vanished = [
      for (final entry in manifest.entries.values)
        if (inScope(entry.path) &&
            entry.etag != null &&
            entry.conflict == null &&
            !local.containsKey(entry.path) &&
            (entry.expectedPresent ||
                (operation(entry.path, 'delete')?.data['dispatchState'] ==
                    'not-started')) &&
            !moving.any((from) => withinOrAt(from, entry.path)))
          entry.path,
    ]..sort((a, b) => a.length.compareTo(b.length));
    if (vanished.isEmpty) return;
    final appeared = [
      for (final item in local.values)
        if (manifest.entries[item.path] case final entry?
            when entry.etag == null &&
                entry.conflict == null &&
                !entry.expectedPresent &&
                manifest.operationsAt(item.path).isEmpty &&
                !targets.any((to) => withinOrAt(to, item.path)))
          item.path,
    ];
    _unprovenSharedOut.clear();
    final pairs = _pairByIdentity(vanished, {
      for (final path in appeared) path: local[path]!,
    });
    // Names that differ only by case or normalization (#71) pair any row
    // identity left unpaired: one without a recorded identity, or a file
    // whose new name has a second link. The name is its own proof, so a
    // folder shared out renamed in case only still moves.
    final taken = pairs.values.toSet();
    for (final MapEntry(key: from, value: to) in pairRenames(
      vanished.where((v) => !pairs.containsKey(v)),
      appeared.where((v) => !taken.contains(v)),
    ).entries) {
      // Across a shared-out boundary (the shared folder itself, renamed in
      // case only) the name is proof only together with more (#78 reviews
      // D-H1, F-M1, F-L1; decision #162):
      if (_sharedOutRoot(from) != _sharedOutRoot(to)) {
        final entry = manifest.entries[from]!;
        final recorded = entry.localIdentity;
        final item = local[to]!;
        if (recorded == null) {
          // Nothing to compare: never a MOVE, and a folder is restored.
          if (entry.kind == ItemKind.directory) _unprovenSharedOut.add(from);
          continue;
        }
        // Both numbers known and different: provably not a rename. The
        // ordinary rules apply: the owner's delete (for everyone after the
        // holds, #157), and the new folder uploads once its name is free.
        if (recorded != item.identity) continue;
        // The same number is no proof alone (ext4, XFS reuse it): a folder
        // also holds a known item of the old one, or had nothing on disk to
        // check and the new one is empty too.
        if (entry.kind == ItemKind.directory &&
            !_holdsKnownItem(from, to) &&
            !(_knownSamples(from).isEmpty &&
                !local.keys.any((v) => p.posix.isWithin(to, v)))) {
          _unprovenSharedOut.add(from);
          continue;
        }
      }
      pairs[from] = to;
    }
    _unprovenSharedOut.removeWhere(pairs.containsKey);
    _restoreUnprovenSharedOut(local);
    // Top items only. Null: a pair left to the ordinary rules, whose
    // subtree follows those rules too.
    final tops = <String, String?>{};
    for (final from in vanished) {
      final to = pairs[from];
      if (to == null) continue;
      final top = tops.keys.where((t) => p.posix.isWithin(t, from)).firstOrNull;
      if (top != null) {
        final topTo = tops[top];
        // Moved out of a folder that moves too: paired again once the
        // folder's move is applied; until then never created.
        if (topTo != null && !withinOrAt(topTo, to)) _waiting.add(to);
        continue;
      }
      tops[from] = _planMove(from, to, local) ? to : null;
    }
    if (raw == null) return;
    // Moved to a name that is not synchronized (an exclusion): the cloud
    // item stays where it was (spec #33 I1 step 5).
    final excluded = {
      for (final item in raw.values)
        if (isSyncExcluded(item.path) && item.identity != null)
          item.identity!: item,
    };
    if (excluded.isEmpty) return;
    for (final from in vanished) {
      if (pairs.containsKey(from) ||
          tops.keys.any((t) => withinOrAt(t, from)) ||
          _parked.keys.any((t) => withinOrAt(t, from))) {
        continue;
      }
      final entry = manifest.entries[from]!;
      final identity = entry.localIdentity;
      final item = identity == null ? null : excluded[identity];
      if (item == null ||
          item.kind != entry.kind ||
          !_alone(item) ||
          manifest.identities.localAmbiguous(identity!) ||
          _held(from) ||
          _restoreReason(from, local) != null) {
        continue;
      }
      _park(
        from,
        item.path,
        status: movedNotSyncedStatus(p.posix.basename(item.path)),
      );
    }
  }

  /// Staging names whose manifest record claims each identity: where a
  /// root item may have a link the engine holds itself (a download is
  /// installed by hard link from its staging copy on Linux, macOS and
  /// Windows; Android renames it instead). A hint only, rebuilt when the
  /// operations change: [_ownLinks] proves each name on disk.
  Map<String, Set<String>>? _stagedByIdentity;
  int _stagedVersion = -1;

  Set<String> _stagedNames(String identity) {
    if (_stagedByIdentity == null ||
        _stagedVersion != manifest.operationsVersion) {
      final names = <String, Set<String>>{};
      for (final op in artifacts.records) {
        final claimed = op.data['identity'], name = op.data['name'];
        if (claimed is String && name is String) {
          (names[claimed] ??= {}).add(name);
        }
      }
      _stagedByIdentity = names;
      _stagedVersion = manifest.operationsVersion;
    }
    return _stagedByIdentity![identity] ?? const {};
  }

  /// Staging entries stat-ed for a link-count proof (test seam).
  int stagingStats = 0;

  /// Links of [identity] the engine provably holds: claimed staging names
  /// that a stat of the name, in the private staging directory, finds to be
  /// that same volume:inode now. A claim with nothing on disk counts nothing.
  int _ownLinks(String identity) {
    var count = 0;
    for (final name in _stagedNames(identity)) {
      stagingStats++;
      try {
        if (artifacts.native.info(tree.stageFd, name).identity == identity) {
          count++;
        }
      } on FileSystemException {
        // Gone or unreadable: not the engine's link.
      }
    }
    return count;
  }

  /// The identity a synchronized row records for [item] on every pass, with
  /// no stat: a folder, a file with one link, or a file with more whose
  /// identity a staging record claims (a download; proven only when it pairs,
  /// [_alone]). Null for a file the user hard-linked: never paired.
  String? _recordedIdentity(LocalItem item) {
    final identity = item.identity, links = item.links;
    if (identity == null) return null;
    if (item.kind == ItemKind.directory) return identity;
    if (item.kind != ItemKind.file || links == null) return null;
    if (links == 1) return identity;
    return _stagedNames(identity).isEmpty ? null : identity;
  }

  /// Whether [item] names its file alone, so it may pair (spec #33): a
  /// folder, or a file whose effective link count is exactly 1, the scan's
  /// link count less the engine's own staging links ([_ownLinks]). Stats
  /// staging only for a file with more than one link.
  bool _alone(LocalItem item) {
    final identity = item.identity, links = item.links;
    if (identity == null) return false;
    if (item.kind == ItemKind.directory) return true;
    if (item.kind != ItemKind.file || links == null) return false;
    return links == 1 || links - _ownLinks(identity) == 1;
  }

  /// The nearest folder at or above [path] that this account shares out
  /// (its row says so); null when none.
  String? _sharedOutRoot(String path) {
    for (var at = path; at != '.' && at.isNotEmpty; at = p.posix.dirname(at)) {
      final row = manifest.entries[at];
      if (row != null && row.sharedOut && row.kind == ItemKind.directory) {
        return at;
      }
    }
    return null;
  }

  /// Proof beyond the file number that [item] is the row at [from]
  /// (decision #162): a folder holds a known item of it under the same
  /// name ([_holdsKnownItem]); a file has the size and modification time
  /// the row recorded (a rename keeps both).
  bool _provenSame(Entry entry, String from, LocalItem item) =>
      entry.kind == ItemKind.directory
      ? _holdsKnownItem(from, item.path)
      : entry.kind == ItemKind.file &&
            entry.size == item.size &&
            entry.localModified != null &&
            entry.localModified == modifiedSeconds(item.scanStamp);

  /// Folders shared out whose file number another new folder has, without
  /// proof that it is the same folder (this pass).
  final Set<String> _unprovenSharedOut = {};

  /// A folder shared out, or a folder crossing into or out of one, that may
  /// have been moved here but cannot be proven to be the new folder
  /// (decision #162, #78 delta review D-M1): never deleted that way. Its
  /// items missing here are restored from the cloud (the folder and its
  /// Cloud-only items were never touched there), and the new folder uploads
  /// as a new folder.
  void _restoreUnprovenSharedOut(Map<String, LocalItem> local) {
    for (final folder in _unprovenSharedOut) {
      for (final entry in manifest.entries.values) {
        if (!withinOrAt(folder, entry.path) ||
            local.containsKey(entry.path) ||
            !entry.expectedPresent ||
            entry.etag == null ||
            entry.conflict != null) {
          continue;
        }
        entry
          ..restoring = true
          ..status = sharedOutRestoring;
        _dirty.add(entry.path);
      }
      _localWork = true;
    }
  }

  /// Vanished rows paired with appeared items by recorded local identity.
  /// An identity two rows claim, or two appeared items share, pairs nothing.
  Map<String, String> _pairByIdentity(
    List<String> vanished,
    Map<String, LocalItem> appeared,
  ) {
    final byIdentity = <String, String?>{};
    for (final item in appeared.values) {
      final identity = item.identity;
      if (identity == null ||
          (item.kind != ItemKind.directory && item.kind != ItemKind.file)) {
        continue;
      }
      byIdentity[identity] = byIdentity.containsKey(identity)
          ? null
          : item.path;
    }
    if (byIdentity.isEmpty) return {};
    final pairs = <String, String>{};
    for (final from in vanished) {
      final entry = manifest.entries[from]!;
      final identity = entry.localIdentity;
      if (identity == null || manifest.identities.localAmbiguous(identity)) {
        continue;
      }
      final to = byIdentity[identity];
      if (to == null || appeared[to]!.kind != entry.kind) continue;
      // Shared folders never pair by a file number alone: ext4 and XFS give
      // a freed number to the next new item (decision #162, which restates
      // #160; #89 review G-H1).
      // An incoming share's folder (in Shared/ or placed in a top folder)
      // pairs only when a known item of it is found under the same name and
      // number; otherwise it is left or restored ([_restoreReason]) and the
      // new folder is this account's own.
      if (_shareFolderOf(from) == from && !_holdsKnownItem(from, to)) continue;
      // A move into or out of a folder this account shares out, the shared
      // folder itself included, needs the same proof (a file: the same size
      // and modification time), so a deleted private item never surfaces in
      // a share and a share never moves onto an unrelated folder. Without
      // it a file is a delete plus a create. A folder, the shared folder
      // itself or any folder crossing the boundary (Cloud-only contents
      // included), is never deleted that way: its old place is restored and
      // the new folder uploads as a new folder ([_restoreUnprovenSharedOut],
      // #78 delta review D-M1).
      final root = _sharedOutRoot(from);
      if (root != _sharedOutRoot(to) &&
          !_provenSame(entry, from, appeared[to]!)) {
        if (entry.kind == ItemKind.directory) _unprovenSharedOut.add(from);
        continue;
      }
      pairs[from] = to;
    }
    // The link-count proof, only where it decides: a top pair (one beneath
    // a paired folder moves with it). A pair without it is dropped.
    pairs.removeWhere((from, to) {
      for (
        var at = p.posix.dirname(from);
        at != '.';
        at = p.posix.dirname(at)
      ) {
        if (pairs.containsKey(at)) return false;
      }
      return !_alone(appeared[to]!);
    });
    return pairs;
  }

  /// Plans the move of the synchronized item at [from] to [to]: a pending
  /// cloud MOVE, an immediate re-key where the cloud name is unchanged, or a
  /// park when the new path cannot sync. False when the pair is left to the
  /// ordinary rules (a restore, a held owner, a move across storages, work
  /// in flight beneath it).
  bool _planMove(String from, String to, Map<String, LocalItem> local) {
    final entry = manifest.entries[from]!;
    if (entry.kind != local[to]!.kind ||
        _held(from) ||
        // A top folder's contents restored (#150), or a share folder renamed
        // here (case only included), which is renamed for everyone after the
        // listing ([_renameRemovedMounts]), not moved here.
        _restoreReason(from, local) != null ||
        isSyncExcluded(to) ||
        !_quietSubtree(from, ignoreUnsentDeletes: true)) {
      return false;
    }
    // Into a paused owner's folder (#80), or onto the new name of a share
    // folder waiting to be renamed for everyone (#155): nothing may be
    // inferred there, so the cloud item stays where it was, whichever
    // storage the new path is in.
    final held = _held(to);
    // Into or out of an incoming share: a new file ID in the cloud, so a
    // delete plus a create as before (spec #33, out of scope).
    // A share placed in Documents, Music or Videos (spec #34 P6) is its
    // owner's storage like a mount in Shared/ ([_shareFolderOf]).
    if (!held && _shareFolderOf(from) != _shareFolderOf(to)) return false;
    if (held || NameRule.cloudCheck(p.posix.basename(to)) != null) {
      // The new row shows the rule's own status: the ordinary create path
      // shows a name no rule resolves (spec #49), the owner's folder is
      // paused (#80).
      _park(from, to);
      return true;
    }
    _cancelUnsentDeletes(from);
    uploads.forget(to);
    if (NamePolicy.sameInCloud(
      names.cloudPath(from),
      names.movedCloudPath(from, to),
    )) {
      _rekey(from, to, local);
      return true;
    }
    final op = intent(from, 'move', etag: entry.etag, persist: false);
    op.data['to'] = to;
    entry.status = 'rename queued';
    _dirty
      ..add(from)
      ..add(to);
    return true;
  }

  /// The removals inferred for [from] and beneath it, never sent, are
  /// withdrawn: the item was moved, not deleted.
  void _cancelUnsentDeletes(String from) => _takeBackUnsentDeletes(
    (path) => withinOrAt(from, path),
    inferredOnly: false,
  );

  /// The one take-back of deletions never sent, for a move (spec #33 I1)
  /// and for a top folder or `Shared` restored (spec #34 P7): each unsent
  /// deletion at a path [where] accepts is withdrawn, its row is expected
  /// here again, and its settle hold ([_holdTopDeletion]) ends with it.
  /// [inferredOnly] keeps an explicit Delete everywhere.
  void _takeBackUnsentDeletes(
    bool Function(String path) where, {
    required bool inferredOnly,
  }) {
    for (final op
        in manifest.operations.values
            .where(
              (o) =>
                  _unsentDelete(o) &&
                  (!inferredOnly || o.data['inferred'] == true) &&
                  where(o.path),
            )
            .toList()) {
      manifest.operations.remove(op.id);
      _deleteHeldSince.remove(op.id);
      manifest.entries[op.path]?.expectedPresent = true;
    }
  }

  /// Keeps the cloud item at [from] while the item is local at [to].
  void _park(String from, String to, {String status = movedHereStatus}) {
    _cancelUnsentDeletes(from);
    _parked[from] = to;
    final entry = manifest.entries[from];
    if (entry != null && entry.conflict == null) entry.status = status;
    _dirty
      ..add(from)
      ..add(to);
  }

  bool _parkedOrWaiting(String path) =>
      _waiting.contains(path) || _parked.keys.any((v) => withinOrAt(v, path));

  /// Carries out pending local moves (spec #33 I1, SC-054) and applies the
  /// cloud's own case- or normalization-only renames here. Runs after the
  /// listing and before deletions and creates, so neither side is
  /// reconciled as a deletion plus a new item. A move whose new folder is a
  /// move's target comes after that move.
  Future<void> _reconcileMoves(
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
  ) async {
    final seen = <String>{};
    int depth(String path) => '/'.allMatches(path).length;
    // One commit point per pass for every move planned in it (decisions
    // #136, #137): taken after their rows and operations are written and
    // before the first MOVE is sent, never once per move (a 1,000-file drag
    // would cost a full flush each on macOS).
    Set<String>? durable; // Moves covered by this pass's commit point.
    var stopped = false; // A commit point failed: nothing more is sent.
    while (true) {
      final op =
          (_moves.where((o) => !seen.contains(o.id)).toList()..sort((a, b) {
                final byTarget = depth(_moveTarget(a))
                    .compareTo(depth(_moveTarget(b)));
                return byTarget != 0
                    ? byTarget
                    : a.path.length.compareTo(b.path.length);
              }))
              .firstOrNull;
      if (op == null) break;
      seen.add(op.id);
      final from = op.path, to = _moveTarget(op);
      final entry = manifest.entries[from];
      final current = remote[from], target = remote[to];
      if (entry == null ||
          entry.conflict != null ||
          !local.containsKey(to) ||
          local.containsKey(from)) {
        // Renamed again or back, or removed: no longer this move. Moved on
        // again, it is paired afresh from where the cloud still has it.
        _abandonMove(
          op,
          local,
          replan:
              entry != null &&
              entry.conflict == null &&
              !local.containsKey(from),
        );
        continue;
      }
      if (current == null &&
          target != null &&
          target.kind == entry.kind &&
          (entry.fileId == null ||
              target.fileId == null ||
              entry.fileId == target.fileId)) {
        // Already moved: a lost acknowledgement, or the same rename made
        // on another device.
        _rekey(from, to, local);
        finish(op);
        continue;
      }
      if (current == null || target != null || current.kind != entry.kind) {
        // Deleted in the cloud (the item is kept and uploaded at its new
        // name, as a local change meeting a cloud delete), or another item
        // took the name: ordinary reconciliation.
        _abandonMove(op, local);
        continue;
      }
      final parent = p.posix.dirname(to);
      if (parent != '.' && remote[parent]?.kind != ItemKind.directory) {
        // Moved into a folder the cloud does not have yet: this pass creates
        // it, and the move follows on the next.
        entry.status = 'rename pending: waiting for its folder';
        _localWork = true;
        continue;
      }
      if (stopped) continue;
      // A move planned during this loop (re-planned by a re-key or an
      // abandoned move) is made durable by another commit point first.
      if (durable == null || !durable.contains(op.id)) {
        manifest.save();
        try {
          manifest.commitPoint();
        } on FileSystemException catch (error) {
          // Not durable: no move is sent this pass; all stay pending.
          entry.status = 'rename pending: $error';
          stopped = true;
          continue;
        }
        durable = {for (final o in _moves) o.id};
      }
      barrier?.call('move-before-dispatch', op);
      try {
        await cloud.move(from, to, etag: current.etag);
      } on NameNotPortable {
        // A name the cloud refuses (spec #49 residual): kept local at it,
        // where the ordinary create path shows why; the cloud item stays.
        finish(op);
        _park(from, to);
        continue;
      } catch (error) {
        entry.status = 'rename pending: $error';
        manifest.save();
        continue;
      }
      for (final path
          in remote.keys.where((v) => withinOrAt(from, v)).toList()) {
        final item = remote.remove(path)!;
        final moved = renamedPath(from, to, path);
        remote[moved] = _respelled(item, moved);
      }
      _rekey(from, to, local);
      finish(op);
    }
    _applyRemoteMoves(local, rawLocal, remote);
  }

  /// The pending rename no longer applies: what was skipped for it is
  /// reconciled the ordinary way, starting with the removals it deferred.
  void _abandonMove(
    Operation op,
    Map<String, LocalItem> local, {
    bool replan = false,
  }) {
    final from = op.path, to = _moveTarget(op);
    finish(op);
    if (replan) _planLocalMoves(local, under: from, inclusive: true);
    final moving = [for (final o in _moves) o.path];
    for (final entry in manifest.entries.values.toList()) {
      if (withinOrAt(from, entry.path) &&
          entry.expectedPresent &&
          entry.conflict == null &&
          !local.containsKey(entry.path) &&
          !moving.any((root) => withinOrAt(root, entry.path)) &&
          !_parkedOrWaiting(entry.path)) {
        _inferRemoval(entry, local);
      }
    }
    final held = manifest.entries[to];
    if (held != null && held.etag == null && isCantSyncName(held.status)) {
      held.status = 'queued';
    }
    _dirty
      ..add(from)
      ..add(to);
    manifest.save();
  }

  /// Cloud moves this pass leaves for a later one (spec #33 I2): the old
  /// row, the new cloud path and where the item is on disk. None of them is
  /// reconciled this pass, so nothing is deleted, downloaded or uploaded for
  /// them; every pass pairs them again.
  final Set<String> _cloudHeld = {};

  bool _cloudHolds(String path) {
    if (_cloudHeld.isEmpty) return false;
    for (var at = path; ; at = p.posix.dirname(at)) {
      if (_cloudHeld.contains(at)) return true;
      if (at == '.' || !at.contains('/')) return false;
    }
  }

  /// Rows the cloud renamed while this device renamed the same item to
  /// another name: row path -> where the item is on disk (spec #33, both
  /// sides renamed). The cloud's name wins (planner ruling): the local item
  /// is renamed to it, never the cloud item to the local name.
  final Map<String, String> _renamedBothSides = {};

  /// The commit point of this pass's local renames for cloud moves (decision
  /// #137): taken once, before the first rename, never once per rename.
  bool _cloudMovesDurable = false;

  /// Before the pass's local moves are sent (spec #33 I2): a pending local
  /// move whose row the listing no longer has, while the row's file ID is
  /// listed at another new path, is a rename on both sides. Its MOVE is
  /// withdrawn and the cloud's name applied by [_applyRemoteMoves].
  void _claimBothSidesRenamed(Map<String, RemoteItem> remote) {
    _renamedBothSides.clear();
    _cloudMovesDurable = false;
    _cloudHeld.clear();
    final moves = _moves.toList();
    if (moves.isEmpty) return;
    final listed = _listedFileIds(remote);
    for (final op in moves) {
      final from = op.path, to = _moveTarget(op);
      final entry = manifest.entries[from];
      final id = entry?.fileId;
      if (entry == null ||
          entry.conflict != null ||
          id == null ||
          remote.containsKey(from)) {
        continue;
      }
      final there = listed[id];
      if (there == null ||
          there == to ||
          remote[there]!.kind != entry.kind ||
          manifest.identities.pathOfFileId(id) != from) {
        continue;
      }
      finish(op);
      _renamedBothSides[from] = to;
    }
  }

  /// File ID -> the one listed path without a synchronized row holding it;
  /// an ID listed twice maps to null (paired with nothing).
  Map<int, String?> _listedFileIds(Map<String, RemoteItem> remote) {
    final ids = <int, String?>{};
    for (final item in remote.values) {
      final id = item.fileId;
      if (id == null || manifest.entries[item.path]?.etag != null) continue;
      ids[id] = ids.containsKey(id) ? null : item.path;
    }
    return ids;
  }

  /// Moves made in the cloud (spec #33 I2, decision #139): a synchronized
  /// row missing from the listing and a listed item at a path with no row,
  /// with the same file ID and kind, are one item moved, at any depth and
  /// across folders, files and folders alike. Rows without a file ID fall
  /// back to the same-version pairing of case- or normalization-only
  /// renames (SC-054). Each pair moves its top item once: one local rename
  /// carries a folder and everything beneath it, through the guarded rename,
  /// and the rows follow in one commit. A cloud-only row (released, never
  /// downloaded, or deleted here) just changes its path, so a local delete
  /// follows the item to its new name. Never across storages (an incoming
  /// share gives a moved item a new file ID). A new name this device cannot
  /// hold, or one another local item holds, keeps the item where it is with
  /// the Cloud-only hold status; an item that changed meanwhile waits for
  /// the next pass. Neither deletes nor downloads anything.
  ///
  /// A cloud rename to an excluded name is filtered out of the listing
  /// before pairing, so it stays a remote delete with the local copy
  /// preserved (planner ruling on #80).
  ///
  /// Works on whatever the listing holds (decision #139 with SC-057's
  /// pruned listing): a moved folder is listed at its new path, and a row
  /// beneath it that is listed elsewhere is paired on the next round.
  void _applyRemoteMoves(
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
  ) {
    _dropMovedTombstones(remote);
    final settled = <String>{};
    try {
      // Each round applies the top pairs; a row moved out of a folder that
      // moved too pairs again under the folder's new path in the next.
      for (var round = 0; round < 64; round++) {
        final pairs = _pairCloudMoves(remote, settled);
        if (pairs.isEmpty) break;
        var moved = false;
        for (final MapEntry(key: from, value: to) in pairs.entries) {
          if (_applyCloudMove(from, to, local, rawLocal, remote)) {
            moved = true;
          } else {
            settled.add(from);
          }
        }
        if (!moved) break;
      }
    } finally {
      // A local move the cloud's rename did not settle and did not hold:
      // reconciled the ordinary way (the new local name is uploaded).
      _renamedBothSides.clear();
    }
  }

  /// A "deleted" row whose cloud item is listed at another path: the item
  /// moved, it was not deleted. Left when a crash fell between a cloud
  /// move's local rename and its rows for a file the restart cannot pair
  /// (a user hard link): its removal was found already done, and the item
  /// was adopted at its new path (spec #33 I2, accepted cost: one GET).
  /// Dropped on the next listing rather than shown as deleted.
  void _dropMovedTombstones(Map<String, RemoteItem> remote) {
    Map<int, String>? listed;
    for (final entry in manifest.entries.values.toList()) {
      final id = entry.fileId;
      if (id == null ||
          entry.status != 'deleted' ||
          entry.etag != null ||
          entry.expectedPresent ||
          entry.conflict != null ||
          entry.preservedCopies.isNotEmpty ||
          remote.containsKey(entry.path) ||
          manifest.operationsAt(entry.path).isNotEmpty) {
        continue;
      }
      listed ??= {
        for (final item in remote.values)
          if (item.fileId != null) item.fileId!: item.path,
      };
      final there = listed[id];
      if (there == null || there == entry.path) continue;
      manifest.entries.remove(entry.path);
      _dirty.remove(entry.path);
    }
  }

  /// This round's cloud moves, top items only, shallowest target first.
  Map<String, String> _pairCloudMoves(
    Map<String, RemoteItem> remote,
    Set<String> settled,
  ) {
    final vanished = [
      for (final entry in manifest.entries.values)
        if (entry.etag != null &&
            entry.conflict == null &&
            entry.kind != ItemKind.unsupported &&
            !remote.containsKey(entry.path) &&
            !settled.contains(entry.path) &&
            !_cloudHolds(entry.path))
          entry.path,
    ];
    if (vanished.isEmpty) return const {};
    vanished.sort((a, b) => a.length.compareTo(b.length));
    final listed = _listedFileIds(remote);
    final pairs = <String, String>{};
    for (final from in vanished) {
      final entry = manifest.entries[from]!;
      final id = entry.fileId;
      final to = id == null ? null : listed[id];
      if (to != null &&
          !_cloudHolds(to) &&
          remote[to]!.kind == entry.kind &&
          manifest.identities.pathOfFileId(id!) == from) {
        pairs[from] = to;
      }
    }
    // Rows without a file ID (or listed without one): case- or
    // normalization-only renames of the same version (SC-054).
    final taken = pairs.values.toSet();
    final appeared = [
      for (final item in remote.values)
        if (manifest.entries[item.path]?.etag == null &&
            !taken.contains(item.path) &&
            !_cloudHolds(item.path))
          item.path,
    ];
    for (final MapEntry(key: from, value: to) in pairRenames(
      vanished.where((v) {
        if (pairs.containsKey(v)) return false;
        final id = manifest.entries[v]!.fileId;
        return id == null || !listed.containsKey(id);
      }),
      appeared,
    ).entries) {
      final entry = manifest.entries[from]!;
      final item = remote[to]!;
      final sameItem = entry.fileId != null && item.fileId != null
          ? entry.fileId == item.fileId
          : entry.etag == item.etag;
      if (sameItem && item.kind == entry.kind) pairs[from] = to;
    }
    // Documents, Music and Videos never move here, and nothing takes their
    // names (spec #34 P7): never paired, so what is inside them pairs on
    // its own and follows the cloud.
    pairs.removeWhere((from, to) => isTopFolder(from) || isTopFolder(to));
    final tops = <String, String>{};
    for (final from in vanished) {
      final to = pairs[from];
      if (to == null) continue;
      // Beneath a moved top: carried along by its rename, or (moved
      // elsewhere) paired again under the top's new path next round.
      var covered = false;
      for (
        var at = p.posix.dirname(from);
        at != '.';
        at = p.posix.dirname(at)
      ) {
        if (tops.containsKey(at)) {
          covered = true;
          break;
        }
      }
      if (!covered) tops[from] = to;
    }
    int depth(String path) => '/'.allMatches(path).length;
    final ordered = tops.keys.toList()
      ..sort((a, b) {
        final byTarget = depth(tops[a]!).compareTo(depth(tops[b]!));
        return byTarget != 0 ? byTarget : a.length.compareTo(b.length);
      });
    return {for (final from in ordered) from: tops[from]!};
  }

  /// Applies one cloud move of the row at [from] to the listed [to]. True
  /// when the rows moved; false when the pair is held for a later pass
  /// ([_cloudHeld]) or left to the ordinary rules.
  bool _applyCloudMove(
    String from,
    String to,
    Map<String, LocalItem> local,
    Map<String, LocalItem> rawLocal,
    Map<String, RemoteItem> remote,
  ) {
    final entry = manifest.entries[from]!;
    final renamedHere = _renamedBothSides[from] ?? _parked[from];
    // Where the item is on disk: its row's path, or where a rename here
    // took it.
    final at = renamedHere ?? from;
    bool hold([String? status]) {
      _cloudHeld.addAll({from, to, at});
      if (status != null && entry.conflict == null) entry.status = status;
      _dirty.add(from);
      return false;
    }

    // The item, or something beneath it, is open in another program: a scan
    // leaves a busy file out, so the pair cannot be judged now. Left to the
    // ordinary rules it would be downloaded again under the new name and
    // its old row taken for a remote deletion. Held for the pass; once the
    // file can be read the move is followed, with any edit made meanwhile.
    if (tree.busy.any((path) => withinOrAt(at, path))) return hold();
    if (_held(from) ||
        _held(to) ||
        // The cloud renaming Documents, Music or Videos (even in case only)
        // never renames them here, and nothing takes their names (spec #34
        // P7): the ordinary rules keep them. What is inside them follows
        // the cloud like any other item, into another top folder too.
        isTopFolder(from) ||
        isTopFolder(to) ||
        isSyncExcluded(to) ||
        // Into or out of an incoming share, in Shared/ or placed in a top
        // folder (spec #33, out of scope): the cloud gives the item a new
        // file ID, so this is never reached by file ID; same-version
        // pairing never crosses either.
        _shareFolderOf(from) != _shareFolderOf(to) ||
        !_cloudMovable(from, at, local)) {
      return false;
    }
    // A removal this partial pass holds: the other side of a local rename
    // may still be on its way. Planned again next pass.
    if (_deferred.any((v) => withinOrAt(from, v))) return hold();
    final here = local[at] ?? (renamedHere != null ? rawLocal[at] : null);
    // Deleted here, its delete not sent yet: no local item moves, so no name
    // here can clash. The rows and the delete follow the cloud's item to its
    // new path (a local delete follows a cloud rename, #142). A different
    // local file at that name is not the deleted item: the delete leaves it
    // in place, and it then uploads as its own new item (#80 review L1).
    final unsent = operation(from, 'delete');
    if (here == null &&
        unsent?.data['dispatchState'] == 'not-started' &&
        (!rawLocal.containsKey(to) ||
            (entry.kind == ItemKind.file &&
                rawLocal[to]!.kind == ItemKind.file &&
                // Not the item itself, already there (a crash between a
                // cloud move's rename and its rows): that is adopted. A file
                // the user hard-linked records no identity, so its bytes
                // decide (#80 delta review L1).
                rawLocal[to]!.identity != entry.localIdentity &&
                (entry.baselineHash == null ||
                    rawLocal[to]!.hash != entry.baselineHash)))) {
      final otherHere = rawLocal.containsKey(to);
      _moveCloudRows(from, to, local);
      if (otherHere) {
        operation(to, 'delete')?.data['otherItemHere'] = true;
        manifest.save();
      }
      return true;
    }
    // Another local item still holds the new name: the clash partner whose
    // removal frees it (spec #49 AC7), applied later in this pass, or an
    // item of this device not synchronized yet. The item keeps its place
    // until the name is free; paired again every pass.
    if (rawLocal.containsKey(to) && !withinOrAt(at, to)) {
      return hold(here != null ? renamePendingStatus : null);
    }
    if (here == null) {
      // Not removal-inferred yet (expected here, no delete): next pass. An
      // item restored with its top folder (spec #34 P7) is never a removal:
      // its rows follow the cloud and it comes back at the new path.
      if (entry.expectedPresent &&
          operation(from, 'delete') == null &&
          !restoredWithTopFolder(from, local)) {
        return hold();
      }
      // Cloud-only, deleted here, or being restored: only the rows move (no
      // disk work), and a removal never sent follows the item to its new
      // path.
      _moveCloudRows(from, to, local);
      return true;
    }
    // Defence in depth: the scan has already turned a changed kind into a
    // type conflict and rewritten a differing identity onto the row, and
    // renameExclusive refuses an item that is no longer [here]; these
    // guard rows a scan did not visit (a partial pass) and a scan without
    // identities, leaving them to the ordinary rules.
    if (here.kind != entry.kind ||
        here.identity == null ||
        (entry.localIdentity != null &&
            renamedHere == null &&
            entry.localIdentity != here.identity)) {
      return false;
    }
    // Still the item this pass saw: same identity, kind and stamp.
    // renameExclusive checks the identity only; this also catches a file
    // written between the scan and now (same inode, new stamp), whose edit
    // must be hashed by a scan before the row moves (tested).
    LocalItem? now;
    try {
      now = tree.statItem(at);
    } on FileSystemException {
      now = null;
    }
    if (now == null ||
        now.kind != here.kind ||
        now.identity != here.identity ||
        (here.kind == ItemKind.file && now.scanStamp != here.scanStamp)) {
      _localWork = true;
      return hold('rename pending: the item changed during the check');
    }
    final parent = p.posix.dirname(to);
    // The highest folder created for the move, if any.
    String? created;
    if (parent != '.' && rawLocal[parent]?.kind != ItemKind.directory) {
      // Into a cloud folder this device does not have yet: created first,
      // as a download would create it.
      if (rawLocal.containsKey(parent) ||
          remote[parent]?.kind != ItemKind.directory ||
          _cloudHolds(parent)) {
        _localWork = true;
        return hold('rename pending: waiting for its folder');
      }
      try {
        tree.ensureDirectory(parent);
      } on FileSystemException catch (error) {
        return hold('rename pending: $error');
      }
      for (var dir = parent; dir != '.'; dir = p.posix.dirname(dir)) {
        if (rawLocal.containsKey(dir)) break;
        final made = tree.statItem(dir);
        if (made == null) break;
        rawLocal[dir] = made;
        local[dir] = made;
        _dirty.add(dir);
        created = dir;
      }
    }
    if (!_cloudMovesDurable) {
      // One commit point for every local rename of the pass (decisions
      // #136, #137), taken after the rows planned so far are written.
      manifest.save();
      try {
        manifest.commitPoint();
      } on FileSystemException catch (error) {
        return hold('rename pending: $error');
      }
      _cloudMovesDurable = true;
    }
    try {
      tree.native.checkRoot(tree.fd, tree.root.path);
      _renameUnderCommitPoint(at, to, here.identity!);
    } on FileSystemException catch (error) {
      return hold('rename pending: $error');
    }
    for (final view in [local, rawLocal]) {
      for (final path in view.keys.where((v) => withinOrAt(at, v)).toList()) {
        final old = view.remove(path)!;
        final moved = renamedPath(at, to, path);
        view[moved] = old.movedTo(moved);
      }
    }
    if (_watching && _view != null) {
      _drop(at);
      watcher!.retainUnder(at, const {});
      // The view (and the watches) follow, with any folder made for it.
      _rescan(const {}, {created ?? to});
    }
    _touched.addAll({at, to});
    if (renamedHere != null) {
      // The new local name's rows (never synchronized) go with the item.
      for (final row
          in manifest.entries.values
              .where((e) => withinOrAt(at, e.path) && e.etag == null)
              .toList()) {
        manifest.entries.remove(row.path);
        uploads.forget(row.path);
        _dirty.remove(row.path);
      }
      _parked.remove(from);
    }
    _moveCloudRows(from, to, local);
    if (renamedHere != null) {
      final name = p.posix.dirname(from) == parent ? p.posix.basename(to) : to;
      manifest.entries[to]?.movedNote = 'Renamed on another device to $name';
      manifest.save();
    }
    return true;
  }

  /// Nothing beneath [from] is in conflict, and its work in flight can move
  /// with it: removals never sent, and uploads of a file still the local
  /// identity its row records (at [at], where the item is on disk). Any
  /// other work leaves the pair to the ordinary rules.
  bool _cloudMovable(String from, String at, Map<String, LocalItem> local) {
    if (manifest.entries.values.any(
      (e) => withinOrAt(from, e.path) && e.conflict != null,
    )) {
      return false;
    }
    for (final op in manifest.operations.values) {
      if (!withinOrAt(from, op.path) ||
          _passiveOperations.contains(op.kind) ||
          _unsentDelete(op)) {
        continue;
      }
      if (op.kind == 'upload') {
        // Planner ruling: only while the file is still the identity its
        // row records. The scan keeps the two equal at the row's own path,
        // so this guards the item found at another path (renamed here too).
        final recorded = manifest.entries[op.path]?.localIdentity;
        final here = local[renamedPath(from, at, op.path)];
        if (recorded != null &&
            here != null &&
            here.kind == ItemKind.file &&
            here.identity == recorded) {
          continue;
        }
      }
      return false;
    }
    return true;
  }

  /// The guarded rename of a cloud move, covered by the pass's commit point
  /// rather than one of its own: a crash after it, before its rows are
  /// durable, leaves the item at its new name with its row at the old one,
  /// which the next pass pairs by identity and finds already moved in the
  /// cloud (spec #33 I1), so it never reads as a local delete.
  void _renameUnderCommitPoint(String from, String to, String identity) {
    final guard = tree.native.beforeDestructiveChange;
    tree.native.beforeDestructiveChange = null;
    try {
      tree.native.renameExclusive(tree.fd, from, to, identity);
    } finally {
      tree.native.beforeDestructiveChange = guard;
    }
  }

  /// Moves the rows of [from] and beneath it to [to] for a cloud move, with
  /// the work [_cloudMovable] lets follow them: a removal never sent (a
  /// delete here follows the item), and a pending upload, sent at the new
  /// path with If-Match on the version its edit started from, so a cloud
  /// edit meanwhile is the ordinary edit/edit conflict.
  void _moveCloudRows(String from, String to, Map<String, LocalItem> local) {
    for (final op
        in manifest.operations.values
            .where(
              (o) =>
                  withinOrAt(from, o.path) &&
                  (_unsentDelete(o) || o.kind == 'upload'),
            )
            .toList()) {
      final path = renamedPath(from, to, op.path);
      manifest.operations.remove(op.id);
      final data = Map<String, dynamic>.of(op.data);
      final excluded = (data['excludedSubtreeVersions'] as Map?)
          ?.cast<String, String>();
      if (excluded != null) {
        data['excludedSubtreeVersions'] = {
          for (final e in excluded.entries)
            renamedPath(op.path, path, e.key): e.value,
        };
      }
      final moved = Operation(
        uniqueId(),
        op.kind,
        path,
        expectedEtag: op.expectedEtag,
        phase: op.phase,
        staged: op.staged,
        hash: op.hash,
      )..data = data;
      manifest.operations[moved.id] = moved;
      // A deletion held for its top folder's settle (#91) keeps its clock:
      // one hold, not a new one at the new path.
      if (_deleteHeldSince.remove(op.id) case final since?) {
        _deleteHeldSince[moved.id] = since;
      }
      // The upload's staged snapshot belongs to the row at its new path.
      final staged = op.staged;
      if (staged != null) {
        for (final record in artifacts.records.where(
          (r) => r.staged == staged,
        )) {
          record.data['entryPath'] = path;
        }
      }
    }
    _rekey(from, to, local);
    for (final row in manifest.entries.values) {
      if (!withinOrAt(to, row.path)) continue;
      row.movedNote = null;
      // Held at its old path for this move: planned afresh at the new one.
      if (isLegacyNameHold(row.status) ||
          row.status.startsWith('rename pending')) {
        row.status = 'queued';
      }
      _dirty.add(row.path);
    }
    manifest.save();
  }

  /// Moves the rows of [from] and everything beneath it to [to] (SC-054).
  /// Each keeps its versions and baselines; the local index of an item
  /// already scanned under the new spelling is kept from that scan. A row
  /// expected here but missing under the new spelling is a local removal.
  void _rekey(String from, String to, Map<String, LocalItem> local) {
    final rows = <Entry>[];
    for (final old
        in manifest.entries.values
            .where((e) => withinOrAt(from, e.path))
            .toList()) {
      final path = renamedPath(from, to, old.path);
      final scanned = manifest.entries[path];
      final moved = Entry.fromJson({...old.toJson(), 'path': path});
      // A new local name is the new cloud name (spec #49 Reverse direction);
      // a move that keeps the name keeps the cloud name.
      if (old.path == from && p.posix.basename(from) != p.posix.basename(to)) {
        moved.cloudName = null;
      }
      if (scanned != null) {
        moved
          ..localHash = scanned.localHash
          ..size = scanned.size
          ..localModified = scanned.localModified
          ..setIndex(
            scanned.localStamp,
            scanned.stampHash,
            scanned.stampedAt,
            scanned.stampFinal,
          );
      }
      if (moved.status == 'rename queued' ||
          isMovedHereStatus(moved.status) ||
          moved.status.startsWith('rename pending')) {
        moved.status = 'queued';
      }
      manifest.entries.remove(old.path);
      manifest.entries[path] = moved;
      uploads
        ..forget(old.path)
        ..forget(path);
      _dirty
        ..remove(old.path)
        ..add(path);
      rows.add(moved);
    }
    // A child renamed together with its folder (Photos/Top.txt ->
    // photos/top.txt) is paired under the new folder, so it moves too.
    _planLocalMoves(local, under: to);
    final moving = [for (final op in _moves) op.path];
    for (final row in rows) {
      if (identical(manifest.entries[row.path], row) &&
          row.expectedPresent &&
          row.conflict == null &&
          !local.containsKey(row.path) &&
          !moving.any((root) => withinOrAt(root, row.path))) {
        _inferRemoval(row, local);
      }
    }
    // Every row of the moved subtree in one commit (spec #33 I1 step 4).
    // Made durable by the pass's commit points; a loss before then re-plans
    // the move, and the listing shows it already done (adopted, not sent).
    manifest.save();
  }

  /// Listed cloud items this device cannot hold under any name (spec #49
  /// R3: no ` (n)` fits its local limit), by local path, with what is
  /// beneath them: never created here, shown with the residual row.
  final Set<String> _unplaceable = {};

  /// The listing with each path in the local spelling of its item (spec #49
  /// Sync Boundary, decision #199). Each segment first takes this device's
  /// name for it (R3, once per listed folder: no sibling is listed per
  /// item). Cloud names are NFC (decision #138); a local name that differs
  /// only by normalization (an NFD name from macOS, say) is the same item,
  /// so a segment then takes the local spelling. Where several local
  /// spellings share one cloud name, the synchronized item (a row with a
  /// version) wins, then the exact spelling on disk, then any other; the
  /// rest stay distinct items. The differences are recorded in [names].
  Map<String, RemoteItem> _localSpelling(
    Map<String, RemoteItem> listed,
    Map<String, LocalItem> rawLocal,
  ) {
    _unplaceable.clear();
    final os = nameOs;
    final perDevice = os == NameOs.windows || os == NameOs.macos;
    bool respelled(String path) => NamePolicy.nfc(path) != path;
    final normalizing =
        rawLocal.keys.any(respelled) || manifest.entries.keys.any(respelled);
    if (!perDevice && !normalizing) {
      names.listed(const {}, const {});
      return listed;
    }
    // Cloud folder -> {cloud name: local name} where any differs (R3).
    final local = <String, Map<String, String?>>{};
    if (perDevice) {
      final folders = <String, List<NameEntry>>{};
      for (final item in listed.values) {
        folders
            .putIfAbsent(p.posix.dirname(item.path), () => [])
            .add(
              NameEntry(
                p.posix.basename(item.path),
                fileId: item.fileId,
                folder: item.kind == ItemKind.directory,
              ),
            );
      }
      for (final MapEntry(key: folder, value: items) in folders.entries) {
        final names = NameRule.localNames(items, os);
        if (names.entries.any((v) => v.key != v.value)) local[folder] = names;
      }
    }
    // Local parent spelling -> cloud name of a child -> its local spellings.
    final children = <String, Map<String, Set<String>>>{};
    void index(String path) {
      final name = p.posix.basename(path);
      children
          .putIfAbsent(p.posix.dirname(path), () => {})
          .putIfAbsent(NamePolicy.nfc(name), () => {})
          .add(name);
    }

    if (normalizing) {
      rawLocal.keys.forEach(index);
      manifest.entries.keys.forEach(index);
    }
    String child(String parent, String name) =>
        parent == '.' ? name : '$parent/$name';
    String component(String parent, String name) {
      final spellings = children[parent]?[name];
      if (spellings == null) return name;
      final synced = spellings
          .where((v) => manifest.entries[child(parent, v)]?.etag != null)
          .toList();
      if (synced.isNotEmpty) {
        return synced.contains(name) ? name : synced.first;
      }
      if (rawLocal.containsKey(child(parent, name))) return name;
      return spellings.firstWhere((v) => v != name, orElse: () => name);
    }

    final resolved = <String, String>{'.': '.'};
    String spelled(String path) {
      final known = resolved[path];
      if (known != null) return known;
      final folder = p.posix.dirname(path);
      final parent = spelled(folder);
      final cloudName = p.posix.basename(path);
      final names = local[folder];
      var name = names == null || !names.containsKey(cloudName)
          ? cloudName
          : names[cloudName];
      if (name == null || _unplaceable.contains(parent)) {
        name = cloudName;
        _unplaceable.add(child(parent, name));
      }
      return resolved[path] = child(parent, component(parent, name));
    }

    final cloudNames = <String, String>{};
    final localPaths = <String, String>{};
    final result = <String, RemoteItem>{};
    for (final item in listed.values) {
      final path = spelled(item.path);
      if (path != item.path) {
        localPaths[item.path] = path;
        final name = p.posix.basename(item.path);
        if (p.posix.basename(path) != name) cloudNames[path] = name;
      }
      result[path] = path == item.path ? item : _respelled(item, path);
    }
    names.listed(cloudNames, localPaths);
    // Every listed row keeps the cloud name it has now, so a restart maps
    // it before its first listing; written only when it changes.
    for (final MapEntry(key: path, value: item) in result.entries) {
      final entry = manifest.entries[path];
      if (entry != null && entry.kind == item.kind) {
        entry.cloudName = cloudNames[path];
      }
    }
    return result;
  }

  static RemoteItem _respelled(RemoteItem item, String path) => RemoteItem(
    path,
    item.kind,
    item.etag,
    size: item.size,
    fileId: item.fileId,
    modified: item.modified,
    permissions: item.permissions,
    shared: item.shared,
  );

  /// A result that still needs work (failed, waiting, queued) is revisited.
  static bool _unsettled(Entry entry) =>
      entry.status == 'queued' ||
      entry.status.toLowerCase().contains('pending') ||
      // A row an earlier client held for its name (decision #120): resolved
      // through the name rule on the first pass (spec #49 AC8).
      isLegacyNameHold(entry.status);

  Future<int> _tick(
    bool audit,
    Future<bool> Function()? between,
    RemotePolicy remotePolicy,
  ) async {
    _mountChanges.clear();
    _heldTargets.clear();
    Map<String, LocalItem> rawLocal;
    String? folderWarning;
    try {
      folderWarning = folders.recover();
      final scanning = Stopwatch()..start();
      try {
        rawLocal = await _localSnapshot();
      } catch (_) {
        lastPassReadWholeRoot = false;
        rethrow;
      } finally {
        final measured = scanning.elapsed;
        lastLocalScan = debugLocalScanDuration?.call(measured) ?? measured;
      }
      // Before anything reads the scan: a top folder that is gone or
      // replaced is back before a missing item could read as a deletion.
      _migrateLegacyIdentities();
      _keepTopFolders(rawLocal);
      _keepSharedFolder(rawLocal);
      _cleanUpNames(rawLocal);
      _recordMountIdentities();
      _lookUpVanished(rawLocal);
      localUnavailable = false;
      localIdentities
        ..clear()
        ..addEntries(
          rawLocal.values.map((item) => MapEntry(item.path, item.identity)),
        );
      localDirectories
        ..clear()
        ..addAll(
          rawLocal.values
              .where((item) => item.kind == ItemKind.directory)
              .map((item) => item.path),
        );
    } catch (error) {
      localUnavailable = true;
      localDirectories.clear();
      localIdentities.clear();
      message = error is TopFolderBlocked
          ? '${error.message} Synchronization is paused until then; no deletions are inferred.'
          : 'Paused: local storage unavailable or folder creation pending: $error. No deletions inferred.';
      return 0;
    }
    // Legacy Cloud roots must acquire a complete policy snapshot before any
    // recovery or reconciliation can change bytes. Never turn an offline upgrade
    // into a root-wide download or silently discard its former Cloud intent.
    Map<String, RemoteItem>? migrationRemote;
    if (manifest.setting('retention') == 'cloud') {
      if (remotePolicy == RemotePolicy.never) return 0;
      try {
        final neverPaired =
            cloud is DisconnectedCloud &&
            [
              'server',
              'accountUid',
              'accountOrigin',
              'certificate',
            ].every((key) => manifest.setting(key) == null) &&
            manifest.entries.values.every((entry) => entry.etag == null) &&
            manifest.operations.isEmpty;
        migrationRemote = neverPaired
            ? {}
            : {for (final item in await cloud.snapshot()) item.path: item};
        if (!rootAvailable()) return 0;
        _migrateCloudRoot(rawLocal, migrationRemote);
        if (neverPaired) migrationRemote = null;
      } catch (error) {
        message =
            'Storage upgrade pending: connect to finish preserving existing Cloud-only choices. Synchronization is paused: $error';
        return 0;
      }
    }
    editing.recover();
    evictions.recover(
      rawLocal,
      cloudWanted: (path) =>
          !isSyncExcluded(path) && retention(path) == Retention.cloud,
    );
    exclusions.adopt();
    // A Recover or Dismiss a crash interrupted (spec #25); local only.
    recovery.recoverInterrupted();
    final pendingFolders = folders.pendingPaths;
    bool pendingFolder(String path) => pendingFolders.any(
      (folder) => folder == path || p.posix.isWithin(folder, path),
    );
    var local = Map<String, LocalItem>.fromEntries(
      rawLocal.entries.where(
        (v) =>
            !isSyncExcluded(v.key) &&
            !pendingFolder(v.key) &&
            !_temporary(v.value),
      ),
    );
    // Candidate detection: any local path whose type, identity, stamp or
    // content differs from the previous pass, or that appeared/disappeared.
    final seenLocal = {
      for (final item in local.values) item.path: _localSignature(item),
    };
    for (final item in seenLocal.entries) {
      if (_seenLocal[item.key] != item.value) {
        _dirty.add(item.key);
        _localWork = true;
      }
    }
    if (_seenLocal.keys.any((v) => !seenLocal.containsKey(v))) {
      _localWork = true;
    }
    _dirty.addAll(_seenLocal.keys.where((v) => !seenLocal.containsKey(v)));
    _seenLocal
      ..clear()
      ..addAll(seenLocal);
    // Replay preservation before classifying missing paths. Every retained file
    // remains outside the root and is never automatically discarded.
    for (final op
        in manifest.operations.values
            .where((o) => o.kind == 'preserve')
            .toList()) {
      final entry = manifest.entries[op.path];
      if (op.staged != null &&
          artifacts.resolve(op.staged!).existsSync() &&
          !local.containsKey(op.path)) {
        if (entry != null) {
          entry.expectedPresent = false;
          if (!entry.preservedCopies.contains(op.staged)) {
            entry.preservedCopies.add(op.staged!);
          }
        }
        final retained = Operation(
          uniqueId(),
          'retained',
          op.path,
          expectedEtag: op.expectedEtag,
          staged: op.staged,
          hash: op.hash,
        )..data = Map<String, dynamic>.from(op.data);
        manifest.operations[retained.id] = retained;
        adoptInterruptedPreserve(op.staged!);
        finish(op);
      }
    }
    for (final retained
        in manifest.operations.values
            .where((o) => o.kind == 'retained')
            .toList()) {
      final entry = manifest.entries[retained.path];
      if (entry == null ||
          entry.conflict != null ||
          retained.staged == null ||
          retained.hash == null) {
        continue;
      }
      // A kept upload snapshot can be large: re-read it only if its staged
      // file changed since it was written (SC-028).
      if (retained.data['unsyncedRemoval'] == true &&
          _stagedIntact(retained.staged!, retained.hash!)) {
        continue;
      }
      final file = artifacts.resolve(retained.staged!);
      if (file.existsSync() &&
          await fileHash(file, 'retained-check') != retained.hash) {
        final status = entry.status;
        conflict(entry, preservedChangedConflict);
        // A completed deletion stays completed; its copy is a recovery copy
        // whose differing bytes remain recoverable through the conflict.
        if (const {
          'deleted',
          'deleted remotely',
          'removed locally',
        }.contains(status)) {
          entry.status = status;
          manifest.save();
        }
      }
    }
    for (final item in local.values) {
      final entry = manifest.entries.putIfAbsent(
        item.path,
        () => Entry(item.path, item.kind),
      );
      if (entry.kind != item.kind) {
        conflict(entry, 'Local item type changed; review both versions.');
        continue;
      }
      entry.localHash = item.hash;
      entry.size = item.size;
      // Only a synchronized row is anyone's identity (IdentityIndex): the
      // new row at a renamed item's new path stays without one until the
      // move or its upload has made it so.
      if (entry.etag != null && entry.localIdentity != item.identity) {
        entry.localIdentity = _recordedIdentity(item);
      }
      // A folder's birth time with it: the same number with another birth
      // is another folder (flag SC-074). Only for the folders whose identity
      // is checked that way ([_sameFolder]).
      if (entry.etag != null && _birthTracked(item)) {
        entry.localBirth = item.birth;
      }
      if (item.kind == ItemKind.file) {
        entry.localModified =
            modifiedSeconds(item.scanStamp) ?? entry.localModified;
        entry.setIndex(
          item.stamp,
          item.stamp == null ? null : item.hash,
          item.stampedAt,
          item.stampFinal,
        );
      }
      if (item.kind == ItemKind.unsupported) {
        entry.status = 'unsupported';
        continue;
      }
      if (entry.conflict == null &&
          item.kind == ItemKind.file &&
          item.hash != entry.baselineHash) {
        // A held upload keeps its reason (amber), not "queued" (#27 rule).
        entry.status =
            uploads.status(item.path, _localSignature(item)) ??
            _residualStatus(entry) ??
            'queued';
      }
    }
    _holdUnavailable();
    // A new file that is busy has a row too (SC-048 F5): never synchronized,
    // not expected present, so nothing is inferred from it.
    for (final path in tree.busy) {
      if (!isSyncExcluded(path) &&
          !NameRule.isTemporary(p.posix.basename(path))) {
        manifest.entries.putIfAbsent(path, () => Entry(path, ItemKind.file));
      }
    }
    for (final entry in manifest.entries.values) {
      if (entry.conflict != null) continue;
      if (tree.busy.contains(entry.path)) {
        entry.status = fileBusyStatus;
      } else if (entry.status == fileBusyStatus) {
        // Released: read below as usual; a never-synchronized file that is
        // gone meanwhile leaves no row.
        entry.status = entry.etag == null && !local.containsKey(entry.path)
            ? 'removed locally'
            : 'current local';
      }
    }
    _planLocalMoves(local, raw: rawLocal);
    final movingFrom = [for (final op in _moves) op.path];
    final w = watcher;
    if (_localScan != 'partial') {
      _missingSince.clear();
    } else {
      // A hold ends when its path is back or no longer expected, and also
      // when it became a move or a park: those rows skip the deferral below,
      // so a stale hold would keep the next pass due at once (#78 review).
      _missingSince.removeWhere(
        (path, _) =>
            local.containsKey(path) ||
            !(manifest.entries[path]?.expectedPresent ?? false) ||
            movingFrom.any((from) => withinOrAt(from, path)) ||
            _parkedOrWaiting(path),
      );
    }
    _lossNoted.removeWhere(local.containsKey);
    for (final entry in manifest.entries.values) {
      if (entry.expectedPresent &&
          !local.containsKey(entry.path) &&
          entry.conflict == null &&
          !movingFrom.any((from) => withinOrAt(from, entry.path)) &&
          !_parkedOrWaiting(entry.path)) {
        // A partial pass can see a rename's old side before its new side
        // has reached the view; the removal is held for a while, so the pair
        // is planned as a move on a later pass (decision #140, SC-058). An
        // item restored with its top folder (#150) is never a move or a
        // deletion, so its restore is not held.
        if (!restoredWithTopFolder(entry.path, local) &&
            (_deferRemoval(entry.path, w) || _auditUncertain(entry.path, w))) {
          // Not reconciled this pass (no restore, no deletion); revisited
          // on the next.
          _deferred.add(entry.path);
          _dirty.add(entry.path);
          continue;
        }
        _inferRemoval(entry, local);
      }
    }
    // A row whose local item is gone for good (released to Cloud-only,
    // deleted, removed) is nobody's local identity any more, so a later
    // item on a reused inode never meets a stale claim (#78 review). A
    // removal still unsent keeps it: a stalled rename can still pair.
    for (final entry in manifest.entries.values) {
      if (entry.localIdentity != null &&
          !entry.expectedPresent &&
          !local.containsKey(entry.path) &&
          operation(entry.path, 'delete')?.data['dispatchState'] !=
              'not-started') {
        entry.localIdentity = null;
      }
    }
    manifest.save();
    // Local state is recorded. Without a due listing or new local work the
    // pass ends here: no network request and no root mutation follow.
    if (migrationRemote == null &&
        (remotePolicy == RemotePolicy.never ||
            (remotePolicy == RemotePolicy.ifLocalWork && !_localWork))) {
      return 0;
    }
    Map<String, RemoteItem> rawRemote;
    // Before the listing: a disabled owner's folder vanishes from it.
    final incomingRead = migrationRemote != null || await _refreshIncoming();
    try {
      rawRemote =
          migrationRemote ??
          {for (final item in await cloud.snapshot()) item.path: item};
      rawRemote = _localSpelling(rawRemote, rawLocal);
      remoteListed = true;
      lastListedAt = _clock.elapsed;
      _localWork = false;
    } catch (error) {
      remoteFailed = true;
      message =
          'Offline: $error${folderWarning == null ? '' : '. $folderWarning'}';
      return 0;
    }
    if (!rootAvailable()) {
      return 0;
    }
    // Complete observed metadata is retained only for freezing future directory
    // delete intent. A queued intent is never refreshed from this new snapshot.
    manifest.setSetting(
      'excludedRemoteVersionsV1',
      jsonEncode({
        for (final item in rawRemote.values.where(
          (v) => isSyncExcluded(v.path),
        ))
          item.path: item.etag,
      }),
    );
    await exclusions.observe(rawRemote);
    final remote = Map<String, RemoteItem>.fromEntries(
      rawRemote.entries.where(
        (v) => !isSyncExcluded(v.key) && !pendingFolder(v.key),
      ),
    );
    // Permissions and share state first: delete and editing intents below
    // already need them, and a permission change alone changes no version.
    for (final item in remote.values) {
      manifest.entries[item.path]
        ?..permissions = item.permissions
        ..sharedOut = item.shared;
    }
    _listedMounts = {
      for (final item in remote.values)
        if (isMountPlace(item.path) && item.permissions != null)
          item.path: item.permissions!,
    };
    _holdUnavailable();
    if (!incomingRead) {
      // Unknown whether a vanished incoming folder was unshared or its owner
      // disabled: pause it rather than infer deletions.
      for (final entry in manifest.entries.values) {
        if (isIncomingMountPath(entry.path) &&
            entry.etag != null &&
            !remote.containsKey(entry.path)) {
          _heldMounts.add(entry.path);
        }
      }
    }
    for (final mount in _heldMounts) {
      final entry = manifest.entries[mount];
      if (entry != null && entry.conflict == null) {
        entry.status = ownerUnavailableStatus;
        _dirty.add(mount);
      }
    }
    if (incomingRead && migrationRemote == null) {
      await _renameRemovedMounts(local, rawLocal, remote, rawRemote);
      await _leaveRemovedMounts(local, remote, rawRemote);
    }
    // Whether or not this pass could read the incoming list (review D-H1).
    if (migrationRemote == null) {
      _setAsideUnsyncedAtMounts(local, rawLocal, remote);
    }
    final seenRemote = {
      for (final item in remote.values)
        item.path:
            '${item.kind.name}|${item.etag}|${item.permissions}|${item.shared}',
    };
    for (final item in seenRemote.entries) {
      if (_seenRemote[item.key] != item.value) {
        _dirty.add(item.key);
        _metadataDue = true;
      }
    }
    final vanished = _seenRemote.keys
        .where((v) => !seenRemote.containsKey(v))
        .toList();
    if (vanished.isNotEmpty) _metadataDue = true;
    _dirty.addAll(vanished);
    _seenRemote
      ..clear()
      ..addAll(seenRemote);
    // A lost acknowledgement is reconciled against the immutable upload hash,
    // before a later local edit can reuse its old conditional baseline.
    for (final op
        in manifest.operations.values
            .where((o) => o.kind == 'upload')
            .toList()) {
      final entry = manifest.entries[op.path];
      final current = remote[op.path];
      if (entry == null ||
          entry.conflict != null ||
          current == null ||
          current.kind != ItemKind.file ||
          op.hash == null ||
          current.etag == op.expectedEtag) {
        continue;
      }
      try {
        final proof = await remoteCopy(current, 'upload-recovery');
        if (await fileHash(proof, 'upload-recovery') == op.hash) {
          entry.etag = current.etag;
          entry.baselineHash = op.hash;
          entry.recordRemoteVersion(current.etag, op.hash!);
          entry.expectedPresent = local.containsKey(op.path);
          confirmArtifacts(op.path, op.hash!, current.etag);
          finish(op);
        } else {
          entry.remoteCopy = tree.durablePath(proof);
          conflict(
            entry,
            'Cloud content differs from the interrupted upload. Both versions are retained.',
          );
        }
      } on TransfersHeld {
        // The recovery download waits for Wi-Fi like any other (#108 Q4).
        _waitForNetwork(entry);
      } catch (error) {
        entry.status = 'Upload acknowledgement recovery pending: $error';
      }
    }
    // Each externally opened working file keeps its own baseline. Older open
    // editor sessions never become new uploads merely because the root changed.
    for (final work
        in manifest.operations.values
            .where((o) => o.kind == 'working')
            .toList()) {
      final entry = manifest.entries[work.path];
      if (entry == null ||
          entry.conflict != null ||
          work.staged == null ||
          _held(work.path)) {
        continue;
      }
      work.data.remove('presentationError');
      final file = artifacts.resolve(work.staged!);
      if (!file.existsSync()) {
        entry.status = 'Working copy missing; root/cloud retained';
        work.data['presentationError'] = entry.status;
        continue;
      }
      String hash;
      try {
        tree.native.checkRoot(tree.stageFd, tree.staging.path);
        hash = tree.native.copyAndHash(
          tree.stageFd,
          p.basename(file.path),
          null,
          purpose: 'working',
        );
      } on FileSystemException catch (error) {
        entry.status = 'Working copy pending: $error';
        work.data['presentationError'] = entry.status;
        continue;
      }
      if (hash != work.hash || artifacts.workingEdited(work)) {
        // Decision #183: from here on the session is an edit (Editing,
        // Finish editing), whatever later re-aligns its stamp or hash.
        if (work.data['edited'] != true) {
          work.data['edited'] = true;
          manifest.save();
        }
      }
      if (hash == work.hash) continue;
      if (viewOnly(work.path)) {
        conflict(entry, viewOnlyConflict);
        continue;
      }
      final current = remote[work.path];
      final here = local[work.path];
      if (operation(work.path, 'delete') != null ||
          current?.etag != work.expectedEtag ||
          (here != null && here.hash != work.hash && here.hash != hash)) {
        conflict(
          entry,
          'Working copy meets another edit or deletion. All copies retained.',
        );
        continue;
      }
      try {
        final upload = artifacts.reserve(work.path, 'working-upload');
        final copied = tree.native.copyAndHash(
          tree.stageFd,
          p.basename(file.path),
          upload,
          purpose: 'working',
        );
        if (copied != hash ||
            tree.native.copyAndHash(
                  tree.stageFd,
                  p.basename(file.path),
                  null,
                  purpose: 'working',
                ) !=
                hash) {
          throw const CloudFailure('Working copy changed during snapshot.');
        }
        final buffer = artifacts.record(upload)!;
        buffer.data['workingId'] = work.id;
        buffer.data['baseEtag'] = work.expectedEtag;
        buffer.data['sessionBinding'] = editing.binding;
        buffer.data['lineageVersion'] = 1;
        artifacts.complete(upload, hash: hash);
        final version = await cloud.upload(
          work.path,
          upload,
          etag: work.expectedEtag,
        );
        final readBack = cloud.lastUploadReadBack;
        if (readBack) buffer.data['versionReadBack'] = true;
        tree.native.checkRoot(tree.fd, tree.root.path);
        artifacts.complete(upload, hash: hash, etag: version);
        editing.acceptUpload(work, buffer, version, hash);
        // Before the install: where installs rename (Android) the staged
        // file is the root file afterwards and its staging name is gone.
        final uploadSize = await upload.length();
        if (here != null && here.hash != hash) {
          preserve(entry);
          installOwned(work.path, upload);
          entry.expectedPresent = true;
        }
        entry.etag = version;
        entry.baselineHash = hash;
        if (!readBack) entry.recordRemoteVersion(version, hash);
        entry.localHash = hash;
        entry.status = 'working copy synchronized';
        work.hash = hash;
        work.expectedEtag = version;
        remote[work.path] = RemoteItem(
          work.path,
          ItemKind.file,
          version,
          size: uploadSize,
        );
        manifest.save();
        if (_watching && _view != null) {
          _rescan({work.path}, const {});
          local = {
            for (final item in _view!.values)
              if (!isSyncExcluded(item.path)) item.path: item,
          };
        } else {
          local = await tree.snapshot();
        }
      } on TransfersHeld {
        _waitForNetwork(entry);
        work.data['presentationError'] = entry.status;
        manifest.save();
      } catch (error) {
        entry.status = 'Working edit pending: $error';
        work.data['presentationError'] = entry.status;
        manifest.save();
      }
    }
    // The cloud renamed Documents, Music or Videos in case only (the web
    // UI, an older client): renamed back there, never followed here.
    try {
      await _respellRemoteTops(rawRemote, remote);
    } catch (error) {
      message = 'Pending: restoring a top folder name in the cloud: $error';
      manifest.save();
      return 0;
    }
    _claimBothSidesRenamed(remote);
    await _reconcileMoves(local, rawLocal, remote);
    final pendingMoves = [
      for (final op in _moves) ...[op.path, _moveTarget(op)],
    ];
    bool moving(String path) =>
        pendingMoves.any((root) => withinOrAt(root, path)) ||
        _parkedOrWaiting(path) ||
        _cloudHolds(path);
    // Files whose inferred delete was withdrawn because they exist again:
    // left for the next pass, which reads them as edits.
    final reappeared = <String>{};
    // Directory creates precede child transfers. Deletes are handled as whole
    // user intents, including descendants, before ordinary file reconciliation.
    _deletesHeld = false;
    final keptForShares = <String>{};
    for (final op
        in manifest.operations.values.where((o) => o.kind == 'delete').toList()
          ..sort((a, b) => a.path.length.compareTo(b.path.length))) {
      if (keptForShares.contains(op.id)) continue;
      if (manifest.operations.values.any(
        (ancestor) =>
            ancestor.kind == 'delete' &&
            p.posix.isWithin(ancestor.path, op.path),
      )) {
        continue;
      }
      if (!rootAvailable()) {
        return 0;
      }
      final entry = manifest.entries[op.path]!;
      final current = remote[op.path];
      if (entry.conflict != null || _held(op.path)) continue;
      // Beneath a folder whose cloud move is held for a later pass (a busy
      // file inside it, a new name this device cannot hold): the cloud has
      // the item under the folder's new path, so nothing is listed here and
      // the delete would read as already done, its row dropped and the item
      // fetched back once the move is followed. It stays queued, unsent, and
      // moves with the folder's rows when the move is followed, to be sent
      // at the new path (SC-105). The held item itself is not covered: its
      // own pairing has already decided what its delete means.
      if (op.path.contains('/') && _cloudHolds(p.posix.dirname(op.path))) {
        _dirty.add(op.path);
        continue;
      }
      // A folder holding someone else's share: deleting it in the cloud
      // could reach into the share, so the deletion waits. A share inside
      // is left only when its own folder alone was removed (spec #34 P6);
      // otherwise it is restored, never deleted.
      if (incoming.keys.any((mount) => p.posix.isWithin(op.path, mount))) {
        // Nothing inside propagates (decision #150): the folder and all
        // it held come back from the cloud.
        for (final inside
            in manifest.operations.values
                .where((o) => o.kind == 'delete' && withinOrAt(op.path, o.path))
                .toList()) {
          manifest.operations.remove(inside.id);
          keptForShares.add(inside.id);
          final row = manifest.entries[inside.path];
          if (row == null) continue;
          row
            ..expectedPresent = true
            ..status = sharedFolderInside;
          _dirty.add(row.path);
        }
        manifest.save();
        continue;
      }
      // Queued before the share became View only: never sent (no 403 loop).
      final restore = current == null ? null : _restoreReason(op.path, local);
      if (restore != null) {
        finish(op);
        entry.expectedPresent = true;
        if (restore == topFolderRestoring && !local.containsKey(op.path)) {
          entry.restoring = true;
        }
        entry.status = restore;
        _dirty.add(op.path);
        continue;
      }
      // The item may be at a new name that another program holds open: it
      // is among the busy files, which a scan leaves out, so its old path
      // looks removed. The removal waits; once the file can be read, the
      // scan pairs the two paths as a move.
      if (op.data['inferred'] == true &&
          entry.localIdentity != null &&
          tree.busyIdentities.containsValue(entry.localIdentity)) {
        _dirty.add(op.path);
        _localWork = true;
        continue;
      }
      if (_holdTopDeletion(op, entry)) continue;
      if (current == null) {
        // Already gone before this client's delete ran: whichever version
        // was deleted is unknown, so preserved copies are retained.
        if (entry.kind == ItemKind.directory) _markUnknownDeletion(op.path);
        acknowledgeDelete(entry, op, local, versionKnown: false);
        continue;
      }
      if (op.data['inferred'] == true &&
          // A different local item at a name the deleted one was moved onto
          // in the cloud is not the file coming back.
          op.data['otherItemHere'] != true &&
          entry.kind == ItemKind.file &&
          (local.containsKey(op.path) || tree.statItem(op.path) != null)) {
        // The file is back under its name (an editor that saves by delete
        // and recreate, as Paint does): an edit of the same file, never a
        // delete and a new upload, so the server keeps its version history.
        // Checked before the etag: a server edit meanwhile is then an
        // ordinary edit/edit conflict that Keep both can resolve, never a
        // delete/edit conflict on a file that is present.
        finish(op);
        entry.expectedPresent = true;
        entry.status = 'current local';
        reappeared.add(op.path);
        _dirty.add(op.path);
        continue;
      }
      if (current.etag != op.expectedEtag) {
        conflict(entry, 'Delete/edit conflict: remote content changed.');
        continue;
      }
      try {
        if (entry.kind == ItemKind.directory) {
          final excludedBaseline = (op.data['excludedSubtreeVersions'] as Map?)
              ?.cast<String, String>();
          final actualExcluded = Map<String, String>.fromEntries(
            rawRemote.entries
                .where(
                  (v) =>
                      p.posix.isWithin(op.path, v.key) && isSyncExcluded(v.key),
                )
                .map((v) => MapEntry(v.key, v.value.etag)),
          );
          if (excludedBaseline == null && actualExcluded.isNotEmpty) {
            entry.status = 'Delete pending: excluded cloud descendants lack a known intent baseline; separate confirmation is required.';
            continue;
          }
          if (excludedBaseline != null &&
              (excludedBaseline.length != actualExcluded.length ||
                  excludedBaseline.entries.any(
                    (v) => actualExcluded[v.key] != v.value,
                  ))) {
            conflict(
              entry,
              'Folder deletion meets new or changed excluded cloud descendants; all cloud versions retained.',
            );
            continue;
          }
          if (!cloud.safeFolderDeletion) {
            entry.status = 'folder delete awaiting server proof';
            continue;
          }
          final descendants = manifest.entries.values.where(
            (e) => e.path == op.path || p.posix.isWithin(op.path, e.path),
          );
          final versions = <String, String>{...?excludedBaseline};
          var safe = true;
          for (final child in descendants) {
            final actual = remote[child.path];
            if (child.conflict != null ||
                (local[child.path]?.hash != null &&
                    local[child.path]!.hash != child.baselineHash) ||
                (actual != null && actual.etag != child.etag)) {
              safe = false;
            }
            if (child.etag != null) versions[child.path] = child.etag!;
          }
          if (rawRemote.keys.any(
            (path) =>
                p.posix.isWithin(op.path, path) &&
                !manifest.entries.containsKey(path) &&
                !(excludedBaseline?.containsKey(path) ?? false),
          )) {
            safe = false;
          }
          if (!safe) {
            conflict(
              entry,
              'Folder contains changed or unsynchronized descendants.',
            );
            continue;
          }
          op.data['dispatchState'] = 'started';
          manifest.save();
          await cloud.deleteFolder(op.path, versions: versions);
          for (final path
              in remote.keys
                  .where(
                    (path) =>
                        path == op.path || p.posix.isWithin(op.path, path),
                  )
                  .toList()) {
            remote.remove(path);
          }
          for (final childOp
              in manifest.operations.values
                  .where(
                    (o) =>
                        o.kind == 'delete' && p.posix.isWithin(op.path, o.path),
                  )
                  .toList()) {
            manifest.operations.remove(childOp.id);
          }
        } else {
          op.data['dispatchState'] = 'started';
          manifest.save();
          barrier?.call('delete-before-dispatch', op);
          await cloud.deleteFile(op.path, etag: op.expectedEtag!);
          remote.remove(op.path);
        }
        // The conditional DELETE succeeded: it removed exactly the versions
        // it named (the file's, or every descendant's for a folder).
        acknowledgeDelete(entry, op, local, versionKnown: true);
      } catch (error) {
        entry.status = 'delete pending: $error';
      }
    }
    final deletedDirectories = <Entry>[];
    // A path absent from both the manifest and the listing has nothing to
    // reconcile (a full pass would not visit it either).
    _dirty.removeWhere(
      (v) => !manifest.entries.containsKey(v) && !remote.containsKey(v),
    );
    final Set<String> selected;
    if (audit) {
      selected = {...manifest.entries.keys, ...remote.keys};
    } else {
      selected = {
        for (final path in {
          ..._dirty,
          for (final op in manifest.operations.values)
            if (!_passiveOperations.contains(op.kind)) op.path,
        })
          if (manifest.entries.containsKey(path) || remote.containsKey(path))
            path,
      };
      // Ancestors precede descendants so directory creates come first.
      for (final path in selected.toList()) {
        var parent = p.posix.dirname(path);
        while (parent != '.' && selected.add(parent)) {
          parent = p.posix.dirname(parent);
        }
      }
      selected.removeWhere(
        (v) => !manifest.entries.containsKey(v) && !remote.containsKey(v),
      );
    }
    final paths = selected.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    // Directories whose conflict, pending creation or delete intent blocks
    // every descendant. Computed once, then kept exact as paths change.
    final blockers = <String>{
      for (final entry in manifest.entries.values)
        if (_blocks(entry)) entry.path,
    };
    bool blocked(String path) {
      var parent = p.posix.dirname(path);
      while (parent != '.') {
        if (blockers.contains(parent)) return true;
        parent = p.posix.dirname(parent);
      }
      return false;
    }

    // The transfer queue the user sees: files this pass expects to upload
    // or download. Each leaves it once the pass has visited it.
    activity.plan(
      paths.where(
        (path) =>
            !blocked(path) &&
            !_held(path) &&
            !moving(path) &&
            _expectsTransfer(path, local, remote),
      ),
    );
    String? previous;
    var listingOnlyRows = 0;
    for (final path in paths) {
      if (previous != null) activity.retire(previous);
      previous = path;
      if (between != null && await between()) {
        blockers
          ..clear()
          ..addAll([
            for (final entry in manifest.entries.values)
              if (_blocks(entry)) entry.path,
          ]);
      }
      if (stopRequested) {
        manifest.save();
        return paths.length;
      }
      if (_deferred.contains(path)) continue;
      if (!rootAvailable()) {
        return paths.length;
      }
      _visited++;
      if (_held(path) || moving(path) || reappeared.contains(path)) {
        _dirty.add(path);
        continue;
      }
      final current = remote[path];
      final here = local[path];
      final entry = manifest.entries.putIfAbsent(
        path,
        () => Entry(path, current!.kind),
      );
      if (current != null) {
        entry
          ..permissions = current.permissions
          ..sharedOut = current.shared;
      }
      if (entry.kind == ItemKind.unsupported ||
          entry.conflict != null ||
          operation(path, 'delete') != null) {
        _dirty.remove(path);
        continue;
      }
      // An ancestor delete/edit conflict must block child re-uploads too.
      if (blocked(path)) {
        _dirty.add(path);
        continue;
      }
      final before = jsonEncode(entry.toJson());
      var failed = false;
      ({String signature, int size})? uploadFailure;
      try {
        if (current != null && current.kind != entry.kind) {
          conflict(entry, 'Local/cloud item types differ.');
          continue;
        }
        if (entry.kind == ItemKind.directory) {
          if (entry.awaitingFolderUpload && current != null) {
            conflict(
              entry,
              'Cloud already contains this folder name. Existing local and cloud content retained; review both locations.',
            );
            continue;
          }
          if (current == null &&
              (entry.etag != null || entry.status.startsWith('deleted'))) {
            final unsafeChild = manifest.entries.values.any(
              (child) =>
                  p.posix.isWithin(path, child.path) &&
                  (child.conflict != null ||
                      child.kind == ItemKind.unsupported ||
                      (local.containsKey(child.path) &&
                          (child.kind == ItemKind.file
                              ? local[child.path]!.hash != child.baselineHash
                              : child.etag == null &&
                                    !child.status.startsWith('deleted')))),
            );
            if (unsafeChild) {
              conflict(
                entry,
                'Remote folder deletion meets unsynchronized descendants. Local bytes retained.',
              );
            } else {
              deletedDirectories.add(entry);
            }
            continue;
          }
          if (here == null &&
              current == null &&
              entry.etag == null &&
              (isCantSyncName(entry.status) ||
                  isLegacyNameHold(entry.status))) {
            // Renamed or removed before it was ever synchronized.
            uploads.forget(path);
            entry.expectedPresent = false;
            entry.status = 'removed locally';
            continue;
          }
          if (here != null &&
              current == null &&
              entry.etag == null &&
              !entry.status.startsWith('deleted')) {
            if (viewOnly(path)) {
              conflict(entry, viewOnlyConflict);
              continue;
            }
            // A name no rule resolves (spec #49): never created.
            final residual = _residualStatus(entry);
            if (residual != null) {
              entry.status = residual;
              continue;
            }
            await cloud.mkdir(path);
            entry.localIdentity = _recordedIdentity(here);
            if (_birthTracked(here)) entry.localBirth = here.birth;
            entry.awaitingFolderUpload = false;
            entry.expectedPresent = true;
            entry.status = 'current local';
          } else if (current != null &&
              here == null &&
              _unplaceable.contains(path)) {
            // No local name fits (spec #49 R3): never created here.
            entry.etag = current.etag;
            entry.expectedPresent = false;
            entry.status = unplaceableStatus;
          } else if (current != null) {
            // Last guard (review D-H1): a share is never adopted over a
            // folder with no synchronized history.
            if (here != null && entry.etag == null && _listedAsShare(current)) {
              conflict(
                entry,
                'A folder shared with you has the name of a folder here that was never synchronized. Rename this folder to receive the share.',
              );
              continue;
            }
            // A folder of a deleted top folder comes back even when it is
            // Cloud-only, as it was (spec #34 P7).
            final bringBack =
                here == null &&
                (retention(path) == Retention.local || entry.restoring);
            if (bringBack) tree.ensureDirectory(path);
            entry.etag = current.etag;
            entry.expectedPresent = here != null || bringBack;
            entry.status = entry.expectedPresent
                ? 'current local'
                : 'cloud-only';
          }
          continue;
        }
        if (current == null && entry.etag != null) {
          if (here != null && here.hash != entry.baselineHash) {
            conflict(
              entry,
              'Remote deletion meets unsynchronized local edits.',
            );
          } else {
            // Another device's deletion, or a descendant of a folder this
            // client deleted: the deleted version is the last one observed,
            // unless the deletion was found already complete (unknown).
            if (here != null) {
              preserve(
                entry,
                facts: deletionFacts(
                  entry,
                  _unknownDeletion(path) ? null : entry.etag,
                ),
              );
            }
            entry.etag = null;
            entry.expectedPresent = false;
            entry.status = 'deleted remotely';
          }
          continue;
        }
        if (here == null && current == null) {
          // Gone from disk, not merely hidden (pending folder, exclusion).
          if (entry.kind == ItemKind.file &&
              entry.etag == null &&
              !rawLocal.containsKey(path) &&
              (operation(path, 'upload') != null ||
                  _unsettled(entry) ||
                  isSizeRefusal(entry.status) ||
                  isCantSyncName(entry.status))) {
            _settleUnsyncedRemoval(entry);
          }
          continue;
        }
        final dirty = here != null && here.hash != entry.baselineHash;
        final changed =
            current != null &&
            (current.etag != entry.etag || entry.refreshRemote);
        if (dirty && changed) {
          final copy = await remoteCopy(current, 'conflict');
          final hash = await fileHash(copy, 'conflict');
          if (hash == here.hash) {
            entry.etag = current.etag;
            entry.baselineHash = hash;
            entry.recordRemoteVersion(current.etag, hash);
            entry.expectedPresent = true;
            entry.status = 'current local';
            final pendingUpload = operation(path, 'upload');
            if (pendingUpload != null) finish(pendingUpload);
          } else {
            entry.remoteCopy = tree.durablePath(copy);
            conflict(
              entry,
              'Both versions changed. Complete copies are retained.',
            );
          }
        } else if (dirty) {
          // View only: kept here as an in-place conflict, never uploaded.
          if (viewOnly(path)) {
            conflict(entry, viewOnlyConflict);
            continue;
          }
          final signature = _localSignature(here);
          final limit = cloud.uploadLimit;
          final held = uploads.hold(
            path,
            signature,
            size: here.size,
            limit: limit,
          );
          if (held != null &&
              (held.refused || uploads.clock() < held.notBefore)) {
            entry.status = held.status;
            continue;
          }
          // A name no rule resolves (spec #49): never sent.
          final residual = _residualStatus(entry);
          if (residual != null) {
            entry.status = residual;
            continue;
          }
          // Over the limit the server reported: never staged, never sent.
          if (limit != null && here.size > limit) {
            entry.status = uploads.refuse(path, signature, limit: limit);
            continue;
          }
          if (transfersHeld) {
            _waitForNetwork(entry);
            continue;
          }
          waitingForNetwork.remove(path);
          final op = intent(path, 'upload', etag: entry.etag);
          final staged = op.staged == null
              ? artifacts.reserve(path, 'upload')
              : artifacts.resolve(op.staged!);
          // A retry reuses the snapshot of unchanged bytes (SC-028).
          if (!_snapshotCurrent(op, here)) {
            op.staged = tree.durablePath(staged);
            op.hash = tree.snapshotFile(
              path,
              staged,
              purpose: 'upload-snapshot',
            );
            artifacts.complete(staged, hash: op.hash);
          }
          manifest.save();
          op.data['dispatchState'] = 'started';
          manifest.save();
          barrier?.call('upload-before-dispatch', op);
          try {
            entry.etag = await cloud.upload(
              path,
              staged,
              etag: op.expectedEtag,
            );
          } catch (error) {
            uploadFailure = (signature: signature, size: here.size);
            rethrow;
          }
          uploads.succeeded(path);
          // A version read back separately may be a concurrent writer's; it
          // never becomes release evidence (spec #12 rule 2).
          final readBack = cloud.lastUploadReadBack;
          tree.native.checkRoot(tree.fd, tree.root.path);
          entry.baselineHash = op.hash;
          entry.localIdentity = _recordedIdentity(here);
          artifacts.complete(staged, hash: op.hash, etag: entry.etag);
          if (!readBack) entry.recordRemoteVersion(entry.etag!, op.hash!);
          confirmArtifacts(path, op.hash!, entry.etag!, readBack: readBack);
          entry.expectedPresent = true;
          entry.status = 'current local';
          finish(op);
        } else if (current != null && (changed || here == null)) {
          if (here == null && _unplaceable.contains(path)) {
            // No local name fits (spec #49 R3): never created here.
            entry.etag = current.etag;
            entry.baselineHash = null;
            entry.status = unplaceableStatus;
          } else if (retention(path) == Retention.cloud && here == null) {
            entry.etag = current.etag;
            entry.baselineHash = null;
            entry.status = 'cloud-only';
          } else {
            final restoring = entry.status == viewOnlyRestoring;
            if (transfersHeld) {
              _waitForNetwork(entry);
              continue;
            }
            waitingForNetwork.remove(path);
            final copy = await remoteCopy(current, 'download');
            final hash = await fileHash(copy, 'download');
            if (here != null) {
              if (checkLocal(path) != entry.baselineHash) {
                entry.remoteCopy = tree.durablePath(copy);
                conflict(entry, 'Local content changed before replacement.');
                continue;
              }
              preserve(entry);
            }
            installOwned(path, copy);
            entry.etag = current.etag;
            entry.baselineHash = hash;
            entry.recordRemoteVersion(current.etag, hash);
            entry.localHash = hash;
            entry.expectedPresent = true;
            entry.status = restoring
                ? viewOnlyRestored
                : entry.restoring
                ? topFolderRestored
                : 'current local';
            entry.refreshRemote = false;
          }
        } else if (here != null) {
          entry.expectedPresent = true;
          entry.status = 'current local';
        }
        await editing.run(entry, current, retention(path));
        if (retention(path) == Retention.cloud &&
            !editing.requests.any((o) => o.path == path) &&
            (entry.expectedPresent ||
                operation(path, 'evict') != null ||
                operation(path, 'working') != null) &&
            entry.conflict == null) {
          await evictions.run(entry);
        }
      } catch (error) {
        if (error is TransfersHeld) {
          // The gate refused bytes on mobile data: no backoff, no retry
          // loop; the path is revisited when Wi-Fi returns.
          _waitForNetwork(entry);
          continue;
        }
        failed = true;
        entry.status = 'pending: $error';
        if (!rootAvailable()) {
          _dirty.add(path);
          _touched.add(path);
          manifest.save();
          return paths.length;
        }
        // The gateway refused the name (its spec #49 backstop): the residual
        // row, visited again when the item changes or the user retries.
        if (error is NameNotPortable) {
          entry.status = error.message;
        } else if (uploadFailure != null) {
          // An interrupted upload backs off; a size refusal waits for the
          // file to change or the user to retry (SC-028).
          entry.status =
              uploads.failed(
                path,
                uploadFailure.signature,
                error,
                size: uploadFailure.size,
                limit: cloud.uploadLimit,
              ) ??
              entry.status;
        }
      } finally {
        // Visited without failure: back, Cloud-only, or deleted elsewhere.
        if (entry.restoring &&
            !failed &&
            entry.conflict == null &&
            entry.status != topFolderRestoring) {
          entry.restoring = false;
        }
        if (_blocks(entry)) {
          blockers.add(path);
        } else {
          blockers.remove(path);
        }
        // Revisit until a pass leaves the path unchanged and settled.
        if (failed ||
            _unsettled(entry) ||
            jsonEncode(entry.toJson()) != before) {
          _dirty.add(path);
          _touched.add(path);
        } else {
          _dirty.remove(path);
        }
      }
      // A row that only records the cloud joins the next commit instead of
      // costing a durable commit of its own: a first pass over 10,000
      // Cloud-only files was 10,000 fsyncs (SC-057).
      if (listingOnlyRow(entry, here: here, failed: failed) &&
          ++listingOnlyRows < listingOnlyCommit) {
        continue;
      }
      listingOnlyRows = 0;
      manifest.save();
    }
    if (previous != null) activity.retire(previous);
    if (!rootAvailable()) {
      manifest.save();
      return paths.length;
    }
    // Reconcile children first. Never recursively delete a local tree: an
    // unexpected child or concurrent insertion makes rmdir fail and retains it.
    deletedDirectories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in deletedDirectories) {
      if (!rootAvailable()) return paths.length;
      if (isTopFolder(directory.path)) {
        // Deleted in the cloud by other means: kept here, created again.
        directory.etag = null;
        directory.expectedPresent = true;
        directory.status = 'queued';
        _dirty.add(directory.path);
        manifest.save();
        continue;
      }
      try {
        if (rawLocal.keys.any(
          (v) => p.posix.isWithin(directory.path, v) && isSyncExcluded(v),
        )) {
          directory.etag = null;
          directory.expectedPresent = false;
          directory.status = 'deleted remotely; excluded local files retained';
          manifest.save();
          continue;
        }
        if (local.containsKey(directory.path)) {
          tree.removeEmptyDirectory(
            directory.path,
            local[directory.path]!.identity!,
          );
        }
        directory.etag = null;
        directory.expectedPresent = false;
        directory.status = 'deleted remotely';
      } catch (error) {
        conflict(
          directory,
          'Deleted folder still contains local or changed items; retained: $error',
        );
      }
      manifest.save();
    }
    // Same pass as the upload/deletion acknowledgement; also converges copies
    // left by earlier versions and interrupted releases.
    var releasePending = false;
    // Whether the server has a trash to restore from, and its trash_days
    // (spec #44), about once a day: decides whether deletion copies may go.
    await _learnTrash();
    try {
      releasePending = releaseRedundantStaging();
    } on FileSystemException {
      releasePending = true;
    }
    if (_metadataDue) {
      await _listingMetadata(remote);
      _metadataDue = false;
    }
    await _refreshOutgoing();
    passes++;
    releasePending =
        releasePending ||
        manifest.operations.values.any((o) => o.kind == 'evict') ||
        manifest.entries.values.any(
          (e) => e.status.toLowerCase().startsWith('cloud pending'),
        );
    if (audit) {
      _fullPending = false;
      _rowsAudited = false;
      _lastAudit = _clock.elapsed;
    }
    message =
        folderWarning ??
        (releasePending
            ? 'Reconciled. Busy or uncertain Cloud releases remain pending.'
            : 'Reconciled.');
    final note = localNote;
    if (note != null) message = '$message $note';
    final topNote = _topFolderNote();
    if (topNote != null) message = '$message $topNote';
    manifest.save();
    return paths.length;
  }

  /// Opening is not editing (decision #183, narrowing #108 Q10): a working
  /// copy no app changed is a downloaded copy, released once no app holds it
  /// open, without Finish editing. Only a copy every hand-out of which went
  /// through the tracked documents provider is released automatically
  /// (decision #184): an app given a plain path (desktop Open) may have
  /// closed it and still save to it later, so such a copy is kept until the
  /// user removes it ([removeOpenedCopy]). A copy is left for
  /// [workingCopyGrace] after its last hand-out (an app may read, close and
  /// save later). The release is the guarded staging release (the lease, and
  /// on Android the open-descriptor registry, refuse a copy an app holds
  /// open; the bytes must still hash to the version that was handed out), so
  /// an open copy is retried by a later pass and a changed one is never
  /// discarded. Busy copies are not reported as pending releases: a song
  /// playing is not a sync problem.
  void reclaimUnchangedWorkingCopies() {
    for (final work
        in manifest.operations.values
            .where((o) => o.kind == 'working')
            .toList()) {
      final staged = work.staged;
      final entry = manifest.entries[work.path];
      if (staged == null || work.hash == null) continue;
      final record = artifacts.record(artifacts.resolve(staged));
      final name = p.basename(staged);
      bool present() {
        try {
          artifacts.native.info(tree.stageFd, name);
          return true;
        } on FileSystemException catch (error) {
          return error.osError?.errorCode != 2;
        }
      }

      if (work.data['reclaiming'] == true) {
        // Interrupted after the guarded unlink: the durable release intent
        // (or its already finalized record) proves the bytes were these.
        if (!present() &&
            (record == null || record.data['releasing'] == work.hash)) {
          if (record != null) manifest.operations.remove(record.id);
          _workingReclaimed(work, entry);
          continue;
        }
        work.data.remove('reclaiming');
        manifest.save();
      }
      if (!_providerOnly(work) || !_graceOver(work)) continue;
      _releaseWorking(work, record, entry);
    }
  }

  /// Every hand-out of [work] went through the tracked documents provider.
  /// A session from before hand-outs were recorded counts as tracked only
  /// where the provider is the sole way a copy is handed out: the
  /// registry-backed release guard is installed exactly there (Android,
  /// whose Open action also hands out the provider document).
  bool _providerOnly(Operation work) =>
      work.data['handout'] == 'provider' ||
      (work.data['handout'] == null &&
          artifacts.native is RegisteredReleaseGuard);

  /// [workingCopyGrace] has passed since [work] was last handed out. A
  /// session with no recorded hand-out (or one in the future: the clock was
  /// set back) starts its grace now.
  bool _graceOver(Operation work) {
    final now = wallClock().millisecondsSinceEpoch;
    final at = work.data['handedAt'];
    if (at is! int || at > now) {
      work.data['handedAt'] = now;
      manifest.save();
      return workingCopyGrace <= Duration.zero;
    }
    return now - at >= workingCopyGrace.inMilliseconds;
  }

  /// Releases unchanged working copy [work] through the guarded staging
  /// release; null when it is not eligible (changed, finishing, conflicted
  /// or not exclusively owned). A durable `reclaiming` mark covers a crash
  /// between the unlink and the session's removal.
  ReleaseOutcome? _releaseWorking(
    Operation work,
    Operation? record,
    Entry? entry,
  ) {
    if (work.hash == null ||
        artifacts.workingEdited(work) ||
        record == null ||
        record.data['role'] != 'working' ||
        entry?.conflict != null ||
        editing.requests.any((o) => o.path == work.path) ||
        manifest.operations.values.any(
          (o) =>
              o.id != work.id && o.id != record.id && o.staged == work.staged,
        )) {
      return null;
    }
    work.data['reclaiming'] = true;
    manifest.save();
    ReleaseOutcome outcome;
    try {
      outcome = releases.release(record, work.hash!);
    } on FileSystemException {
      outcome = ReleaseOutcome.busy;
    }
    if (outcome == ReleaseOutcome.released) {
      _workingReclaimed(work, entry);
      return outcome;
    }
    work.data.remove('reclaiming');
    // Bytes that no longer hash to the handed-out version are an edit.
    if (outcome == ReleaseOutcome.differs) work.data['edited'] = true;
    manifest.save();
    return outcome;
  }

  /// Remove opened copy (decision #184): the user's removal of unchanged
  /// working copy [id] of [path], through the same guarded release. Refused
  /// while an app holds it open; a copy found changed becomes an edit
  /// (Editing, Finish editing) and is kept.
  void removeOpenedCopy(String path, String id) {
    requireStorageReady();
    final work = manifest.operations[id];
    if (work == null || work.kind != 'working' || work.path != path) {
      message = 'This opened copy was already removed.';
      return;
    }
    if (artifacts.workingEdited(work)) {
      message = 'This copy has changes. Use Finish editing.';
      return;
    }
    final record = work.staged == null
        ? null
        : artifacts.record(artifacts.resolve(work.staged!));
    final outcome = _releaseWorking(work, record, manifest.entries[path]);
    message = switch (outcome) {
      ReleaseOutcome.released => 'Opened copy removed.',
      ReleaseOutcome.busy => openedCopyBusy,
      ReleaseOutcome.differs => 'This copy has changes. Use Finish editing.',
      _ => 'This copy could not be verified. It is kept.',
    };
  }

  /// The refusal while an app holds an opened copy.
  static const openedCopyBusy =
      'This copy is open or changing. Try again when it is closed.';

  void _workingReclaimed(Operation work, Entry? entry) {
    manifest.operations.remove(work.id);
    if (entry != null) {
      if (entry.workingCopy == work.staged) entry.workingCopy = null;
      final status = entry.status;
      // The status an opened copy (or an interrupted reclaim, or an earlier
      // version's pin) left on a Cloud-only row reads as Cloud-only again.
      if (!entry.expectedPresent &&
          retention(entry.path) == Retention.cloud &&
          !manifest.operationsAt(entry.path).any((o) => o.kind == 'working') &&
          (status.startsWith('Cloud pending: editor working copies') ||
              status == openedCopyKept ||
              status == 'Working copy missing; root/cloud retained')) {
        entry.status = 'cloud-only';
      }
      markDirty(entry.path);
    }
    manifest.save();
  }

  /// A deletion copy made by an earlier version is recognised only when it is
  /// the entry's last preservation, made from the same baseline that the
  /// terminal deletion recorded. Anything else stays an ordinary recovery copy.
  bool _legacyDeletionCopy(Entry entry, Operation retained) =>
      retained.data['deletion'] == null &&
      retained.expectedEtag != null &&
      retained.hash != null &&
      retained.hash == entry.baselineHash &&
      entry.preservedCopies.isNotEmpty &&
      entry.preservedCopies.last == retained.staged;

  /// Returns true when a busy or uncertain staging release remains.
  bool releaseRedundantStaging() {
    var pending = false;
    void outcome(ReleaseOutcome value) {
      if (value == ReleaseOutcome.busy || value == ReleaseOutcome.uncertain) {
        pending = true;
      }
    }

    releases.recoverInterrupted();
    reclaimUnchangedWorkingCopies();
    // Rule 2: a copy preserved when our deletion was acknowledged is released
    // only when its bytes equal the hash recorded for the deleted version.
    for (final retained
        in manifest.operations.values
            .where((o) => o.kind == 'retained')
            .toList()) {
      final entry = manifest.entries[retained.path];
      if (entry == null ||
          entry.kind != ItemKind.file ||
          !const {'deleted', 'deleted remotely'}.contains(entry.status) ||
          entry.etag != null ||
          entry.conflict != null ||
          retained.staged == null ||
          releases.busy(entry.path) ||
          !manifest.operations.containsKey(retained.id)) {
        continue;
      }
      if (_legacyDeletionCopy(entry, retained)) {
        retained.data['deletion'] = true;
        retained.data['deletedVersion'] = retained.expectedEtag;
        retained.data['deletedVersionHash'] = releases.hashForVersion(
          entry,
          retained.expectedEtag!,
        );
        // Persist the version evidence before any upload record is released.
        manifest.save();
      }
      if (retained.data['deletion'] != true) continue;
      // A server without a trash (an older gateway, or not yet known) gives
      // no way back: the copy is kept in the device trash instead (spec #44).
      if (!deviceTrash.serverTrash) continue;
      final expected = retained.data['deletedVersionHash'] as String?;
      if (expected == null) continue;
      adoptInterruptedPreserve(retained.staged!);
      final record = artifacts.record(File(retained.staged!));
      if (record == null || record.data['role'] != 'preserved') continue;
      final aliases = artifacts.records
          .where(
            (o) =>
                o.id != record.id &&
                StagingRelease.entryPath(o) == entry.path &&
                o.data['role'] == 'download' &&
                o.data['identity'] != null &&
                o.data['identity'] == record.data['identity'] &&
                !manifest.operations.values.any(
                  (other) =>
                      other.kind != 'artifact' && other.staged == o.staged,
                ),
          )
          .toList();
      try {
        outcome(releases.release(record, expected, aliases: aliases));
      } on FileSystemException {
        pending = true;
      }
    }
    // Rule 1: an upload snapshot whose version the server acknowledged.
    final trash = deviceTrash.held;
    for (final record in artifacts.records.toList()) {
      if (trash.contains(record.staged)) continue;
      final role = record.data['role'];
      if ((role != 'upload' && role != 'upload-recovery') ||
          record.phase != 'complete' ||
          record.hash == null ||
          record.expectedEtag == null ||
          record.data['versionReadBack'] == true ||
          record.staged == null ||
          !manifest.operations.containsKey(record.id)) {
        continue;
      }
      final path = StagingRelease.entryPath(record);
      final entry = manifest.entries[path];
      if (entry == null ||
          entry.conflict != null ||
          entry.remoteCopy == record.staged ||
          entry.workingCopy == record.staged ||
          entry.preservedCopies.contains(record.staged) ||
          releases.busy(path) ||
          manifest.operations.values.any(
            (o) => o.id != record.id && o.staged == record.staged,
          )) {
        continue;
      }
      try {
        outcome(releases.release(record, record.hash!));
      } on FileSystemException {
        pending = true;
      }
    }
    // The device trash (spec #44): a copy the restored file now holds goes,
    // the copies of completed deletions move into the trash (also the rows
    // earlier versions left, T7), and copies past `trash_days` are purged.
    // Never a reason to report a pending release.
    try {
      deviceTrash.releaseRestored();
      if (!debugDeletionRecoveryRows) deviceTrash.collect();
      deviceTrash.purge();
    } on FileSystemException {
      // Retried at the next pass; nothing is removed unless verified.
    }
    // Forget an unobserved folder deletion once no descendant can still be
    // reconciled as a remote deletion.
    final unknown = _unknownDeletedFolders();
    final live = unknown
        .where(
          (folder) => manifest.entries.values.any(
            (e) => p.posix.isWithin(folder, e.path) && e.etag != null,
          ),
        )
        .toList();
    if (live.length != unknown.length) {
      if (live.isEmpty) {
        manifest.deleteSetting(_unknownDeletionKey);
      } else {
        manifest.setSetting(_unknownDeletionKey, jsonEncode(live));
      }
    }
    return pending;
  }

  /// A preserve interrupted between rename and completion leaves its record
  /// reserved without identity. The exact target name was recorded before
  /// the rename, so the moved file is adopted as owned; nothing is released
  /// here, and any later release still requires a guarded hash match.
  void adoptInterruptedPreserve(String staged) {
    final record = artifacts.record(File(staged));
    if (record == null ||
        record.phase != 'reserved' ||
        record.data['role'] != 'preserved' ||
        record.data['directoryIdentity'] !=
            tree.native.identity(tree.stageFd)) {
      return;
    }
    try {
      artifacts.complete(artifacts.resolve(staged), moved: true);
    } on FileSystemException {
      // Absent or unreadable: stays uncertain and retained.
    }
  }

  /// Captured when the copy is preserved, before any upload record that
  /// holds the evidence can be released. A null version means unknown.
  Map<String, Object?> deletionFacts(Entry entry, String? version) => {
    'deletion': true,
    'deletedVersion': version,
    'deletedVersionHash': version == null
        ? null
        : releases.hashForVersion(entry, version),
  };

  static const _unknownDeletionKey = 'unknownDeletedFoldersV1';
  List<String> _unknownDeletedFolders() {
    try {
      return (jsonDecode(manifest.setting(_unknownDeletionKey) ?? '[]') as List)
          .cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Persisted before the folder acknowledgement so that descendants
  /// reconciled in a later pass still know their deletion was not observed.
  void _markUnknownDeletion(String folder) {
    final folders = {..._unknownDeletedFolders(), folder}.toList()..sort();
    manifest.setSetting(_unknownDeletionKey, jsonEncode(folders));
  }

  bool _unknownDeletion(String path) => _unknownDeletedFolders().any(
    (folder) => folder == path || p.posix.isWithin(folder, path),
  );

  void acknowledgeDelete(
    Entry entry,
    Operation op,
    Map<String, LocalItem> local, {
    required bool versionKnown,
  }) {
    // The deleted item followed a cloud move onto a name a different local
    // file holds (#80 review L1): that file is not touched and becomes a new
    // item of its own (uploaded by the ordinary rules).
    if (op.data['otherItemHere'] == true) {
      entry
        ..expectedPresent = false
        ..etag = null
        ..fileId = null
        ..baselineHash = null
        ..localIdentity = null
        ..status = 'queued';
      finish(op);
      _dirty.add(entry.path);
      return;
    }
    if (entry.kind == ItemKind.file && local.containsKey(entry.path)) {
      preserve(
        entry,
        facts: {
          ...deletionFacts(entry, versionKnown ? op.expectedEtag : null),
          // Edited here after the version the server deleted (spec #44).
          if (op.data['localChanged'] == true ||
              (local[entry.path]?.hash != null &&
                  entry.baselineHash != null &&
                  local[entry.path]!.hash != entry.baselineHash))
            'localChanged': true,
        },
      );
      local.remove(entry.path);
    }
    entry.expectedPresent = false;
    entry.etag = null;
    entry.status = 'deleted';
    finish(op);
  }

  void installOwned(String path, File file) {
    tree.native.checkRoot(tree.fd, tree.root.path);
    final parent = p.posix.dirname(path);
    if (parent != '.') {
      tree.ensureDirectory(parent);
    }
    if (!tree.native.hardLinks) return _moveOwned(path, file);
    artifacts.native.install(
      tree.fd,
      path,
      tree.stageFd,
      p.basename(file.path),
    );
    final record = artifacts.record(file);
    // The bytes hashed in staging are the bytes now linked into the root.
    tree.own(
      path,
      hash: record?.phase == 'complete' ? record?.hash : null,
      stagedStamp: record?.data['stamp'] as String?,
    );
    if (record != null) {
      record.data['entryPath'] = path;
      manifest.save();
    }
  }

  /// [installOwned] where the boundary cannot link (Android, decision #123
  /// (2)): the staged file itself is renamed into place (never replacing
  /// [path]) and its record is finalized, so staging keeps no second copy.
  /// The intent is durable before the rename; a restart finishes it
  /// ([Artifacts.finishInterruptedMoves]).
  void _moveOwned(String path, File file) {
    final record = artifacts.record(file);
    if (record != null) {
      record.data['installing'] = path;
      manifest.save();
    }
    artifacts.native.restore(
      tree.fd,
      path,
      tree.stageFd,
      p.basename(file.path),
    );
    // The bytes hashed in staging are the bytes now at [path].
    tree.own(
      path,
      hash: record?.phase == 'complete' ? record?.hash : null,
      stagedStamp: record?.data['stamp'] as String?,
    );
    artifacts.consumed(tree.durablePath(file));
    manifest.save();
  }

  String checkLocal(String path) {
    final file = artifacts.reserve(path, 'check');
    final hash = tree.snapshotFile(path, file, purpose: 'replace-check');
    artifacts.complete(file, hash: hash, etag: manifest.entries[path]?.etag);
    return hash;
  }

  void confirmArtifacts(
    String path,
    String hash,
    String etag, {
    bool readBack = false,
  }) {
    for (final record in artifacts.records.where(
      (o) =>
          (o.data['entryPath'] ?? o.path) == path &&
          o.phase == 'complete' &&
          o.hash == hash,
    )) {
      record.expectedEtag = etag;
      if (readBack) {
        record.data['versionReadBack'] = true;
      } else {
        record.data.remove('versionReadBack');
      }
    }
    manifest.save();
  }

  void preserve(Entry entry, {Map<String, Object?> facts = const {}}) {
    final op = intent(entry.path, 'preserve', etag: entry.etag);
    op.data.addAll(facts);
    // Record exact target before moving so restart can distinguish internal work.
    final target = artifacts.reserve(entry.path, 'preserved', create: false);
    final durable = tree.durablePath(target);
    op.staged = durable;
    op.hash = entry.baselineHash;
    manifest.save();
    tree.native.checkRoot(tree.fd, tree.root.path);
    artifacts.native.preserve(
      tree.fd,
      entry.path,
      tree.stageFd,
      p.basename(target.path),
    );
    tree.own(entry.path);
    artifacts.complete(target, moved: true);
    entry.preservedCopies.add(durable);
    entry.expectedPresent = false;
    final retained = Operation(
      uniqueId(),
      'retained',
      entry.path,
      expectedEtag: entry.etag,
      staged: durable,
      hash: entry.baselineHash,
    )..data = Map<String, dynamic>.from(facts);
    manifest.operations[retained.id] = retained;
    finish(op);
  }

  void _migrateCloudRoot(
    Map<String, LocalItem> local,
    Map<String, RemoteItem> remote,
  ) {
    final previous = {
      for (final entry in manifest.entries.values)
        entry.path: Entry.fromJson(Map<String, dynamic>.from(entry.toJson())),
    };
    final directFiles = <String, (int, int)>{};
    try {
      for (final path in {
        ...manifest.entries.keys,
        ...local.keys,
        ...remote.keys,
      }) {
        if (isSyncExcluded(path)) continue;
        validateRelative(path);
        final parts = path.split('/');
        // Documents, Music and Videos stay Local (spec #34 P7): the former
        // Cloud intent goes to each folder inside them instead.
        if (isTopFolder(parts.first) && parts.length < 2) continue;
        if (isTopFolder(parts.first) &&
            parts.length == 2 &&
            remote[path]?.kind == ItemKind.file &&
            !local.containsKey(path)) {
          final seen = directFiles.putIfAbsent(parts.first, () => (0, 0));
          directFiles[parts.first] = (
            seen.$1 + 1,
            seen.$2 + remote[path]!.size,
          );
        }
        final top = isTopFolder(parts.first)
            ? '${parts[0]}/${parts[1]}'
            : parts.first;
        final entry = manifest.entries.putIfAbsent(
          top,
          () => Entry(
            top,
            local[top]?.kind ?? remote[top]?.kind ?? ItemKind.directory,
          ),
        );
        if (entry.kind == ItemKind.directory) {
          entry.override ??= Retention.cloud;
        }
      }
      // Both settings and the policy rows commit together; a failed commit
      // retains the legacy setting and must retry before sync can proceed.
      manifest.save(settings: {'retention': 'local'});
      for (final MapEntry(key: top, value: (files, bytes))
          in directFiles.entries) {
        _topNowLocal(top, files, bytes);
      }
      _fullPending = true;
      _rowsAudited = false;
    } catch (_) {
      manifest.entries
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  /// Read-only local scan while synchronization is paused: no network, no
  /// manifest write and no root change. Counts paths that differ from the
  /// recorded local state; they stay candidates for the first pass after
  /// resume (a restart re-detects them with its full startup pass).
  Future<int> observePaused() async {
    if (eventDriven) return _observePausedByEvents();
    final local = await tree.snapshot();
    final changed = <String>{};
    for (final item in local.values) {
      final entry = manifest.entries[item.path];
      if (entry == null ||
          entry.kind != item.kind ||
          (!entry.expectedPresent && entry.kind != ItemKind.directory) ||
          (item.kind == ItemKind.file && item.hash != entry.localHash)) {
        changed.add(item.path);
      }
    }
    for (final entry in manifest.entries.values) {
      if (entry.expectedPresent &&
          !local.containsKey(entry.path) &&
          !isSyncExcluded(entry.path)) {
        changed.add(entry.path);
      }
    }
    if (changed.isNotEmpty) {
      _dirty.addAll(changed);
      _localWork = true;
    }
    return changed.length;
  }

  /// [observePaused] with event-driven hashing (decisions #135, #130 (3)):
  /// never reads file content. A stat-only listing is compared with the
  /// kept view (a file whose stat moved since it was hashed has changed) and
  /// with the manifest (new, vanished or retyped paths), plus the paths the
  /// watcher has reported, which stay queued for the next unpaused pass.
  Future<int> _observePausedByEvents() async {
    final local = tree.scanItems();
    final view = _view;
    final changed = <String>{};
    for (final item in local.values) {
      final entry = manifest.entries[item.path];
      final seen = view?[item.path];
      if (entry == null ||
          entry.kind != item.kind ||
          (!entry.expectedPresent && entry.kind != ItemKind.directory) ||
          (item.kind == ItemKind.file &&
              seen != null &&
              (seen.scanStamp != item.scanStamp ||
                  seen.hash != entry.localHash))) {
        changed.add(item.path);
      }
    }
    for (final entry in manifest.entries.values) {
      if (entry.expectedPresent &&
          !local.containsKey(entry.path) &&
          !isSyncExcluded(entry.path)) {
        changed.add(entry.path);
      }
    }
    final w = watcher;
    if (w != null && w.active) {
      final work = w.take();
      w.requeue(work);
      changed.addAll(work.paths.where((path) => !isSyncExcluded(path)));
    }
    if (changed.isNotEmpty) {
      _dirty.addAll(changed);
      _localWork = true;
    }
    return changed.length;
  }

  void requireStorageReady() {
    if (manifest.setting('retention') == 'cloud') {
      throw const CloudFailure(
        'Storage upgrade pending: connect to preserve existing Cloud-only choices before changing or opening files.',
      );
    }
  }

  Future<String> createFolder(
    String parent,
    String name,
    Retention value,
  ) async {
    requireStorageReady();
    final path = await folders.create(parent, name, value);
    markDirty(path);
    localDirectories.add(path);
    message = 'Folder created. Synchronization is queued.';
    return path;
  }

  /// The Rename action of the residual row (spec #49 Error States): a name
  /// no rule resolves. Renames the never-synchronized local item within its
  /// folder, never replacing anything; the next pass uploads it under the new
  /// name (cleaning it first, as any local name).
  Future<String> renameLocal(String path, String name) async {
    requireStorageReady();
    validateRelative(path);
    final entry = manifest.entries[path];
    if (entry == null || entry.etag != null || !isCantSyncName(entry.status)) {
      throw const FileSystemException(
        'Only an item whose name cannot sync can be renamed here.',
      );
    }
    final refused = renameRefusal(
      name,
      folder: entry.kind == ItemKind.directory,
    );
    if (refused != null) throw FileSystemException(refused);
    final parent = p.posix.dirname(path);
    final target = parent == '.' ? name : '$parent/$name';
    validateRelative(target);
    if (isSyncExcluded(target)) {
      throw const FileSystemException(
        'This name is excluded from synchronization. Choose another name.',
      );
    }
    // Existence, type and identity only: no file content is read.
    final local = tree.scanItems(includeExcluded: true);
    final item = local[path];
    if (item == null || item.identity == null || item.kind != entry.kind) {
      throw const FileSystemException(
        'The item changed or is gone. Check the folder and try again.',
      );
    }
    final siblings = {
      for (final key in {
        ...local.keys,
        for (final known in manifest.entries.values)
          if (known.etag != null) known.path,
      })
        if (key != path && p.posix.dirname(key) == parent)
          p.posix.basename(key),
    };
    if (siblings.contains(name)) {
      throw const FileSystemException(
        'A file or folder already uses this name. Choose another name.',
      );
    }
    tree.native.renameExclusive(tree.fd, path, target, item.identity!);
    markDirty(path, descendants: true);
    markDirty(target);
    message = 'Renamed. Synchronization is queued.';
    return target;
  }

  /// Uses the existing scan facts; projection adds no filesystem work per row.
  String selectionVersion(Entry entry) => jsonEncode([
    entry.kind.name,
    entry.etag,
    entry.localHash,
    entry.expectedPresent,
    localIdentities[entry.path],
  ]);

  /// All targets are checked before any intent is written. Remote execution
  /// remains independently conditional and may complete at different times.
  Map<String, Object?> applyBulk(
    String action,
    List<Map<String, dynamic>> targets,
  ) {
    requireStorageReady();
    tree.native.checkRoot(tree.fd, tree.root.path);
    // Local only, so also while paused (spec #25).
    if (action == 'recover' || action == 'dismiss') {
      return recovery.apply(action, targets);
    }
    if (!{'local', 'cloud', 'delete'}.contains(action) || targets.isEmpty) {
      throw const FileSystemException(
        'Choose selected items and a bulk action.',
      );
    }
    final seen = <String>{};
    final checked = <Entry>[];
    final errors = <String>[];
    for (final target in targets) {
      final path = target['path'] as String;
      try {
        validateRelative(path);
        if (!seen.add(path) || isSyncExcluded(path)) {
          throw const FileSystemException('Invalid or duplicate target.');
        }
        final entry = manifest.entries[path];
        if (entry == null ||
            entry.kind == ItemKind.unsupported ||
            entry.kind.name != target['kind'] ||
            selectionVersion(entry) != target['selectionVersion'] ||
            deletedSelectionStatus(entry.status)) {
          throw const FileSystemException('Item changed; select it again.');
        }
        // Check only explicit targets, through the anchored native boundary.
        String? identity;
        try {
          identity = entry.kind == ItemKind.directory
              ? tree.native.directoryIdentity(tree.fd, path)
              : tree.native.fileIdentity(tree.fd, path);
        } on FileSystemException catch (error) {
          if (entry.expectedPresent ||
              localIdentities[path] != null ||
              error.osError?.errorCode != 2) {
            rethrow;
          }
        }
        if (identity != localIdentities[path]) {
          throw const FileSystemException(
            'Local item changed; select it again.',
          );
        }
        if (isTopFolder(path) && action == 'cloud') {
          throw const FileSystemException(topFolderCloudOnlyRefusal);
        }
        if (isTopFolder(path) && action == 'delete') {
          throw const FileSystemException(topFolderDeleteRefusal);
        }
        if (action == 'delete' && entry.etag == null) {
          throw const FileSystemException(
            'No synchronized version; upload first.',
          );
        }
        checked.add(entry);
      } catch (error) {
        errors.add('$path: $error');
      }
    }
    if (errors.isNotEmpty) {
      return {'accepted': 0, 'failed': targets.length, 'errors': errors};
    }
    final roots = action == 'delete'
        ? canonicalDeleteTargets(
            checked,
            pathOf: (entry) => entry.path,
            isDirectory: (entry) => entry.kind == ItemKind.directory,
          )
        // Folders first, outermost first, then files: a folder's choice
        // never clears the one a selected file is given in the same batch.
        : ([...checked]..sort((a, b) {
            final kind =
                (a.kind == ItemKind.directory ? 0 : 1) -
                (b.kind == ItemKind.directory ? 0 : 1);
            return kind != 0
                ? kind
                : a.path.split('/').length - b.path.split('/').length;
          }));
    final entriesBefore = {
      for (final entry in roots)
        entry.path: Entry.fromJson(Map<String, dynamic>.from(entry.toJson())),
    };
    final addedOperations = <String>[];
    final choicesBefore = <Entry, Retention?>{};
    try {
      for (final entry in roots) {
        if (action == 'delete') {
          final existing = operation(entry.path, 'delete');
          final queued = intent(
            entry.path,
            'delete',
            etag: entry.etag,
            persist: false,
          );
          if (existing == null) addedOperations.add(queued.id);
          _noteLocalEdits(entry, queued);
          entry.status = 'delete queued';
        } else {
          _choose(entry, Retention.values.byName(action), choicesBefore);
        }
      }
      manifest.save();
      for (final entry in roots) {
        markDirty(entry.path, descendants: true);
      }
    } catch (_) {
      for (final MapEntry(key: entry, value: choice) in choicesBefore.entries) {
        entry.override = choice;
      }
      manifest.entries.addAll(entriesBefore);
      for (final id in addedOperations) {
        manifest.operations.remove(id);
      }
      rethrow;
    }
    return {
      'accepted': roots.length,
      'failed': 0,
      'covered': checked.length - roots.length,
      'errors': errors,
      // What one Undo puts back (spec #44), and when it was deleted.
      if (action == 'delete') ...{
        'paths': [for (final entry in roots) entry.path],
        'at': wallClock().millisecondsSinceEpoch,
      },
    };
  }

  void setRetention(String path, Retention value) {
    validateRelative(path);
    requireStorageReady();
    if (isSyncExcluded(path)) {
      throw const FileSystemException('This item is outside synchronization.');
    }
    final entry = manifest.entries[path];
    if (entry == null) throw const FileSystemException('Unknown item');
    if (entry.kind != ItemKind.directory && entry.kind != ItemKind.file) {
      throw const FileSystemException('Choose a file or folder.');
    }
    _choose(entry, value);
    manifest.save();
    markDirty(path, descendants: true);
  }

  /// Records [value] as [entry]'s storage choice (spec #45, superseding
  /// decision #29), without saving. Each row changed is first recorded in
  /// [previous] with its former choice.
  ///
  /// A file's choice equal to what its folders give it is no choice of its
  /// own: it follows the folder again ("as folder").
  ///
  /// A folder's choice clears the own choices of the files that inherit
  /// from it (R2): those whose nearest folder with a choice is this one, so
  /// Cloud-only on a folder means everything in it. Nested folder choices
  /// stay. For a top folder those are its loose files only.
  void _choose(
    Entry entry,
    Retention value, [
    Map<Entry, Retention?>? previous,
  ]) {
    void set(Entry row, Retention? choice) {
      previous?.putIfAbsent(row, () => row.override);
      row.override = choice;
    }

    final path = entry.path;
    if (entry.kind == ItemKind.file) {
      set(entry, value == folderRetention(path) ? null : value);
      return;
    }
    final top = isTopFolder(path);
    // A top folder's row is the choice for what is inside it (decision
    // #163, M1): new and loose files. The folder itself stays (retention).
    // Switching it changes only loose files and folders added later: each
    // folder already inside without a choice of its own first gets one that
    // keeps its current state, so nothing already there is evicted or
    // downloaded by the switch (#97 re-review N2).
    if (top && value != folderRetention('$path/_')) {
      final current = folderRetention('$path/_');
      for (final child in manifest.entries.values) {
        if (child.kind == ItemKind.directory &&
            child.override == null &&
            p.posix.dirname(child.path) == path) {
          set(child, current);
        }
      }
    }
    set(entry, value);
    for (final file in manifest.entries.values) {
      if (file.kind != ItemKind.file ||
          file.override == null ||
          !p.posix.isWithin(path, file.path)) {
        continue;
      }
      if (top
          ? p.posix.dirname(file.path) == path
          : _choosingFolder(file.path) == path) {
        set(file, null);
      }
    }
  }

  /// The nearest folder above [path] holding a storage choice; null when
  /// only the root's applies.
  String? _choosingFolder(String path) {
    var current = p.posix.dirname(path);
    while (current != '.') {
      final entry = manifest.entries[current];
      if (entry?.kind == ItemKind.directory && entry?.override != null) {
        return current;
      }
      current = p.posix.dirname(current);
    }
    return null;
  }

  void requestDelete(String path) {
    validateRelative(path);
    requireStorageReady();
    if (isSyncExcluded(path)) {
      throw const FileSystemException('This item is outside synchronization.');
    }
    final entry = manifest.entries[path];
    if (entry == null) throw const FileSystemException('Unknown item');
    if (isTopFolder(path)) {
      throw const FileSystemException(topFolderDeleteRefusal);
    }
    if (entry.etag == null) {
      throw const CloudFailure(
        'This item has no synchronized version. Retain it until it is uploaded.',
      );
    }
    _noteLocalEdits(entry, intent(path, 'delete', etag: entry.etag));
    entry.status = 'delete queued';
    manifest.save();
    markDirty(path, descendants: true);
  }

  /// A file whose local bytes differ from the version last synced: the delete
  /// trashes the server's older version, so the bytes preserved here are the
  /// latest and Undo and Restore use them (spec #44).
  void _noteLocalEdits(Entry entry, Operation delete) {
    if (entry.kind == ItemKind.file &&
        entry.localHash != null &&
        entry.baselineHash != null &&
        entry.localHash != entry.baselineHash) {
      delete.data['localChanged'] = true;
    }
  }

  Future<void> _learnTrash() async {
    final api = trashApi;
    if (api == null || !deviceTrash.checkDue) return;
    try {
      deviceTrash.learned(await api.listTrash());
    } on Exception {
      // Unreachable now: what was known stays, and the next pass asks again.
    }
  }

  // ------------------------------------------------------------- Trash

  /// The gateway's trash routes (spec #44), when this cloud has them.
  TrashApi? get trashApi => cloud is TrashApi ? cloud as TrashApi : null;

  static const trashUnreachable =
      "Can't reach the server: showing only this device's trash";

  /// The Trash view: one entry per deletion, newest first (spec #44). The
  /// server part is left out, with a note, when [server] is false (paused or
  /// offline) or the server cannot be reached.
  Future<Map<String, Object?>> trashListing({bool server = true}) async {
    ServerTrash? listed;
    String? note;
    final api = trashApi;
    if (!server || api == null) {
      note = trashUnreachable;
    } else {
      try {
        listed = await api.listTrash();
        deviceTrash.learned(listed);
        if (listed == null) {
          note =
              "This server has no Trash yet: showing only this device's trash";
        }
      } on Exception {
        note = trashUnreachable;
      }
    }
    final days = deviceTrash.days;
    return {
      'note': note,
      'server': listed != null,
      'trashDays': days,
      'deviceBytes': deviceTrash.bytes,
      'entries': [
        for (final entry in mergeTrash(listed?.items ?? const [], [
          // Shown, and joined with the server's items, by cloud path.
          for (final copy in deviceTrash.items())
            DeviceTrashItem(
              id: copy.id,
              path: names.cloudPath(copy.path),
              size: copy.size,
              at: copy.at,
              changed: copy.changed,
            ),
        ]))
          entry.toJson(days),
      ],
    };
  }

  /// Restore of one Trash entry: the server item when there is one, else the
  /// device copy. Returns where it went and whether the name was taken.
  Future<Map<String, Object?>> trashRestore({
    String? serverId,
    String? deviceId,
  }) async {
    requireStorageReady();
    final edited =
        deviceId != null &&
        deviceTrash.items().any((c) => c.id == deviceId && c.changed);
    if (serverId != null && !edited) {
      final api = trashApi;
      if (api == null) throw const CloudFailure(trashUnreachable);
      final restored = await api.restoreTrash(serverId);
      _restoredFromServer(names.localPath(restored.path));
      return {'path': restored.path, 'renamed': restored.renamed};
    }
    if (deviceId == null) throw const CloudFailure('No longer in Trash');
    final result = deviceTrash.restore(deviceId);
    final destination = result['destination'] as String;
    return {
      'path': destination,
      'renamed': destination != result['path'],
      if (result['kept'] == true) 'kept': true,
    };
  }

  /// An item the server restored: its path is read again by the next pass,
  /// and a delete still queued there is dropped (it would delete it again).
  void _restoredFromServer(String path) {
    final queued = operation(path, 'delete');
    if (queued != null) finish(queued);
    final entry = manifest.entries[path];
    if (entry != null && deletionStatuses.contains(entry.status)) {
      entry.refreshRemote = true;
      manifest.save();
    }
    markDirty(path, descendants: true);
  }

  /// Delete now (spec #44): permanent, for the given server items and
  /// device copies. Returns how many went and the errors of the rest.
  Future<Map<String, Object?>> trashDelete(
    List<String> serverIds,
    List<String> deviceIds,
  ) async {
    var deleted = 0;
    final errors = <String>[];
    final api = trashApi;
    for (final id in serverIds) {
      try {
        if (api == null) throw const CloudFailure(trashUnreachable);
        await api.deleteTrash(id);
        deleted++;
      } on CloudFailure catch (error) {
        if (error.status == 404) {
          deleted++;
        } else {
          errors.add(error.message);
        }
      }
    }
    for (final id in deviceIds) {
      try {
        deviceTrash.delete(id);
        deleted++;
      } on FileSystemException catch (error) {
        errors.add(error.message);
      }
    }
    return {'deleted': deleted, 'errors': errors.toSet().toList()};
  }

  /// Empty Trash (spec #44): the server's anj-cloud/ items when it can be
  /// reached, and every device copy that can be removed now.
  Future<Map<String, Object?>> trashEmpty({bool server = true}) async {
    var deleted = 0;
    final errors = <String>[];
    final api = trashApi;
    if (server && api != null) {
      try {
        deleted += await api.emptyTrash();
      } on Exception {
        errors.add("Couldn't empty the server's Trash. Try again later.");
      }
    } else {
      errors.add(trashUnreachable);
    }
    final before = deviceTrash.records.length;
    deleted += deviceTrash.empty();
    if (deviceTrash.records.length == before && before > 0) {
      errors.add('Copies open in another program are kept.');
    }
    return {'deleted': deleted, 'errors': errors};
  }

  /// Undo of one delete (spec #44): every path of it back with the same
  /// content. A delete not yet sent is cancelled (the local item never
  /// left); one the server applied is restored from the server's trash,
  /// else from the device trash. A name taken meanwhile gets `(restored)`.
  /// [at] is when the delete was made (ms since epoch). Never loses data:
  /// an item that cannot come back stays in Trash.
  Future<Map<String, Object?>> undoDelete(
    List<String> paths,
    int at, {
    bool server = true,
  }) async {
    requireStorageReady();
    final results = <Map<String, Object?>>[];
    final remote = <String>[];
    for (final path in paths) {
      validateRelative(path);
      final queued = operation(path, 'delete');
      if (queued != null && queued.data['dispatchState'] != 'started') {
        finish(queued);
        final entry = manifest.entries[path];
        if (entry != null && entry.status == 'delete queued') {
          entry.status = 'current local';
          manifest.save();
        }
        markDirty(path, descendants: true);
        results.add({'path': path, 'result': 'restored', 'to': path});
      } else {
        remote.add(path);
      }
    }
    if (remote.isEmpty) return {'results': results};
    // Clocks may disagree: a server item for the path deleted up to an hour
    // before this delete was made still counts as this delete's.
    const skew = Duration(hours: 1);
    Map<String, Object?> deviceResult(String path, DeviceTrashItem copy) {
      final result = deviceTrash.restore(copy.id);
      final destination = result['destination'] as String;
      return {
        'path': path,
        'result': destination == path ? 'restored' : 'renamed',
        'to': destination,
      };
    }

    DeviceTrashItem? copyOf(String path, {bool edited = false}) => deviceTrash
        .items()
        .where(
          (c) =>
              c.path == path &&
              c.at >= at - skew.inMilliseconds &&
              (!edited || c.changed),
        )
        .firstOrNull;
    final fromServer = <String>[];
    for (final path in remote) {
      // Edited here before the delete: these bytes are the latest version and
      // win over the server's older one, which is left to expire.
      final edited = copyOf(path, edited: true);
      if (edited == null) {
        fromServer.add(path);
        continue;
      }
      try {
        _dropUnsentDelete(path);
        results.add(deviceResult(path, edited));
      } on FileSystemException catch (error) {
        results.add({
          'path': path,
          'result': 'failed',
          'message': error.message,
        });
      }
    }
    if (fromServer.isEmpty) return {'results': results};
    ServerTrash? listed;
    String? unreachable;
    final api = trashApi;
    if (server && api != null) {
      try {
        listed = await api.listTrash();
        deviceTrash.learned(listed);
      } on Exception {
        unreachable = trashUnreachable;
      }
    } else {
      unreachable = trashUnreachable;
    }
    final since = (at - skew.inMilliseconds) ~/ 1000;
    final ids = <String, String>{};
    for (final path in fromServer) {
      final items =
          (listed?.items ?? const <ServerTrashItem>[])
              .where(
                (i) => i.path == names.cloudPath(path) && i.deleted >= since,
              )
              .toList()
            ..sort((a, b) => b.deleted.compareTo(a.deleted));
      if (items.isNotEmpty) ids[path] = items.first.id;
    }
    // One request for all of them (spec #44 S6).
    final restored = <String, TrashRestoreResult>{};
    if (ids.isNotEmpty) {
      try {
        for (final result in await api!.restoreTrashMany(ids.values.toList())) {
          restored[result.id] = result;
        }
      } on Exception catch (error) {
        unreachable = error is CloudFailure ? error.message : trashUnreachable;
      }
    }
    for (final path in fromServer) {
      try {
        final id = ids[path];
        final result = id == null ? null : restored[id];
        if (result?.restored case final done?) {
          _restoredFromServer(names.localPath(done.path));
          results.add({
            'path': path,
            'result': done.renamed ? 'renamed' : 'restored',
            'to': done.path,
          });
          continue;
        }
        if (result?.error case final error?) {
          results.add({'path': path, 'result': 'failed', 'message': error});
          continue;
        }
        final copy = copyOf(path);
        if (copy != null) {
          _dropUnsentDelete(path);
          results.add(deviceResult(path, copy));
          continue;
        }
        final queued = operation(path, 'delete');
        if (queued != null && listed != null) {
          // Sent, but the server never deleted it: the item is still there.
          finish(queued);
          final entry = manifest.entries[path];
          if (entry != null && entry.status.startsWith('delete')) {
            entry.status = 'current local';
            manifest.save();
          }
          markDirty(path, descendants: true);
          results.add({'path': path, 'result': 'restored', 'to': path});
          continue;
        }
        results.add({
          'path': path,
          'result': 'failed',
          'message': unreachable ?? 'No longer in Trash',
        });
      } on Exception catch (error) {
        results.add({
          'path': path,
          'result': 'failed',
          'message': error is FileSystemException ? error.message : '$error',
        });
      }
    }
    return {'results': results};
  }

  /// A delete still recorded for [path] that a device-copy restore answers.
  void _dropUnsentDelete(String path) {
    final queued = operation(path, 'delete');
    if (queued != null) finish(queued);
  }

  /// Downloads (or snapshots) [path] into a private working copy, or hands
  /// out again the unchanged copy of the same version that already exists
  /// (one per file and version, decision #184). Pass [providerTracked] only
  /// when this hand-out goes through the documents provider's tracked open
  /// path; only a copy every hand-out of which did is cleared automatically
  /// while unchanged.
  Future<String> openFile(String path, {bool providerTracked = false}) async {
    requireStorageReady();
    final entry = manifest.entries[path]!;
    if (entry.kind != ItemKind.file) {
      throw const CloudFailure('Choose a regular file.');
    }
    if (!entry.expectedPresent) {
      final reuse = reusableWorkingCopy(path);
      if (reuse != null) {
        workingCopyOpened(reuse, providerTracked: providerTracked);
        return reuse.staged!;
      }
    }
    // An open of a Cloud-only file under Wi-Fi only on mobile data waits
    // for Wi-Fi and downloads nothing (#108 Q4).
    if (!entry.expectedPresent && transfersHeld) throw const TransfersHeld();
    final copy = artifacts.reserve(path, 'working');
    String hash;
    if (entry.expectedPresent) {
      hash = tree.snapshotFile(path, copy, purpose: 'open');
      // A Local file: the snapshot shows whether an unchanged copy of these
      // exact bytes is already out; then the fresh one is released again.
      final reuse = reusableWorkingCopy(path);
      if (reuse != null && reuse.hash == hash) {
        artifacts.complete(copy, hash: hash, etag: entry.etag);
        ReleaseOutcome outcome;
        try {
          outcome = releases.release(artifacts.record(copy)!, hash);
        } on FileSystemException {
          outcome = ReleaseOutcome.busy;
        }
        if (outcome == ReleaseOutcome.released) {
          workingCopyOpened(reuse, providerTracked: providerTracked);
          return reuse.staged!;
        }
      }
    } else {
      if (entry.etag == null) {
        throw const CloudFailure('No remote version is available.');
      }
      await cloud.download(path, copy, etag: entry.etag!);
      hash = await fileHash(copy, 'open');
    }
    final op = Operation(
      uniqueId(),
      'working',
      path,
      expectedEtag: entry.etag,
      staged: tree.durablePath(copy),
      hash: hash,
    )..data['handout'] = providerTracked ? 'provider' : 'untracked';
    manifest.operations[op.id] = op;
    markDirty(path);
    artifacts.complete(copy, hash: hash, etag: entry.etag);
    entry.workingCopy = tree.durablePath(copy);
    // Opening is not editing (decision #183): the row keeps its status until
    // the copy is changed (Evictions pins it then).
    workingCopyOpened(op, providerTracked: providerTracked);
    return tree.durablePath(copy);
  }

  /// An unchanged working copy of [path]'s current version, to hand out
  /// again instead of a new copy.
  Operation? reusableWorkingCopy(String path) {
    final etag = manifest.entries[path]?.etag;
    if (etag == null) return null;
    return manifest
        .operationsAt(path)
        .where(
          (op) =>
              op.kind == 'working' &&
              op.staged != null &&
              op.expectedEtag == etag &&
              op.data['reclaiming'] != true &&
              // A copy confirmed for Finish editing is never handed out again.
              !editing.requests.any(
                (r) => editing.ids(r, 'sessions').contains(op.id),
              ) &&
              !artifacts.workingEdited(op),
        )
        .firstOrNull;
  }

  /// Wall clock for the persisted hand-out time (test seam).
  DateTime Function() wallClock = DateTime.now;

  /// How long an unchanged, provider-tracked working copy is kept after its
  /// last hand-out before a pass may release it (decision #184): an app may
  /// read and close a file and save it later, which no guard can see.
  Duration workingCopyGrace = const Duration(hours: 12);

  /// [work] was just handed to an app (an Open, or a provider open). The
  /// time is persisted; one hand-out outside the provider makes the copy
  /// untracked for good (decision #184).
  void workingCopyOpened(Operation work, {required bool providerTracked}) {
    work.data['handedAt'] = wallClock().millisecondsSinceEpoch;
    if (!providerTracked) work.data['handout'] = 'untracked';
    manifest.save();
  }

  List<Map<String, Object?>> workingCopies(String path) {
    return [
      for (final op
          in manifest
              .operationsAt(path)
              .where((o) => o.kind == 'working' && o.staged != null))
        () {
          final result = <String, Object?>{
            'id': op.id,
            'path': op.staged,
            'size': null,
            // Only an edited copy reads as Editing and offers Finish editing
            // (decision #183); an unchanged one is reclaimed by a later pass.
            'edited': artifacts.workingEdited(op),
          };
          try {
            final file = artifacts.resolve(op.staged!);
            final owned = artifacts.record(file);
            if (owned?.data['directoryIdentity'] ==
                tree.native.identity(tree.stageFd)) {
              final preview = artifacts.native.preview(
                tree.stageFd,
                p.basename(file.path),
              );
              result['size'] = preview.size;
              result['modified'] = DateTime.fromMillisecondsSinceEpoch(
                preview.modifiedMs,
              ).toLocal().toString();
              result['preview'] = {
                ...preview.toJson(),
                'directoryIdentity': tree.native.identity(tree.stageFd),
              };
            }
          } on FileSystemException {
            // Keep the location visible even if the owned file is unavailable.
          }
          return result;
        }(),
    ];
  }

  int _artifactIndexVersion = -1;
  final Map<String, List<Operation>> _artifactIndex = {};

  /// Owned staging records attributed to [path], indexed once per change.
  List<Operation> _artifactsFor(String path) {
    if (_artifactIndexVersion != manifest.operationsVersion) {
      _artifactIndex.clear();
      // A device-trash copy (spec #44) is no row's copy or staging file.
      final trash = deviceTrash.held;
      for (final record in artifacts.records) {
        if (trash.contains(record.staged)) continue;
        _artifactIndex
            .putIfAbsent(
              (record.data['entryPath'] ?? record.path) as String,
              () => [],
            )
            .add(record);
      }
      _artifactIndexVersion = manifest.operationsVersion;
    }
    return _artifactIndex[path] ?? const [];
  }

  Map<String, Object?> localArtifacts(String path) {
    var count = 0;
    var bytes = 0;
    var uncertain = false;
    final files = <Map<String, Object?>>[];
    final kinds = <String, int>{};
    final inodes = <String>{};
    for (final record in _artifactsFor(path)) {
      try {
        final info = artifacts.native.info(
          tree.stageFd,
          record.data['name'] as String,
        );
        var kind = artifactKind(record.data['role'] as String?);
        if (record.data['role'] == 'working') {
          // An unchanged working copy is a downloaded copy (decision #183).
          final session = manifest
              .operationsAt(path)
              .where((o) => o.kind == 'working' && o.staged == record.staged)
              .firstOrNull;
          if (session != null && !artifacts.workingEdited(session)) {
            kind = 'download';
          }
        }
        count++;
        kinds[kind] = (kinds[kind] ?? 0) + 1;
        // Hard-linked names (download-* installs) share one inode's bytes.
        if (inodes.add(info.identity)) bytes += info.size;
        files.add({'path': record.staged, 'size': info.size, 'kind': kind});
        if (info.identity != record.data['identity']) uncertain = true;
      } on FileSystemException {
        uncertain = true;
      }
    }
    return {
      'count': count,
      'bytes': bytes,
      'uncertain': uncertain,
      'files': files,
      'kinds': kinds,
    };
  }

  Future<bool> canRecoverLocalVariants(String path) async {
    final entry = manifest.entries[path];
    if (entry == null ||
        entry.conflict == null ||
        entry.kind != ItemKind.file) {
      return false;
    }
    if (entry.expectedPresent &&
        entry.localHash != null &&
        entry.localHash != entry.baselineHash) {
      return true;
    }
    for (final op
        in manifest
            .operationsAt(path)
            .where((o) => o.kind == 'working' || o.kind == 'retained')) {
      if (op.staged == null || op.hash == null) {
        continue;
      }
      try {
        final file = artifacts.resolve(op.staged!);
        if (file.existsSync() &&
            await fileHash(file, 'conflict-presentation') != op.hash) {
          return true;
        }
      } on FileSystemException {
        /* Keep the conflict and recovery bytes intact. */
      }
    }
    return false;
  }

  Future<void> keepBoth(String path) async {
    requireStorageReady();
    final entry = manifest.entries[path]!;
    final variants = <File>[];
    String? rootHash;
    if (entry.expectedPresent) {
      final copy = artifacts.reserve(path, 'conflict-local');
      rootHash = tree.snapshotFile(path, copy, purpose: 'conflict');
      artifacts.complete(copy, hash: rootHash);
      if (rootHash != entry.baselineHash) variants.add(copy);
    }
    final acknowledged = <Operation, String>{};
    for (final op
        in manifest.operations.values
            .where(
              (o) =>
                  o.path == path &&
                  (o.kind == 'working' || o.kind == 'retained'),
            )
            .toList()) {
      if (op.staged == null ||
          op.hash == null ||
          !artifacts.resolve(op.staged!).existsSync()) {
        continue;
      }
      final source = artifacts.resolve(op.staged!);
      final hash = await fileHash(source, 'conflict');
      if (hash == op.hash) continue;
      final copy = artifacts.reserve(path, 'conflict-edited-copy');
      await source.copy(copy.path);
      if (await fileHash(copy, 'conflict') != hash ||
          await fileHash(source, 'conflict') != hash) {
        throw const CloudFailure(
          'Edited copy is still changing. Retry when its save finishes.',
        );
      }
      artifacts.complete(copy, hash: hash);
      variants.add(copy);
      acknowledged[op] = hash;
    }
    if (variants.isEmpty) {
      throw const CloudFailure(
        'No new local variant is available. Inspect the preserved copies before resolving this conflict.',
      );
    }
    for (final copy in variants) {
      final newPath = '$path.conflict-${uniqueId().substring(0, 8)}';
      installOwned(newPath, copy);
    }
    for (final variant in acknowledged.entries) {
      variant.key.hash = variant.value;
    }
    entry.baselineHash = rootHash;
    entry.conflict = null;
    entry.refreshRemote = true;
    entry.status = 'queued';
    manifest.save();
    markDirty(path);
  }

  void close() {
    watcher?.close();
    cloud.close();
    tree.close();
    manifest.close();
  }
}
