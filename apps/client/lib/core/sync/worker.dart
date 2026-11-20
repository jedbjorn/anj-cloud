import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../gateway/certificate_renewal.dart';
import '../gateway/cloud_api.dart';
import '../gateway/dav_api.dart';
import '../gateway/fetch_api.dart';
import '../gateway/admin_api.dart';
import '../gateway/releases_api.dart';
import 'documents_ops.dart';
import 'editor_diagnostic.dart';
import 'entry_projection.dart';
import '../ports/documents_filesystem.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../gateway/sharing.dart';
import '../local/root_identity.dart';
import '../local/root_tree.dart';
import '../local/staging_location.dart';
import '../ports/phone_folders.dart';
import '../ports/root_filesystem.dart';
import '../ports/root_location.dart';
import 'phone_folder_move.dart';
import '../../platform/adapters.dart';
import '../update/release.dart';
import 'sync_activity.dart';
import 'cloud_names.dart';
import 'sync_engine.dart';
import 'sync_schedule.dart';

/// Status shown while a legacy root identity is checked against file content.
const rootCheckMessage = 'Checking folder after update…';

/// All filesystem scans, SQLite writes and sync commands are serialized here.
/// UI plugin operations (keyring, dialogs and desktop open) stay on the UI isolate.
Future<void> syncWorker(Map<String, Object?> initial) async {
  final output = initial['output'] as SendPort;
  final input = ReceivePort();
  // Android's phone folders (spec #52): the root filesystem maps Music,
  // Videos and Documents into shared storage.
  final phone = PhoneFolderLayout.active = PhoneFolderLayout.fromJson(
    initial['phoneFolders'],
  );
  final native = platformAdapters().rootFilesystem(
    initial['nativeLibrary'] as String?,
  );
  final manifest = Manifest(Directory(initial['profile'] as String));
  final root = manifest.setting('root');
  final staging = manifest.setting('staging');
  if (root == null || staging == null) {
    output.send({'event': 'fatal', 'message': 'Choose a root first.'});
    manifest.close();
    input.close();
    return;
  }
  RootTree? tree;
  String? refusal;
  try {
    final profilePath = Directory(initial['profile'] as String)
        .resolveSymbolicLinksSync();
    final rootPath = Directory(root).resolveSymbolicLinksSync();
    if (p.equals(rootPath, profilePath) ||
        p.isWithin(rootPath, profilePath) ||
        p.isWithin(profilePath, rootPath)) {
      throw const FileSystemException(
        'The synchronized root overlaps private profile state.',
      );
    }
    // The platform's location rules on where the root really is (symlinks
    // resolved), before anything beneath it is opened (macOS: a protected,
    // provider, snapshot, read-only or non-APFS location, as a profile from
    // an earlier build, or a symlink swapped in since, may hold), and again
    // on the opened root's own volume. Tests pass `rootLocation`.
    final policy =
        initial['rootLocation'] as RootLocationPolicy? ??
        platformAdapters().rootLocationPolicy();
    refusal = policy.refuseRoot(rootPath);
    if (refusal == null) {
      // Spec #34 P3.2: pre-P3 sibling staging with no pending work moves
      // into the profile (or its dot-named sibling) before the root is
      // opened. A failed move changes nothing: the current staging stays in
      // use. Linux only in this delivery: elsewhere the sibling stays
      // untouched.
      var settled = staging;
      if (initial['settleStaging'] == true) {
        try {
          settled = settleStaging(manifest, profilePath, native);
        } on Object {
          settled = manifest.setting('staging') ?? staging;
        }
      }
      // The one-time move of an existing install's private Music, Videos
      // and Documents into the phone's folders, before anything syncs
      // (spec #52 Moving an Existing Install). Resumes after a crash.
      if (phone != null &&
          !phone.paused &&
          !runPhoneFolderMove(manifest, native, rootPath, phone, output.send)) {
        // Unfinished: the private copies are still there, so the phone
        // folders stay paused (nothing is inferred from a half-moved folder).
        (native as PhoneFolderRouting).setPaused(true);
      }
      tree = RootTree(Directory(root), Directory(settled), native);
      refusal = policy.refuseRoot(rootPath, fd: tree.fd);
    }
    // Stable across reboot (fsid-based); a pre-fix dev:ino value is migrated
    // only on positive evidence (root_identity.dart), otherwise paused.
    // A legacy profile may need file reads for evidence: say so first, so a
    // long check is visible and not mistaken for a hung start.
    if (refusal == null) {
      final accepted = acceptRoot(
        manifest,
        tree!,
        onLongCheck: () =>
            output.send({'event': 'checking', 'message': rootCheckMessage}),
      );
      if (accepted.outcome == RootOutcome.refused) {
        throw const FileSystemException('Root directory identity changed.');
      }
    }
  } catch (_) {
    tree?.close();
    manifest.close();
    input.close();
    output.send({
      'event': 'fatal',
      'message': 'Paused: root unavailable or replaced. No deletions inferred.',
    });
    return;
  }
  if (refusal != null) {
    tree?.close();
    manifest.close();
    input.close();
    output.send({
      'event': 'fatal',
      'message': 'Paused: $refusal No files were changed.',
    });
    return;
  }
  CloudApi cloud = const DisconnectedCloud();
  RenewableCloud? renewable;
  CertificateRenewal? renewal;
  if (initial['privateKey'] != null &&
      manifest.setting('certificate') != null &&
      manifest.setting('accountUid') != null) {
    final pickup = CertificatePickup(manifest, initial['privateKey'] as String);
    // The shipped gateway serializes every mutation and checks a fresh
    // concrete collection ETag. Qualified against the real two-profile fixture.
    DavCloud connect(String certificate) => DavCloud(
      Uri.parse(manifest.setting('server')!),
      pickup.context(certificate),
      folderDeletionQualified: true,
    );
    final connection = RenewableCloud(
      connect(manifest.setting('certificate')!),
    );
    renewable = connection;
    cloud = connection;
    // Reissued certificates arrive over this device's existing mTLS identity
    // (spec #19); the sync engine switches to the renewed one in place.
    renewal = CertificateRenewal(
      (stillWanted) => pickup.run(stillWanted: stillWanted),
      expires:
          DateTime.tryParse(manifest.setting('certificateExpires') ?? '') ??
          DateTime.now(),
      onRenewed: (result) => connection.replace(connect(result.certificate)),
      onStatus: (warning, expires) => output.send({
        'event': 'certificate',
        'warning': warning,
        'expires': expires.toUtc().toIso8601String(),
      }),
    );
  }
  // An unpaired worker makes no requests (and its engine recognises the
  // disconnected cloud); a paired one is gated for Pause.
  final gate = cloud is DisconnectedCloud ? null : PausableCloud(cloud);
  final activity = SyncActivity();
  // Every request leaves with cloud names (spec #49, decision #199); the
  // activity it records stays under local paths, as the rows are.
  final names = CloudNames();
  final engine = SyncEngine(
    manifest,
    tree!,
    gate == null ? cloud : ActivityCloud(NamedCloud(gate, names), activity),
    activity: activity,
    names: names,
  );
  // Local changes arrive as inotify events; without them (or on a network
  // or FUSE root) every pass stat-scans the root, with a status note.
  await engine.startWatching();
  final metrics = Platform.environment['ANJ_CLIENT_METRICS'];
  final loop = WorkerLoop(
    engine,
    output.send,
    metrics: metrics == null || metrics.isEmpty ? null : File(metrics),
    gate: gate,
    unpaired: cloud is DisconnectedCloud,
    // The update feed over the device certificate (spec #28 G1, spec #37);
    // not file sync, so neither the pause gate nor sync activity applies.
    releases: cloud is ReleaseTransport ? cloud as ReleaseTransport : null,
    // Media fetch job routes (spec #42): not file sync either.
    fetch: cloud is FetchTransport ? cloud as FetchTransport : null,
    defaultNetworkPolicy: initial['networkPolicy'] as String?,
    pickupIfDue: renewal?.runIfDue,
    foregroundReads: initial['androidForeground'] == true && renewable != null
        ? () => renewable!.current as ForegroundReads
        : null,
  );
  output.send({'event': 'ready', 'input': input.sendPort});
  renewal?.start();
  try {
    await loop.run(input);
  } finally {
    renewal?.stop();
  }
}

/// Runs or resumes the one-time move of the private Music, Videos and
/// Documents into the phone's folders (spec #52), at start or when All files
/// access arrives while the app runs. False when it could not finish: the
/// private copies stay, the caller keeps the folders paused, and the move
/// resumes at the next start or grant.
bool runPhoneFolderMove(
  Manifest manifest,
  RootFilesystem native,
  String privateRoot,
  PhoneFolderLayout layout,
  void Function(Object?) send,
) {
  final move = PhoneFolderMove(
    manifest,
    native,
    privateRoot: privateRoot,
    layout: layout,
    onProgress: (message) => send({'event': 'checking', 'message': message}),
  );
  try {
    move.run();
    send({'event': 'phoneFolders', 'problem': null});
    return true;
  } on FileSystemException catch (error) {
    send({
      'event': 'phoneFolders',
      'problem':
          "Music, Videos and Documents could not be moved to your phone's "
          'folders yet (${error.message}). They are paused; nothing was '
          'deleted, and the move continues at the next start.',
    });
    return false;
  } finally {
    if (move.placed.isNotEmpty) {
      send({'event': 'mediaScan', 'paths': move.placed});
    }
  }
}

/// A one-shot [Timer] that never fires before [delay] has passed. The VM
/// timer truncates a [Duration] to whole milliseconds and then waits at
/// least that many, so a computed remainder such as 199.6 ms would fire
/// after 199 ms: before the deadline it stands for. Rounding up keeps the
/// worker's "at least" promises (a pass [WorkerLoop.interval] after the
/// previous one ends, an activity event no sooner than its spacing).
Timer _timerAtLeast(Duration delay, void Function() callback) {
  final micros = delay.inMicroseconds;
  return Timer(
    Duration(milliseconds: micros <= 0 ? 0 : (micros + 999) ~/ 1000),
    callback,
  );
}

/// Serializes passes and commands on the worker isolate. A pass starts
/// [interval] after the previous one finishes (never back to back), or
/// earlier when watched local work falls due (a settled change, a
/// confirmation hash, an audit), but never sooner than [minGap] after the
/// previous pass. Queued commands run at each candidate-path boundary
/// instead of waiting for the whole pass. State is sent to the UI only when
/// it changed.
///
/// Every pass records local state; [schedule] decides when a pass also
/// lists the cloud. Pause (persisted in the manifest) stops passes and
/// closes [gate]; a read-only scan every [pausedInterval] keeps counting
/// local changes. Stop is honoured at the next path boundary; a transfer
/// still running after [abortGrace] is abandoned by closing the cloud
/// client (its durable intent is retried by the next start).
class WorkerLoop {
  /// The line under "Reconnecting" from start until the first pass ends.
  static const startingMessage =
      'Showing files from the last sync. Checking for changes.';

  /// Until the first pass ends the server has not been heard from: the
  /// stored library shows as Reconnecting.
  late bool _connecting = !unpaired;

  WorkerLoop(
    this.engine,
    this.send, {
    this.interval = const Duration(seconds: 2),
    this.minGap = const Duration(milliseconds: 250),
    this.metrics,
    RemoteSchedule? schedule,
    this.gate,
    this.unpaired = false,
    this.pausedInterval = const Duration(seconds: 30),
    this.abortGrace = const Duration(seconds: 5),
    this.activityInterval = const Duration(milliseconds: 500),
    this.releases,
    this.fetch,
    this.defaultNetworkPolicy,
    this.pickupIfDue,
    this.joinedListingAge = const Duration(seconds: 60),
    this.foregroundReads,
  }) : schedule = schedule ?? RemoteSchedule() {
    engine.onLocalChange = () {
      if (!_inPass && !_paused) _schedule(interval);
    };
    engine.activity.onChanged = _activityChanged;
    if (_androidForeground) {
      engine.yieldToForeground = _foregroundCheckpoint;
      engine.duringDiscovery = _duringDiscovery;
      engine.discoverSnapshot = _discoverSnapshot;
    }
  }
  final SyncEngine engine;
  final void Function(Object?) send;
  final Duration interval;
  final Duration minGap;
  final RemoteSchedule schedule;
  final PausableCloud? gate;
  final bool unpaired;
  final Duration pausedInterval;
  final Duration abortGrace;

  /// The update feed; null while unpaired.
  final ReleaseTransport? releases;
  bool _downloadingRelease = false;

  /// The media fetch job routes (spec #42); null while unpaired.
  final FetchTransport? fetch;

  /// The running download's request and its cancel signal.
  final _releaseCancels = <Object?, Completer<void>>{};
  final Stopwatch _sinceEnd = Stopwatch()..start();
  bool _inPass = false;

  /// Minimum spacing of `activity` events while files keep changing; an
  /// empty set (nothing syncing) is sent at once so indicators clear promptly.
  final Duration activityInterval;

  /// Opt-in JSON-lines file receiving one record per pass.
  final File? metrics;
  final Queue<Map> _queue = Queue();

  /// Returns the active transport instance, which stays the same until the
  /// connection is replaced, such as when the device certificate renews.
  final ForegroundReads Function()? foregroundReads;
  bool get _androidForeground => foregroundReads != null;
  SyncStatus _connection = SyncStatus.checkingServer;
  String? _connectionMessage;
  bool _checkingChanges = true;
  int _connectionGeneration = 0;
  int _passGeneration = 0;
  late bool _verifyPassWanted = _androidForeground;
  bool _listPassWanted = false;
  bool _passWillVerify = false;
  bool _discovering = false;
  bool? _online;
  int? _networkRoute;
  Map? _heldOpen;
  Future<void>? _selectedRead;

  /// The documents provider's commands (spec #28 A5; Android only sends
  /// them).
  late final DocumentsOps documents = DocumentsOps(
    engine,
    paused: () => _paused,
    checkRemote: _androidForeground ? _checkSelectedFile : null,
    checkTransferPolicy: _androidForeground ? _checkOpenPolicy : null,
    downloadSelected: _androidForeground ? _downloadSelectedFile : null,
  );
  Completer<void>? _signal;
  Timer? _deadline;
  bool _passWanted = true;
  bool _stopping = false;
  bool _paused = false;
  Timer? _abort;
  String? _lastState;
  String? _lastStatus;
  Timer? _activityTimer;
  final Stopwatch _sinceActivity = Stopwatch();
  List<String> _lastActivity = const [];

  /// Number of activity events sent (test seam).
  int activityEmitted = 0;

  /// The platform's network setting when the profile has none: 'wifi'
  /// ("Wi-Fi only", the Android default, decision #108 Q4) or null (no
  /// setting: Linux). The profile's 'network' setting ('wifi' or 'any')
  /// overrides it once the user chooses.
  final String? defaultNetworkPolicy;
  String? _networkPolicy;

  /// Certificate pickup when overdue (spec #19), awaited by background
  /// runs, paused or not: pickup is the one request Pause allows (#53).
  final Future<void> Function()? pickupIfDue;

  /// Whether the device is on Wi-Fi (or Ethernet), as the platform last
  /// reported; null until the first report. Under "Wi-Fi only" an unknown
  /// network holds bytes, so nothing moves on mobile data before the first
  /// report arrives.
  bool? _onWifi;

  /// Passes started since the loop began; background runs wait for a pass
  /// that started after they were asked for.
  int _passSerial = 0;

  /// Pending background runs: answered once a pass with a serial above
  /// [after] ends. [listedSince], set for a run that joined a pass already
  /// under way, is the oldest listing it accepts; an older one gets one
  /// follow-up listing pass first.
  final List<({Object? request, int after, Duration? listedSince})>
  _background = [];

  /// The pass a background command arrived during, if any, and when.
  final Expando<int> _arrivedDuring = Expando();
  final Expando<Duration> _arrivedAt = Expando();

  /// How old a joined pass's listing may be, measured from the request: a
  /// run joining a long app-open pass must not answer with a listing made
  /// minutes before it asked.
  final Duration joinedListingAge;

  /// Full verifications counted when the current pass began, and the last
  /// pass that was a full verification and listed the cloud.
  int _passVerifications = 0;
  bool _passLists = false;
  int? _verifiedSerial;

  /// The running pass is already a full verification (it began one).
  bool get _passVerifies =>
      _inPass &&
      _passLists &&
      _passGeneration == _connectionGeneration &&
      (_passWillVerify || engine.fullVerifications > _passVerifications);

  String? get networkPolicy => _networkPolicy;

  bool get paused => _paused;

  /// True once a stop abandoned an in-flight transfer (test seam).
  bool abandoned = false;

  /// Number of state events sent (test seam).
  int emitted = 0;

  RootTree get tree => engine.tree;

  void _wake() {
    final signal = _signal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Stop is acted on as soon as it arrives, not when its turn in the queue
  /// comes: the running pass ends at its next path boundary.
  void _requestStop() {
    if (_stopping) return;
    _stopping = true;
    _deadline?.cancel();
    engine.stopRequested = true;
    _abort = Timer(abortGrace, () {
      abandoned = true;
      engine.cloud.close();
    });
  }

  void _setPaused(bool value) {
    _paused = value;
    gate?.paused = value;
  }

  void _restartForegroundCheck() {
    _connectionGeneration++;
    if (_inPass) engine.stopRequested = true;
    _connection = SyncStatus.checkingServer;
    _connectionMessage = null;
    _checkingChanges = true;
  }

  void _foregroundReadFailed(Object error) {
    final denied =
        error is CloudFailure && (error.status == 401 || error.status == 403);
    _connection = denied ? SyncStatus.accessDenied : SyncStatus.offline;
    _connectionMessage = denied ? error.toString() : unreachableMessage(error);
    _emitForegroundStatus();
  }

  SyncStatus get _status {
    if (_androidForeground && !_paused) {
      if (_connection == SyncStatus.accessDenied ||
          _connection == SyncStatus.offline) {
        return _connection;
      }
      if (_heldOpen != null) return SyncStatus.waiting;
      if (_connection == SyncStatus.checkingServer) return _connection;
    }
    final status = deriveStatus(
      paused: _paused,
      offline: !_androidForeground && (schedule.offline || _connecting),
      unpaired: unpaired,
      message: engine.message,
      entries: engine.manifest.entries.values,
      operations: engine.manifest.operations.values,
    );
    if (_androidForeground &&
        _checkingChanges &&
        (status == SyncStatus.syncing || status == SyncStatus.upToDate)) {
      return SyncStatus.checkingChanges;
    }
    return status;
  }

  String _statusMessage(SyncStatus status) => _androidForeground && !_paused
      ? _connectionMessage ??
            (status == SyncStatus.checkingServer
                ? startingMessage
                : status == SyncStatus.checkingChanges
                ? 'Checking the library.'
                : engine.message)
      : engine.message;

  Map<String, Object?> _statusFields() {
    final status = _status;
    return {
      'status': status.name,
      'message': _statusMessage(status),
      'paused': _paused,
      'transfersHeld': engine.transfersHeld,
      'networkPolicy': _networkPolicy,
    };
  }

  void _emitForegroundStatus() {
    final fields = _statusFields();
    final encoded = jsonEncode(fields);
    if (encoded == _lastStatus) return;
    _lastStatus = encoded;
    // A lightweight update changes what the controller displays, even if
    // the next full state matches one it received before this update.
    _lastState = null;
    send({'event': 'foregroundStatus', ...fields});
  }

  void _foregroundReadSucceeded() {
    if (_connection != SyncStatus.checkingChanges || _passVerifies) {
      _checkingChanges = true;
    }
    _connection = SyncStatus.checkingChanges;
    _connectionMessage = null;
    _emitForegroundStatus();
  }

  bool _foregroundResultCurrent(int generation) =>
      !_paused &&
      !_stopping &&
      generation == _connectionGeneration &&
      !_queue.any(
        (command) => switch (command['action']) {
          'pause' => true,
          'network' =>
            (command['online'] is bool && command['online'] != _online) ||
                (command['route'] is int &&
                    command['route'] != _networkRoute) ||
                command['wifi'] != _onWifi,
          _ => false,
        },
      );

  bool _passCurrent() =>
      !_paused && !_stopping && _passGeneration == _connectionGeneration;

  Future<List<RemoteItem>> _discoverSnapshot() async {
    final reads = foregroundReads!();
    reads.guardListing(
      stillWanted: _passCurrent,
      selectedRead: () => _selectedRead,
    );
    try {
      final items = await _duringDiscovery(engine.cloud.snapshot());
      // The certificate may have changed between the early probe and listing.
      if (_connection == SyncStatus.checkingServer &&
          _passCurrent() &&
          identical(reads, foregroundReads!())) {
        _foregroundReadSucceeded();
      }
      return items;
    } finally {
      reads.clearCheckedRoot();
    }
  }

  void _openNotice(String? message) =>
      send({'event': 'openNotice', 'message': message});

  bool _isForegroundCommand(Map command) => switch (command['action']) {
    'visible' ||
    'foregroundLeft' ||
    'pause' ||
    'resume' ||
    'network' ||
    'networkPolicy' ||
    'phoneFolders' ||
    'open' => true,
    'documents' => command['op'] == 'open' || command['op'] == 'closed',
    _ => false,
  };

  /// Discovery has no in-flight reconciliation write. Service foreground
  /// commands while waiting for its response, then give ownership back to
  /// the pass before it interprets the snapshot.
  Future<T> _duringDiscovery<T>(Future<T> pending) async {
    var finished = false;
    late T result;
    Object? failure;
    StackTrace? trace;
    final completion = pending
        .then(
          (value) {
            result = value;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
          },
        )
        .whenComplete(() {
          finished = true;
          _wake();
        });
    try {
      while (!_stopping) {
        await _foregroundCheckpoint();
        if (finished || _stopping) break;
        final wake = _signal = Completer<void>();
        await wake.future;
        _signal = null;
      }
    } finally {
      // An enumeration can still be using the root and watch descriptors.
      await completion;
    }
    if (failure case final error?) Error.throwWithStackTrace(error, trace!);
    return result;
  }

  Future<void> _foregroundCheckpoint() async {
    await Future<void>.delayed(Duration.zero);
    while (!_stopping) {
      final command = _queue.where(_isForegroundCommand).firstOrNull;
      if (command == null) return;
      _queue.remove(command);
      await _handleQueued(command);
    }
  }

  void _checkOpenPolicy() {
    var wifi = _onWifi;
    var policy = _networkPolicy;
    var paused = _paused || _stopping;
    for (final command in _queue) {
      switch (command['action']) {
        case 'pause':
          paused = true;
        case 'network':
          wifi = command['wifi'] == true;
        case 'networkPolicy':
          policy = command['value'] as String?;
      }
    }
    if (paused) {
      throw const CloudFailure('Resume sync to download this file.');
    }
    if (policy == 'wifi' && wifi != true) throw const TransfersHeld();
  }

  Future<RemoteItem> _checkSelectedFile(String path, String etag) async {
    if (engine.phoneFolderPaused(path) ||
        (_phonePaused == true && inPhoneFolder(path))) {
      // A new grant or loss of shared storage is applied at the pass boundary.
      throw const CloudFailure(
        'Phone storage is unavailable. Check All files access.',
      );
    }
    final name = engine.names.cloudPath(path);
    return _readSelected((reads, current) async {
      try {
        final item = await reads.checkFile(name, etag);
        _checkOpenPolicy();
        if (current()) _foregroundReadSucceeded();
        return item;
      } on CloudFailure catch (error) {
        switch (error.status) {
          case 404:
            throw const CloudFailure(
              'This file is no longer available.',
              status: 404,
            );
          case 412:
            throw const CloudFailure(
              'This file changed on the server. Try again after the library refreshes.',
              status: 412,
            );
          default:
            rethrow;
        }
      }
    });
  }

  Future<void> _downloadSelectedFile(
    String path,
    File target, {
    required String etag,
  }) =>
      _readSelected((_, _) => engine.cloud.download(path, target, etag: etag));

  Future<T> _readSelected<T>(
    Future<T> Function(ForegroundReads, bool Function()) read,
  ) async {
    final reads = foregroundReads!();
    final generation = _connectionGeneration;
    // The worker queues network and pause commands while the read is pending.
    bool current() =>
        identical(reads, foregroundReads!()) &&
        _foregroundResultCurrent(generation);
    try {
      return await read(reads, current);
    } catch (error) {
      if ((error is SocketException ||
              error is HttpException ||
              error is TlsException ||
              error is TimeoutException ||
              error is TransferInterrupted) &&
          current()) {
        // A discovery reply may still be in flight on this connection.
        // Retire that pass and let the normal retry schedule obtain a fresh one.
        _connectionGeneration++;
        if (_inPass) engine.stopRequested = true;
        if (!schedule.offline || schedule.untilDue == Duration.zero) {
          schedule.completed(listed: false, failed: true);
        }
        _foregroundReadFailed(error);
        if (!_inPass) _schedule(interval);
      }
      rethrow;
    }
  }

  Future<void> _openForegroundFile(Map command) async {
    final path = command['path'] as String;
    final name = p.posix.basename(path);
    _heldOpen = null;
    _openNotice('Opening $name…');
    try {
      final copy = await engine.openFile(
        path,
        providerTracked: command['providerTracked'] == true,
        checkRemote: _checkSelectedFile,
        checkTransferPolicy: _checkOpenPolicy,
        downloadSelected: _downloadSelectedFile,
      );
      // The provider resolves the working-copy URI from the projected rows.
      // Publish its ID before the receiver is launched.
      await emit();
      if (!_stopping &&
          !_queue.any((command) => command['action'] == 'foregroundLeft')) {
        send({'event': 'open', 'path': copy});
      }
      _openNotice(null);
    } on TransfersHeld catch (error) {
      _heldOpen = command;
      _openNotice('$name: ${error.message}');
    } catch (error) {
      _openNotice('Could not open $name. $error');
    }
  }

  /// Coalesced: at most one event per [activityInterval] while files keep
  /// changing, never per byte, and only when the set of paths changed.
  void _activityChanged() {
    if (_stopping) return;
    // O(1): this runs once per planned path as the pass retires it.
    final idle = engine.activity.isEmpty;
    final wait = activityInterval - _sinceActivity.elapsed;
    if (idle || !_sinceActivity.isRunning || wait <= Duration.zero) {
      _sendActivity();
    } else {
      _activityTimer ??= _timerAtLeast(wait, _sendActivity);
    }
  }

  void _sendActivity() {
    _activityTimer?.cancel();
    _activityTimer = null;
    final paths = engine.activity.paths.toList()..sort();
    if (_listEquals(paths, _lastActivity)) return;
    _lastActivity = paths;
    _sinceActivity
      ..reset()
      ..start();
    activityEmitted++;
    send({'event': 'activity', 'paths': paths});
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// "Wi-Fi only" off Wi-Fi holds file bytes (spec #28 R3); when the hold
  /// lifts, every waiting path is reconciled and the cloud listed at once.
  void _applyNetwork() {
    final held = _networkPolicy == 'wifi' && _onWifi != true;
    gate?.bytesHeld = held;
    if (held == engine.transfersHeld) return;
    if (held) {
      engine.transfersHeld = true;
    } else {
      engine.releaseTransfers();
      if (!_androidForeground || !_discovering || !_passLists) {
        schedule.requestNow();
        _passWanted = true;
      }
      if (_heldOpen case final held?) {
        _heldOpen = null;
        _queue.addFirst(held);
      }
    }
  }

  /// Answers background runs (Android WorkManager, spec #28 A4) whose
  /// complete pass has now run, or all of them when [paused] or [stopped].
  void _answerBackground({bool paused = false, bool stopped = false}) {
    if (_background.isEmpty) return;
    final done = paused || stopped
        ? List.of(_background)
        : _background.where((run) => _passSerial > run.after).toList();
    for (final run in done) {
      _background.remove(run);
      final since = run.listedSince;
      final listed = engine.lastListedAt;
      if (!paused &&
          !stopped &&
          !(_androidForeground && schedule.offline) &&
          since != null &&
          (listed == null || listed < since)) {
        // The joined pass verified, but its listing is too old: one
        // follow-up listing pass, without a second verification.
        _background.add((
          request: run.request,
          after: _passSerial,
          listedSince: null,
        ));
        schedule.requestNow();
        _passWanted = true;
        continue;
      }
      send({
        'event': 'backgroundDone',
        'request': run.request,
        'listed':
            !paused &&
            !stopped &&
            engine.remoteListed &&
            (!_androidForeground || _passCurrent()),
        'offline': schedule.offline,
        'paused': paused,
        'stopped': stopped,
        'waiting': engine.waitingForNetwork.length,
        'fullVerifications': engine.fullVerifications,
      });
    }
  }

  Future<void> run(Stream<dynamic> input) async {
    _setPaused(engine.manifest.setting('paused') == '1');
    _networkPolicy = engine.manifest.setting('network') ?? defaultNetworkPolicy;
    _applyNetwork();
    final subscription = input.listen((message) {
      final command = message as Map;
      if (command['action'] == 'stop') _requestStop();
      // Acted on at once, not in the queue: the connection is aborted now.
      if (command['action'] == 'releaseCancel') {
        final cancel = _releaseCancels[command['request']];
        if (cancel != null && !cancel.isCompleted) cancel.complete();
        return;
      }
      // Add files (spec #43): the copy in progress stops at its next chunk.
      if (command['action'] == 'addCancel') {
        documents.adder.cancel(command['run'] as String);
        return;
      }
      // Media fetch (spec #42): answered beside passes and the queue, so
      // the Downloader's 2 s poll neither waits for a pass nor makes the
      // loop send the whole library state.
      if (command['action'] == 'fetch') {
        // A stopping worker answers at once that it cannot send.
        unawaited(answerFetchCommand(_stopping ? null : fetch, command, send));
        return;
      }
      if (command['action'] == 'background' && _inPass) {
        _arrivedDuring[command] = _passSerial;
        _arrivedAt[command] = engine.clockNow;
      }
      _queue.add(command);
      _wake();
    });
    // The library the manifest already holds, before the first pass: that
    // pass is a full verification (decisions #130, #135) and a cloud
    // listing, a minute or more on a phone, and the app has nothing to show
    // until a state arrives.
    if (!_paused) engine.message = startingMessage;
    await emit(force: true);
    try {
      while (!_stopping) {
        if (_queue.isNotEmpty) {
          await _handleQueued(_queue.removeFirst());
        } else if (_passWanted) {
          _passWanted = false;
          await (_paused ? _observePaused() : _pass());
        } else {
          _signal = Completer<void>();
          await _signal!.future;
          _signal = null;
        }
      }
    } finally {
      _deadline?.cancel();
      _abort?.cancel();
      _activityTimer?.cancel();
      engine.activity.onChanged = null;
      _answerBackground(stopped: true);
      await subscription.cancel();
      // Closing the manifest checkpoints its WAL; intents are already durable.
      engine.close();
      send({'event': 'stopped', 'abandoned': abandoned});
    }
  }

  /// Arms the single-shot deadline for the next pass: [base] after the
  /// previous pass ended, or earlier when watched local work falls due (not
  /// while paused), but never closer than [minGap] after it.
  void _schedule(Duration base) {
    if (_stopping || _passWanted) return;
    final delay = scheduledDelay(
      base: base,
      elapsed: _sinceEnd.elapsed,
      local: _paused ? null : engine.nextLocalDeadline(),
      minGap: minGap,
      cap: _paused ? Duration.zero : wholeRootCap,
    );
    _deadline?.cancel();
    _deadline = _timerAtLeast(delay, () {
      _passWanted = true;
      _wake();
    });
  }

  /// Decision #146: after a pass whose local scan read every file (no
  /// trusted stamp, no change watcher reporting for the root), no scheduled
  /// pass of any kind (the interval, a local trigger, a cloud listing that
  /// falls due) starts sooner than min([wholeRootCapCeiling],
  /// max([interval], 9 x that scan)) after it ended, so whole-root reads
  /// take at most about a tenth of wall time. A listing due inside the cap
  /// runs with the first pass after it. The requests the app already makes
  /// set [_passWanted] and bypass it: window shown, un-pause, and user
  /// actions that ask for a pass (an explicit retry, rename, Finish editing,
  /// sharing changes). Every such pass still hashes every file (#39). Zero
  /// when no cap applies.
  Duration get wholeRootCap {
    if (!engine.lastPassReadWholeRoot) return Duration.zero;
    final nine = engine.lastLocalScan * 9;
    final cap = nine > interval ? nine : interval;
    return cap > wholeRootCapCeiling ? wholeRootCapCeiling : cap;
  }

  /// The longest [wholeRootCap] (decision #146): one stalled scan never
  /// holds local and cloud changes back longer than this.
  static const wholeRootCapCeiling = Duration(minutes: 10);

  /// The delay of the next scheduled pass: [base] after the previous pass
  /// ended, or earlier when local work is due at [local] (never closer than
  /// [minGap]), and never inside [cap]. All measured from the previous
  /// pass's end; [elapsed] has passed since. Public for tests.
  static Duration scheduledDelay({
    required Duration base,
    required Duration elapsed,
    required Duration? local,
    required Duration minGap,
    Duration cap = Duration.zero,
  }) {
    var delay = base - elapsed;
    if (local != null && local < delay) {
      delay = local < minGap - elapsed ? minGap - elapsed : local;
    }
    final floor = cap - elapsed;
    return delay < floor ? floor : delay;
  }

  /// Whether the last pass threw (it is then never treated as quiet).
  bool _lastPassFailed = false;

  /// A pause change of the phone folders waiting for the pass to end.
  bool? _phonePaused;

  /// Applies [_phonePaused]. Access back: the watcher starts again over the
  /// phone folders and one full verification follows; the top-folder rules
  /// (#150 / #163) decide about a folder that changed meanwhile.
  Future<void> _applyPhoneFolders() async {
    final paused = _phonePaused;
    final routing = engine.tree.phoneFolders;
    _phonePaused = null;
    if (paused == null || routing == null || routing.paused == paused) return;
    // Access arrived: the private folders move first (the normal update
    // flow grants access while the app runs); unfinished, they stay paused.
    if (!paused &&
        !runPhoneFolderMove(
          engine.manifest,
          engine.tree.native,
          engine.tree.root.path,
          routing.layout,
          send,
        )) {
      return;
    }
    routing.setPaused(paused);
    await engine.restartWatchingAfterPhoneFolders();
    if (!routing.paused) engine.requestFullVerification();
  }

  Future<void> _pass() async {
    _deadline?.cancel();
    _inPass = true;
    _passSerial++;
    _passVerifications = engine.fullVerifications;
    _passGeneration = _connectionGeneration;
    _passWillVerify = _verifyPassWanted;
    _verifyPassWanted = false;
    if (_listPassWanted) {
      _listPassWanted = false;
      schedule.reconnect();
    }
    final remote = schedule.policy();
    _passLists = remote == RemotePolicy.always;
    _discovering = _androidForeground;
    _lastPassFailed = true;
    final reads = _passLists ? foregroundReads?.call() : null;
    Object? probeError;
    try {
      if (reads != null) {
        await _foregroundCheckpoint();
      }
      if (reads != null && _passCurrent()) {
        bool probeCurrent() =>
            _passCurrent() && identical(reads, foregroundReads!());
        try {
          final generation = _passGeneration;
          await _duringDiscovery(
            reads
                .checkRoot(
                  stillWanted: probeCurrent,
                  selectedRead: () => _selectedRead,
                )
                .then((_) {
                  if (probeCurrent() && _foregroundResultCurrent(generation)) {
                    _foregroundReadSucceeded();
                  }
                }),
          );
          // An initial or Wi-Fi-only report may have been queued while the
          // root replied without replacing this generation.
          if (probeCurrent()) _foregroundReadSucceeded();
        } catch (error) {
          if (probeCurrent()) {
            probeError = error;
            _foregroundReadFailed(error);
          }
        }
      }
      if (!_passCurrent()) {
        engine.stopRequested = false;
      } else {
        await engine.tick(
          between: _between,
          remote: probeError == null ? remote : RemotePolicy.never,
        );
        _lastPassFailed = false;
      }
      final pass = engine.lastPass;
      if (_passCurrent()) {
        if (engine.remoteListed) {
          if (_passWillVerify ||
              engine.fullVerifications > _passVerifications) {
            _verifiedSerial = _passSerial;
          }
          if (pass != null && pass.rowsWritten > 0) schedule.mutated();
        }
        schedule.completed(
          listed: engine.remoteListed,
          failed: engine.remoteFailed || probeError != null,
        );
        if (_androidForeground) {
          if (engine.remoteError case final error?) {
            _foregroundReadFailed(error);
          } else if (pass?.completed == true && engine.remoteListed) {
            _checkingChanges = false;
          }
        }
      }
    } catch (error) {
      engine.message = 'Pending: $error';
    } finally {
      reads?.clearCheckedRoot();
      _inPass = false;
      _discovering = false;
      _connecting = false;
      if (_androidForeground &&
          !_stopping &&
          !_passCurrent() &&
          _passWillVerify) {
        _verifyPassWanted = true;
        engine.requestFullVerification();
      }
    }
    await _applyPhoneFolders();
    // A pause handled during the pass leaves its message to the paused scan.
    if (_paused) {
      _passWanted = true;
      return;
    }
    await emit();
    if (_passCurrent() || schedule.offline) _answerBackground();
    if (_background.isNotEmpty && !schedule.offline) {
      // Asked for during this pass: its completion just set the next
      // listing an idle period away, so ask again for the run's own pass.
      schedule.requestNow();
      _passWanted = true;
    }
    if (_passCurrent() || !_lastPassFailed) _record();
    _sinceEnd
      ..reset()
      ..start();
    _schedule(nextBase());
  }

  /// [interval] after a pass, except with event-driven hashing (decisions
  /// #135 macOS, #130 (3) Android) after a pass that found nothing to do: then no timer
  /// pass runs until the cloud listing is due, and local work (a reported
  /// change, a due verification) brings the next pass forward as always.
  /// After a pass that read the whole root, [wholeRootCap] (decision #146):
  /// a cloud listing due sooner waits for it. Public for tests.
  Duration nextBase() {
    final pass = engine.lastPass;
    if (engine.lastPassReadWholeRoot) return wholeRootCap;
    // A pass that threw is not quiet (PR #68 review): it did not finish.
    final quiet =
        pass != null &&
        !_lastPassFailed &&
        pass.candidates == 0 &&
        pass.rowsWritten == 0 &&
        pass.filesHashed == 0;
    if (!engine.eventDriven || !quiet) return interval;
    final due = schedule.untilDue;
    return due > interval ? due : interval;
  }

  Future<void> _observePaused() async {
    _deadline?.cancel();
    try {
      await _applyPhoneFolders();
      final changed = await engine.observePaused();
      engine.message = changed == 0
          ? 'Sync paused. Local changes are recorded and sync after you resume.'
          : 'Sync paused. $changed local ${changed == 1 ? 'change' : 'changes'} will sync after you resume.';
    } catch (error) {
      engine.message = 'Sync paused. Local folder unavailable: $error';
    }
    await emit();
    _answerBackground(paused: true);
    _sinceEnd
      ..reset()
      ..start();
    _schedule(pausedInterval);
  }

  /// Runs at each candidate-path boundary during a pass.
  Future<bool> _between() async {
    _discovering = false;
    await Future<void>.delayed(Duration.zero);
    // The server answered: the rest of the first pass is ordinary sync.
    if (!_androidForeground && _connecting && engine.remoteListed) {
      _connecting = false;
      await emit();
    }
    var handled = false;
    while (_queue.isNotEmpty && !_stopping) {
      if (await _handleQueued(_queue.removeFirst())) handled = true;
    }
    if (_stopping || _paused) engine.stopRequested = true;
    return handled;
  }

  void _record() {
    final pass = engine.lastPass;
    final file = metrics;
    if (pass == null || file == null) return;
    try {
      file.writeAsStringSync(
        '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'pass': engine.passes, 'emitted': emitted, ...pass.toJson()})}\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // Metrics are optional; never disturb synchronization.
    }
  }

  /// After a pass, sends state only when the projected library, message or
  /// readiness changed. Every command is answered ([force]), so the UI sees
  /// each outcome even when it repeats the previous one.
  Future<void> emit({bool force = false}) async {
    // The media library is told exactly which phone paths changed (spec
    // #52, AC0: path writes are not indexed by themselves).
    final scans = engine.tree.phoneFolders?.drainMediaScans() ?? const [];
    if (scans.isNotEmpty) send({'event': 'mediaScan', 'paths': scans});
    final entries = <Map<String, Object?>>[];
    for (final entry in engine.manifest.entries.values) {
      entries.add(await projectEntry(engine, entry));
    }
    final fields = _statusFields();
    final state = {
      'event': 'state',
      ...fields,
      'entries': entries,
      'operations': engine.manifest.operations.length,
      'storageReady':
          engine.manifest.setting('retention') != 'cloud' &&
          engine.rootAvailable(),
      // A Finish editing still to complete (spec #37: an update waits).
      'finishing': engine.editing.requests.isNotEmpty,
    };
    String? encoded;
    try {
      encoded = jsonEncode(state);
    } on JsonUnsupportedObjectError {
      encoded = null;
    }
    if (!force && encoded != null && encoded == _lastState) return;
    _lastState = encoded;
    _lastStatus = jsonEncode(fields);
    emitted++;
    send({...state, 'passes': engine.passes});
  }

  /// One documents provider command, answered with its own result. Changes
  /// are reconciled by a pass that starts at once; a write closed by another
  /// app uploads through the normal conditional path.
  Future<void> _documents(Map command) async {
    final op = command['op'] as String;
    final args = Map<String, Object?>.from(command['args'] as Map);
    try {
      final data = await documents.handle(op, args);
      if (op != 'open') {
        if (!_paused) schedule.mutated();
        _passWanted = true;
      }
      send({
        'event': 'documentsResult',
        'request': command['request'],
        'ok': true,
        'data': data,
      });
    } on DocumentsFailure catch (error) {
      send({
        'event': 'documentsResult',
        'request': command['request'],
        'ok': false,
        'code': error.code,
        'message': error.message,
      });
    } catch (error) {
      send({
        'event': 'documentsResult',
        'request': command['request'],
        'ok': false,
        'code': error is FileSystemException && error.osError?.errorCode == 2
            ? 'notFound'
            : 'refused',
        'message': error is FileSystemException
            ? error.message
            : error is CloudFailure
            ? error.message
            : '$error',
      });
    }
  }

  /// Manage sharing (spec #26): one gateway call per command, answered with
  /// its own result. Every call passes the pause gate (#53).
  Future<void> _sharing(Map command) async {
    final request = command['request'];
    try {
      final api = engine.cloud;
      if (api is! SharingApi) {
        throw const CloudFailure('Pair this device to manage sharing.');
      }
      final sharing = api as SharingApi;
      Map<String, Object?> share(OutgoingShare share) => {
        'share_id': share.shareId,
        'path': share.path,
        'recipient_id': share.recipientId,
        'recipient_display_name': share.recipientName,
        'permission': share.permission.name,
      };
      Object? data;
      switch (command['op']) {
        case 'load':
          final users = await sharing.householdUsers();
          final shares = await sharing.outgoingShares();
          engine.applyOutgoing(shares);
          data = {
            'users': [
              for (final user in users)
                {'id': user.id, 'display_name': user.displayName},
            ],
            'shares': [for (final row in shares) share(row)],
          };
        case 'create':
          data = share(
            await sharing.createShare(
              command['path'] as String,
              command['recipient'] as String,
              SharePermission.parse(command['permission']),
            ),
          );
        case 'update':
          data = share(
            await sharing.updateShare(
              command['share'] as String,
              SharePermission.parse(command['permission']),
            ),
          );
        case 'remove':
          await sharing.removeShare(command['share'] as String);
        default:
          throw const CloudFailure('Unknown sharing request.');
      }
      if (command['op'] != 'load') {
        // The indicator's names and the listing's share types follow now.
        engine.outgoingChanged();
        schedule.requestNow();
        _passWanted = true;
      }
      send({
        'event': 'sharingResult',
        'request': request,
        'ok': true,
        'data': data,
      });
    } catch (error) {
      send({
        'event': 'sharingResult',
        'request': request,
        'ok': false,
        'message': '$error',
        if (error is CloudFailure && error.status != null)
          'status': error.status,
      });
    }
  }

  /// Trash (spec #44): the Trash view's list and actions, and Undo. While
  /// paused or offline only this device's trash is reached. Answered with
  /// its own result; a change starts a pass at once.
  Future<void> _trash(Map command) async {
    final request = command['request'];
    final op = command['op'];
    final server = !_paused && !schedule.offline;
    List<String> list(String key) =>
        (command[key] as List? ?? const []).cast<String>();
    try {
      final Object data = switch (op) {
        'list' => await engine.trashListing(server: server),
        'restore' => await engine.trashRestore(
          serverId: server ? command['serverId'] as String? : null,
          deviceId: command['deviceId'] as String?,
        ),
        'restoreDevice' => await engine.trashRestore(
          deviceId: command['deviceId'] as String,
        ),
        'delete' => await engine.trashDelete(
          server ? list('serverIds') : const [],
          list('deviceIds'),
        ),
        'empty' => await engine.trashEmpty(server: server),
        'undo' => await engine.undoDelete(
          list('paths'),
          command['at'] as int,
          server: server,
        ),
        _ => throw const CloudFailure('Unknown trash request.'),
      };
      if (op != 'list') {
        if (!_paused) schedule.requestNow();
        _passWanted = true;
      }
      send({
        'event': 'trashResult',
        'request': request,
        'ok': true,
        'data': data,
      });
    } catch (error) {
      send({
        'event': 'trashResult',
        'request': request,
        'ok': false,
        'message': error is FileSystemException ? error.message : '$error',
      });
    }
  }

  /// Household administration (spec #27): one gateway call per command,
  /// answered with its status and body. The gateway authorizes every call.
  Future<void> _admin(Map command) async {
    final request = command['request'];
    try {
      final api = engine.cloud;
      if (api is! AdminTransport) {
        throw const CloudFailure('Pair this device to use Admin.');
      }
      final body = command['body'];
      final response = await (api as AdminTransport).admin(
        command['method'] as String,
        command['path'] as String,
        body: body is Map ? Map<String, Object?>.from(body) : null,
      );
      send({
        'event': 'adminResult',
        'request': request,
        'ok': true,
        'status': response.status,
        'data': response.data,
      });
    } catch (error) {
      send({
        'event': 'adminResult',
        'request': request,
        'ok': false,
        'message': '$error',
      });
    }
  }

  /// The update feed (spec #28 G1, spec #37). Both run beside passes and
  /// commands instead of in the queue: a package download must not hold
  /// sync back.
  Future<void> _releaseCheck(Map command) async {
    final request = command['request'];
    try {
      final feed = releases;
      if (feed == null) {
        throw const CloudFailure('Pair this device to check for updates.');
      }
      final manifest = await feed.releaseManifest(command['target'] as String);
      send({
        'event': 'releaseResult',
        'request': request,
        'ok': true,
        'manifest': manifest?.toJson(),
      });
    } catch (error) {
      send({
        'event': 'releaseResult',
        'request': request,
        'ok': false,
        'message': '$error',
      });
    }
  }

  Future<void> _releaseDownload(Map command) async {
    final request = command['request'];
    final progress = Stopwatch()..start();
    var owned = false;
    try {
      final feed = releases;
      if (feed == null) {
        throw const CloudFailure('Pair this device to download updates.');
      }
      if (_downloadingRelease) {
        throw const CloudFailure('An update is already downloading.');
      }
      _downloadingRelease = owned = true;
      final cancel = _releaseCancels[request] = Completer<void>();
      final manifest = ReleaseManifest.fromJson(
        Map<String, Object?>.from(command['manifest'] as Map),
        command['target'] as String,
      );
      await feed.downloadRelease(
        manifest,
        File(command['path'] as String),
        progress: (received) {
          if (progress.elapsedMilliseconds < 250) return;
          progress.reset();
          send({
            'event': 'releaseProgress',
            'request': request,
            'received': received,
          });
        },
        cancel: cancel.future,
      );
      send({'event': 'releaseResult', 'request': request, 'ok': true});
    } catch (error) {
      send({
        'event': 'releaseResult',
        'request': request,
        'ok': false,
        'refused': error is ReleaseRefused,
        'cancelled': error is ReleaseCancelled,
        'message': '$error',
      });
    } finally {
      if (owned) {
        _downloadingRelease = false;
        _releaseCancels.remove(request);
      }
    }
  }

  Future<bool> _handleQueued(Map command) async {
    if (editorDiagnosticsEnabled &&
        command['action'] == editorDiagnosticRequest) {
      Map<String, Object?>? report;
      try {
        report = readEditorDiagnostic(
          engine,
          command['path'],
          command['selectionVersion'],
          phoneStoragePaused: _phonePaused == true,
        );
      } on FileSystemException {
        // The response must never expose paths from an exception.
      }
      send({
        'event': editorDiagnosticResult,
        'request': command['request'],
        'report': report,
      });
      // Ordinary state projection can persist warning notices. This request
      // also leaves the running pass's mutation/interruption signal alone.
      return false;
    }
    if (_androidForeground && _isForegroundCommand(command)) {
      final opening = command['action'] == 'open' || command['op'] == 'open';
      final done = opening ? Completer<void>() : null;
      _selectedRead = done?.future;
      try {
        await _handle(command);
      } finally {
        _selectedRead = null;
        done?.complete();
      }
      _emitForegroundStatus();
      return command['action'] == 'open' || command['action'] == 'documents';
    }
    await _handle(command);
    await emit(force: true);
    return true;
  }

  Future<void> _handle(Map command) async {
    final action = command['action'];
    try {
      if (!(action == 'open' && _androidForeground) &&
          const {
            'bulk',
            'retention',
            'delete',
            'finishEditing',
            'keepBoth',
            'open',
            'createFolder',
            'renameLocal',
          }.contains(action)) {
        engine.requireStorageReady();
        // These change the root at once; while paused only intents that
        // wait for the next pass (retention, delete, finish) are recorded.
        if (_paused &&
            const {
              'keepBoth',
              'createFolder',
              'renameLocal',
            }.contains(action)) {
          throw const CloudFailure(
            'Sync is paused. Resume sync to change files in the local folder.',
          );
        }
        if (!_paused) schedule.mutated();
      }
      switch (action) {
        case 'tick':
          // An explicit retry: held uploads (backoff, size refusals) too.
          engine.uploads.retryAll();
          if (_androidForeground) _restartForegroundCheck();
          schedule.reconnect();
          _passWanted = true;
        case 'visible':
          // The window was shown: list the cloud now (not while paused).
          // Android's app opening also verifies every file (#130 (3)): its
          // entry sends 'verify'. The always-on desktop does not (#135).
          // Unreachable, the next retry is seconds away, not minutes.
          final verify = command['verify'] == true;
          if (_androidForeground && verify) {
            if (_paused) break;
            if (_passVerifies) {
              _checkingChanges = true;
              break;
            }
            if (!_verifyPassWanted) _restartForegroundCheck();
            _verifyPassWanted = true;
          }
          if (_androidForeground && _inPass && !verify) {
            // A Downloader refresh may arrive after the current listing.
            // Keep its request through schedule.completed for this pass.
            _listPassWanted = true;
          } else {
            schedule.reconnect();
          }
          if (verify) engine.requestFullVerification();
          _passWanted = true;
        case 'foregroundLeft':
          if (_heldOpen != null) {
            _heldOpen = null;
            _openNotice(null);
          }
        case 'background':
          // A background run (Android WorkManager, spec #28 A4): one
          // complete pass that lists the cloud and, with event-driven
          // hashing, verifies every file (decision #130 (3)). Answered by
          // 'backgroundDone' once that pass ends; at once while paused.
          await pickupIfDue?.call();
          final during = _arrivedDuring[command];
          if (_paused) {
            _background.add((
              request: command['request'],
              after: _passSerial,
              listedSince: null,
            ));
            _answerBackground(paused: true);
          } else if (during != null &&
              during == _passSerial &&
              (_passVerifies ||
                  (!_inPass &&
                      (_verifiedSerial == during ||
                          (_androidForeground &&
                              _passWillVerify &&
                              _passGeneration == _connectionGeneration &&
                              schedule.offline))))) {
            // Asked for during a pass that is itself a full verification (a
            // cold start's start-up pass): that pass is the run, so it
            // verifies once, not twice (#130 (3)). Answered when it ends,
            // or now if it already has.
            // Its listing counts if made after the request arrived or at
            // most [joinedListingAge] before it.
            _background.add((
              request: command['request'],
              after: during - 1,
              listedSince: _arrivedAt[command]! - joinedListingAge,
            ));
            if (!_inPass) _answerBackground();
          } else {
            _background.add((
              request: command['request'],
              after: _passSerial,
              listedSince: null,
            ));
            schedule.requestNow();
            engine.requestFullVerification();
            if (_androidForeground) _verifyPassWanted = true;
            _passWanted = true;
          }
        case 'phoneFolders':
          // All files access granted or lost while the app runs (spec #52),
          // applied between passes only: a pass keeps the state it began
          // with (commands also run between the paths of a pass).
          final routing = engine.tree.phoneFolders;
          final paused = command['paused'] == true;
          if (routing != null && paused != (_phonePaused ?? routing.paused)) {
            _phonePaused = paused;
            if (!_inPass) await _applyPhoneFolders();
            schedule.requestNow();
            if (_androidForeground && !paused) _verifyPassWanted = true;
            _passWanted = true;
          }
        case 'network':
          // The platform's connectivity report (Android). A network that
          // just became usable ends an offline wait at once.
          final wifi = command['wifi'] == true;
          final route = command['route'] as int?;
          final routeChanged =
              route != null && _networkRoute != null && route != _networkRoute;
          final wifiChanged = _onWifi != null && wifi != _onWifi;
          _onWifi = wifi;
          _networkRoute = route ?? _networkRoute;
          _applyNetwork();
          final online = command['online'];
          final previous = _online;
          if (online is bool) _online = online;
          final validationChanged = _online != previous;
          final disconnected =
              _connection == SyncStatus.offline ||
              (_connection == SyncStatus.checkingServer && schedule.offline);
          if (_androidForeground && routeChanged) {
            foregroundReads!().networkChanged();
          }
          if (_androidForeground &&
              !_paused &&
              (routeChanged ||
                  (validationChanged && (previous != null || disconnected)) ||
                  (wifiChanged && _online == true && disconnected))) {
            _restartForegroundCheck();
            schedule.reconnect();
            _passWanted = true;
          } else if (!_androidForeground &&
              online == true &&
              schedule.offline &&
              !_paused) {
            schedule.reconnect();
            _passWanted = true;
          }
        case 'networkPolicy':
          final value = command['value'];
          if (value != 'wifi' && value != 'any') {
            throw const CloudFailure('Unknown network setting.');
          }
          engine.manifest.setSetting('network', value as String);
          _networkPolicy = value;
          _applyNetwork();
        case 'pause':
          // Durable before acknowledged; a running pass ends at its next
          // path boundary (see [_between]) and no request follows it.
          engine.manifest.setSetting('paused', '1');
          if (_androidForeground && !_paused) {
            _restartForegroundCheck();
            _heldOpen = null;
            _openNotice(null);
            engine.message =
                'Sync paused. Local changes sync after you resume.';
          }
          _setPaused(true);
          _passWanted = true;
        case 'resume':
          if (_androidForeground && !_paused) break;
          engine.manifest.setSetting('paused', '0');
          _setPaused(false);
          if (_androidForeground) {
            _restartForegroundCheck();
            _verifyPassWanted = true;
            engine.requestFullVerification();
          }
          // Pause then Resume is the user's way to retry held uploads.
          engine.uploads.retryAll();
          schedule.reconnect();
          _passWanted = true;
        case 'bulk':
          final result = engine.applyBulk(
            command['value'] as String,
            (command['targets'] as List)
                .map((target) => Map<String, dynamic>.from(target as Map))
                .toList(),
          );
          send({
            'event': 'bulkResult',
            'request': command['request'],
            ...result,
          });
        case 'retention':
          engine.setRetention(
            command['path'] as String,
            Retention.values.byName(command['value'] as String),
          );
        case 'createFolder':
          final path = await engine.createFolder(
            command['parent'] as String,
            command['name'] as String,
            Retention.values.byName(command['value'] as String),
          );
          send({
            'event': 'folderCreated',
            'request': command['request'],
            'path': path,
          });
        case 'renameLocal':
          final path = await engine.renameLocal(
            command['path'] as String,
            command['name'] as String,
          );
          send({
            'event': 'folderCreated',
            'request': command['request'],
            'path': path,
          });
          _passWanted = true;
        case 'delete':
          engine.requestDelete(command['path'] as String);
        case 'finishEditing':
          engine.editing.request(
            command['path'] as String,
            (command['sessions'] as List)
                .map((v) => Map<String, dynamic>.from(v as Map))
                .toList(),
          );
          // Completion runs in the next pass, which starts immediately.
          engine.markDirty(command['path'] as String);
          _passWanted = true;
        case 'clearMissingEditorCopies':
          send({
            'event': 'editorCopiesResult',
            'message': _phonePaused == true
                ? 'Kept editor copies. Phone storage is unavailable. Check All files access.'
                : engine.clearMissingEditorCopies(
                    command['path'] as String,
                    (command['sessions'] as List).cast<Map>(),
                  ),
          });
        case 'dismissEditorWarnings':
        case 'undoEditorWarnings':
          final undo = action == 'undoEditorWarnings';
          send({
            'event': 'editorCopiesResult',
            'message': !undo && _phonePaused == true
                ? 'Phone storage is unavailable. Check All files access.'
                : engine.changeMissingEditorWarnings(
                    command['path'] as String,
                    (command['sessions'] as List).cast<Map>(),
                    undo: undo,
                  ),
          });
        case 'removeOpenedCopy':
          // Details' Remove opened copy (decision #184): each unchanged copy.
          for (final copy in (command['sessions'] as List? ?? const [])) {
            engine.removeOpenedCopy(
              command['path'] as String,
              (copy as Map)['id'] as String,
            );
          }
        case 'keepBoth':
          await engine.keepBoth(command['path'] as String);
        case 'openDirectory':
          final path = tree.directoryLocation(command['path'] as String);
          send({
            'event': 'openDirectory',
            'path': path,
            'root': tree.root.path,
            'relative': command['path'],
            'rootIdentity': tree.native.identity(tree.fd),
          });
        case 'open':
          if (_androidForeground) {
            await _openForegroundFile(command);
            break;
          }
          final path = await engine.openFile(
            command['path'] as String,
            providerTracked: command['providerTracked'] == true,
          );
          send({'event': 'open', 'path': path});
        case 'documents':
          await _documents(command);
        case 'sharing':
          await _sharing(command);
        case 'trash':
          await _trash(command);
        case 'admin':
          await _admin(command);
        case 'releaseCheck':
          unawaited(_releaseCheck(command));
        case 'releaseDownload':
          unawaited(_releaseDownload(command));
        case 'stop':
          _requestStop();
      }
    } catch (error) {
      if (action == 'clearMissingEditorCopies') {
        send({
          'event': 'editorCopiesResult',
          'message': 'Could not confirm that editor copies were cleared. Check the file and try again.',
        });
        return;
      }
      if (action == 'dismissEditorWarnings' || action == 'undoEditorWarnings') {
        send({
          'event': 'editorCopiesResult',
          'message': 'Could not save the editor warning change. Check the file and try again.',
        });
        return;
      }
      if (action == 'bulk') {
        send({
          'event': 'bulkResult',
          'request': command['request'],
          'accepted': 0,
          'failed': (command['targets'] as List).length,
          'errors': ['$error'],
        });
      }
      if (action == 'createFolder' || action == 'renameLocal') {
        send({
          'event': 'folderCreateFailed',
          'request': command['request'],
          'message': action == 'renameLocal'
              ? 'Could not rename: ${error is FileSystemException ? error.message : error}'
              : 'Could not create folder: $error',
        });
      }
      engine.message = action == 'openDirectory'
          ? 'Local folder unavailable or replaced. No folder was created and storage choices are unchanged.'
          : 'Pending: $error';
      if (action == 'openDirectory') {
        send({'event': 'directoryUnavailable', 'message': engine.message});
      }
    }
  }
}
