import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../gateway/dav_api.dart';
import '../../platform/adapters.dart';
import '../gateway/identity.dart';
import '../gateway/admin_api.dart';
import '../gateway/fetch_api.dart';
import 'fetch_jobs.dart';
import 'icon_colors.dart';
import 'pairing_inputs.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../sync/top_folders.dart';
import '../local/desktop_shortcut.dart';
import '../local/root_move.dart';
import '../local/root_tree.dart';
import '../ports/desktop_launcher.dart';
import '../ports/documents.dart';
import '../ports/root_placement.dart';
import '../ports/root_location.dart';
import '../ports/secret_store.dart';
import '../sync/first_sync.dart';
import '../sync/sync_schedule.dart';
import '../sync/worker.dart';
import '../update/release.dart';

class ClientController extends ChangeNotifier implements DocumentsHost {
  ClientController(
    this.profile, {
    SecretStore? secrets,
    this.nativeLibrary,
    DesktopLauncher? launcher,
    RootLocationPolicy? rootLocation,
    Future<String> Function()? deviceLabel,
    this.folderCommandTimeout = const Duration(seconds: 60),
    this.stopTimeout = const Duration(seconds: 20),
    this.placement = const PickerOnlyPlacement(),
    this.pairingOptions = PairingOptions.desktop,
    this.defaultNetworkPolicy,
    this.fetchTimeout = fetchReplyTimeout,
    this.workerEntry = syncWorker,
  }) : secrets = secrets ?? platformAdapters().secretStore(),
       launcher =
           launcher ??
           platformAdapters().desktopLauncher(nativeLibrary: nativeLibrary),
       rootLocation = rootLocation ?? platformAdapters().rootLocationPolicy(),
       deviceLabel = deviceLabel ?? platformAdapters().deviceLabel;
  final Directory profile;
  late final iconColors = IconColors(profile);
  final SecretStore secrets;
  final DesktopLauncher launcher;

  /// Where this platform allows the root (checked before a root is made).
  final RootLocationPolicy rootLocation;

  /// The platform's device label for pairing, clipped by [pairingLabel].
  final Future<String> Function() deviceLabel;

  /// Set while the secret store refuses access (macOS: Keychain
  /// unavailable). No worker runs then, so nothing touches the network or
  /// the root; [retrySecrets] tries again.
  String? secretsUnavailable;
  final String? nativeLibrary;
  final Duration folderCommandTimeout;

  /// The wait for the worker's answer to one Downloader request.
  final Duration fetchTimeout;

  /// The sync worker isolate's entry point; tests pass a scripted one.
  final Future<void> Function(Map<String, Object?> initial) workerEntry;

  /// Where a new profile's synced folder and desktop shortcut go (spec #34
  /// P1, P2). The default has no automatic root: only `main()` passes the
  /// platform's placement, so no test creates a folder in a real home.
  final RootPlacement placement;

  /// Why the automatic root was not created (shown with **Use another
  /// folder**); null otherwise.
  String? rootProblem;

  /// An interrupted `move-root` (Linux) that the start could neither finish
  /// nor undo: its journal names the folders, so nothing syncs until
  /// move-root runs again.
  bool rootMovePending = false;

  /// The automatic root is being created (no picker is offered meanwhile).
  bool settingUpRoot = false;

  /// Whether this platform creates the root without a picker; the picker is
  /// then the advanced **Use another folder** action.
  bool get automaticRoot => placement.defaultParent() != null;

  /// How this client pairs (spec #28 Pairing): Linux keeps its defaults.
  final PairingOptions pairingOptions;

  /// A first pairing was approved and the first-sync folder screen has not
  /// been confirmed (decision #118). No worker runs meanwhile, so nothing
  /// downloads; the screen returns at the next start.
  bool firstSyncPending = false;

  /// The secret store could not read this device's key (PR #60 review F5).
  /// The key is never silently replaced; [resetDeviceIdentity] is the
  /// knowing reset, offered where the store has a route around itself.
  bool keyUnavailable = false;

  /// Whether this platform can wipe its secret store even when the store
  /// cannot start (Android).
  bool get canResetIdentity => secrets is SecretStoreReset;

  /// Bound for a cooperative worker stop before the isolate is killed.
  final Duration stopTimeout;

  /// The platform's network setting for a profile that has none: 'wifi'
  /// on Android ("Wi-Fi only", decision #108 Q4), null where there is no
  /// such setting (Linux).
  final String? defaultNetworkPolicy;

  /// The network setting in force: 'wifi' ("Wi-Fi only") or 'any' ("Wi-Fi
  /// or mobile data"); null where the platform has none.
  String? networkPolicy;

  /// Whether file transfers are waiting for Wi-Fi right now.
  bool transfersHeld = false;

  /// Whether a worker has reported the library at least once: until then
  /// [entries] is empty for lack of news, not because nothing is there.
  bool stateReceived = false;
  bool? _onWifi;
  final _backgroundRuns = <String, Completer<Map<String, dynamic>>>{};
  @override
  List<Map<String, dynamic>> entries = [];
  String message = 'Choose a root and pair this device.';

  /// The last pairing attempt's outcome, for the pairing form: [message]
  /// is also the worker's status line, which the restarted worker replaces.
  String? pairingMessage;
  String? folderMessage;

  /// Set only while the device certificate is near expiry and renewal keeps failing.
  String? certificateWarning;
  String? root;
  String? server;

  /// This device's paired server as a canonical origin, never the build's
  /// household default. Null before pairing.
  String? get serverOrigin {
    final current = server;
    return current == null ? null : normalizeServerOrigin(current);
  }

  String? ca;
  String? fingerprint;
  String pairingState = 'unpaired';

  /// The household origin this build pairs with unless the person changes it
  /// (spec #35): `--dart-define=ANJ_HOUSEHOLD_ORIGIN=https://…` at build time.
  static const householdOrigin = String.fromEnvironment(
    'ANJ_HOUSEHOLD_ORIGIN',
    defaultValue: 'https://gateway.example.com',
  );

  /// True while a legacy (fingerprint-approved) invitation waits for the
  /// admin: only then is the device fingerprint worth showing.
  bool awaitingFingerprintApproval = false;

  /// How often a device that redeemed a pinned code asks whether the server
  /// has approved it yet, and for how long at most (spec #35). The gateway
  /// itself holds each request up to 20 s, and allows 10 enrollment requests
  /// per source and minute.
  Duration pairingPoll = const Duration(seconds: 8);
  Duration pairingWait = const Duration(minutes: 3);

  /// The device grant from pairing: 'write' or 'read' (null before pairing).
  /// A read-grant device may list shares but not change them (spec #26).
  String? accountRights;
  bool busy = false;

  /// Persisted in the profile; while paused no file-sync request reaches the
  /// network. Device certificate pickup (`GET /v1/device/certificate`) is the
  /// one exception: it continues so a reissued leaf is not missed.
  bool paused = false;
  SyncStatus status = SyncStatus.upToDate;

  /// Files the worker reports as uploading, downloading or queued for
  /// transfer in the running pass. Empty while paused: a paused client shows
  /// nothing as syncing, even while an in-flight transfer winds down.
  Set<String> get syncing => paused ? const {} : _syncing;
  Set<String> _syncing = const {};
  @visibleForTesting
  set syncing(Set<String> value) => _syncing = value;

  /// What the worker reports as moving, paused or not: a transfer still
  /// winding down after Pause counts (an update waits for it, spec #37).
  Set<String> get transferring => _syncing;

  /// Whether the most recent stop closed the worker cleanly (manifest closed).
  bool lastStopClean = true;
  bool _storageReady = false;
  bool get canCreateFolder => _input != null && _storageReady;
  final _bulkRequests = <String, Completer<Map<String, dynamic>>>{};
  final _folderRequests = <String, Completer<String>>{};
  final _sharingRequests = <String, Completer<Object?>>{};
  final _adminRequests = <String, Completer<AdminResponse>>{};
  final _releaseRequests = <String, Completer<Map>>{};
  final _releaseProgress = <String, void Function(int)>{};
  final _fetchRequests = <String, Completer<Map>>{};

  /// A Finish editing is still to complete (the worker's journal holds its
  /// request). An update waits for it (spec #37 rule 4).
  bool finishingEdits = false;
  final _documentsRequests = <String, Completer<Map<String, Object?>>>{};

  /// Whether this device's account holds the admin role (spec #27), from
  /// `GET /v1/account` at start, after pairing and every 5 minutes. The
  /// gateway decides on every call; this only shows or hides the section.
  bool isAdmin = false;

  /// Shown once after the role disappears ("Your admin role was removed.").
  String? adminNotice;
  Timer? _adminPoll;
  Isolate? _worker;
  SendPort? _input;
  ReceivePort? _output;
  ReceivePort? _workerStatus;
  Completer<void>? _stopped;
  Completer<void>? _ready;
  bool _checking = false;
  void _failFolderRequests() {
    for (final request in _bulkRequests.values) {
      request.completeError(
        const FileSystemException(
          'Worker stopped before confirming the batch. Check the library before retrying.',
        ),
      );
    }
    _bulkRequests.clear();
    for (final request in _folderRequests.values) {
      request.completeError(
        const FileSystemException(
          'The worker stopped before confirming creation. The folder may have been created; check the library before retrying.',
        ),
      );
    }
    _folderRequests.clear();
    for (final request in _sharingRequests.values) {
      request.completeError(
        const CloudFailure(
          'Sync stopped before the server answered. Reopen to see the current state.',
        ),
      );
    }
    _sharingRequests.clear();
    for (final run in _backgroundRuns.values) {
      run.complete({'stopped': true});
    }
    _backgroundRuns.clear();
    for (final request in _adminRequests.values) {
      request.completeError(
        const CloudFailure(
          'Sync stopped before the server answered. Try again shortly.',
        ),
      );
    }
    _adminRequests.clear();
    for (final request in _releaseRequests.values) {
      request.completeError(
        const CloudFailure(
          'Sync stopped before the server answered. Try again shortly.',
        ),
      );
    }
    _releaseRequests.clear();
    _releaseProgress.clear();
    for (final request in _fetchRequests.values) {
      request.complete({'ok': false, 'error': FetchError.network.name});
    }
    _fetchRequests.clear();
    for (final request in _documentsRequests.values) {
      request.completeError(
        const DocumentsFailure(
          'unavailable',
          'AnJ Cloud sync stopped before answering. Try again shortly.',
        ),
      );
    }
    _documentsRequests.clear();
  }

  void reportMessage(String text) {
    message = text;
    notifyListeners();
  }

  Future<void> initialize() async {
    final native = platformAdapters().rootFilesystem(nativeLibrary);
    profile.createSync(recursive: true);
    native.privateDir(profile.path);
    String? preferenceWarning;
    try {
      iconColors.load();
    } on FormatException {
      preferenceWarning = 'Saved icon colours could not be read. Choose colours again to reset them.';
    } on FileSystemException {
      preferenceWarning =
          'Saved icon colours could not be read. Check profile permissions.';
    }
    final store = Manifest(profile);
    if (store.setting('profileId') == null) {
      store.setSetting('profileId', uniqueId());
    }
    // An interrupted `move-root` (Linux) is finished, or undone when nothing
    // was renamed yet, before the root is read; one that can be neither
    // keeps its journal and is shown.
    String? moveProblem;
    if (store.setting(rootMoveSetting) != null) {
      try {
        await RootMover(
          store,
          profile.path,
          native,
          desktop: placement.desktopDirectory(),
          keep: placement.keptDirectories(),
        ).resumeAtStart();
      } on RootMoveRefused catch (error) {
        moveProblem = error.message;
      } on Object catch (error) {
        moveProblem =
            'An interrupted move of the synced folder could not be '
            'finished: $error';
      }
    }
    // A move still recorded after that names folders this start must not
    // use: no sync (and no staging recreated at the old place) until
    // move-root finishes or undoes it.
    rootMovePending = store.setting(rootMoveSetting) != null;
    if (rootMovePending) {
      moveProblem ??=
          'An interrupted move of the synced folder is not finished.';
      moveProblem =
          '$moveProblem Sync stays stopped until it is: quit AnJ Cloud and '
          'run move-root again.';
    }
    root = store.setting('root');
    server = store.setting('server');
    ca = store.setting('ca');
    fingerprint = store.setting('fingerprint');
    pairingState = store.setting('certificate') == null ? 'unpaired' : 'paired';
    accountRights = store.setting('accountRights');
    paused = store.setting('paused') == '1';
    firstSyncPending = store.setting(firstSyncSetting) == 'pending';
    status = paused
        ? SyncStatus.paused
        : root == null || rootMovePending
        ? SyncStatus.attention
        : status;
    final keyRef = DeviceIdentity(store, secrets).privateKeyRef;
    store.close();
    // Only where a reset route exists: on Linux this would be one more
    // Secret Service read, and possibly an unlock prompt, at every start.
    if (canResetIdentity) await _probeSecrets(keyRef);
    if (rootMovePending) {
      // Neither the worker nor an automatic root: see above.
    } else if (root != null) {
      await start();
    } else {
      await _automaticRoot();
    }
    if (preferenceWarning != null) message = preferenceWarning;
    if (moveProblem != null) message = moveProblem;
    notifyListeners();
  }

  void setIconColor(String path, int? color) {
    iconColors.set(path, color);
    notifyListeners();
  }

  Future<void> start() async {
    if (_worker != null || _starting || root == null) return;
    if (rootMovePending) return;
    if (firstSyncPending) {
      message = 'Choose which folders to keep on this device.';
      return;
    }
    _starting = true;
    try {
      await _start();
    } finally {
      _starting = false;
      // The worker never became ready: only once it is gone (or reported
      // fatal, which closes its manifest) is a Pause written directly.
      if (_input == null &&
          (_worker == null || (_stopped?.isCompleted ?? true))) {
        _flushPendingPause();
      }
    }
  }

  Future<void> _start() async {
    String? key;
    final store = Manifest(profile);
    final identity = DeviceIdentity(store, secrets);
    if (identity.enrolled) {
      try {
        key = await secrets.read(identity.privateKeyRef);
      } on SecretStoreUnavailable catch (error) {
        // An explicit state with no worker: no network or file work until
        // the store is reachable again (spec #31, Keychain unavailable).
        store.close();
        secretsUnavailable = error.message;
        message = error.message;
        status = SyncStatus.attention;
        notifyListeners();
        return;
      } catch (_) {
        keyUnavailable = true;
        message = 'Keyring unavailable. Local changes retained; unlock it before connecting.';
      }
    } else if (store.setting('certificate') != null) {
      pairingState = 'expired: re-pair required';
    }
    store.close();
    // The worker's first state replaces the message and status.
    secretsUnavailable = null;
    _ready = Completer<void>();
    _checking = false;
    _stopped = Completer<void>();
    _output = ReceivePort();
    _output!.listen((dynamic value) async {
      if (_stopped?.isCompleted ?? true) return;
      final event = value as Map;
      switch (event['event']) {
        case 'ready':
          _input = event['input'] as SendPort;
          _flushPendingPause();
          final wifi = _onWifi;
          if (wifi != null) _input!.send({'action': 'network', 'wifi': wifi});
          _ready?.complete();
          unawaited(refreshAdmin());
          _adminPoll?.cancel();
          _adminPoll = Timer.periodic(
            const Duration(minutes: 5),
            (_) => unawaited(refreshAdmin()),
          );
          _probeFetch();
        case 'state':
          _storageReady = event['storageReady'] == true;
          entries = (event['entries'] as List)
              .cast<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          message = event['message'] as String;
          if (_pendingPause == null) paused = event['paused'] == true;
          finishingEdits = event['finishing'] == true;
          stateReceived = true;
          networkPolicy = event['networkPolicy'] as String?;
          transfersHeld = event['transfersHeld'] == true;
          status = SyncStatus.values.asNameMap()[event['status']] ?? status;
          notifyListeners();
          _probeFetch();
        case 'backgroundDone':
          _backgroundRuns
              .remove(event['request'])
              ?.complete(Map<String, dynamic>.from(event));
        case 'activity':
          _syncing = (event['paths'] as List).cast<String>().toSet();
          notifyListeners();
        case 'checking':
          // Startup is reading files to verify the folder (legacy identity).
          _checking = true;
          message = event['message'] as String;
          notifyListeners();
        case 'bulkResult':
          _bulkRequests
              .remove(event['request'])
              ?.complete(Map<String, dynamic>.from(event));
        case 'folderCreated':
          _folderRequests
              .remove(event['request'])
              ?.complete(event['path'] as String);
        case 'adminResult':
          final pending = _adminRequests.remove(event['request']);
          if (event['ok'] == true) {
            pending?.complete(
              AdminResponse(event['status'] as int, event['data']),
            );
          } else {
            pending?.completeError(CloudFailure(event['message'] as String));
          }
        case 'releaseResult':
          _releaseProgress.remove(event['request']);
          _releaseRequests.remove(event['request'])?.complete(event);
        case 'releaseProgress':
          _releaseProgress[event['request']]?.call(event['received'] as int);
        case 'fetchResult':
          _fetchRequests.remove(event['request'])?.complete(event);
        case 'sharingResult':
          final pending = _sharingRequests.remove(event['request']);
          if (event['ok'] == true) {
            pending?.complete(event['data']);
          } else {
            pending?.completeError(
              CloudFailure(
                event['message'] as String,
                status: event['status'] as int?,
              ),
            );
          }
        case 'documentsResult':
          final pending = _documentsRequests.remove(event['request']);
          final data = event['data'] is Map
              ? Map<String, Object?>.from(event['data'] as Map)
              : <String, Object?>{};
          if (pending == null) {
            // Answered after its caller gave up: release what it opened.
            final fd = data['fd'];
            if (fd is int) _closeLateDescriptor(fd, data['token']);
          } else if (event['ok'] == true) {
            pending.complete(data);
          } else {
            pending.completeError(
              DocumentsFailure(
                event['code'] as String? ?? 'refused',
                event['message'] as String? ?? 'Refused.',
              ),
            );
          }
        case 'folderCreateFailed':
          _folderRequests
              .remove(event['request'])
              ?.completeError(FileSystemException(event['message'] as String));
        case 'open':
          await openOnDesktop(
            () => launcher.openFile(event['path'] as String),
            directory: false,
          );
        case 'openDirectory':
          await openOnDesktop(
            () => launcher.openDirectory(
              event['root'] as String,
              event['relative'] as String,
              event['rootIdentity'] as String,
            ),
            directory: true,
          );
        case 'certificate':
          final warning = event['warning'] as String?;
          if (warning != certificateWarning) {
            certificateWarning = warning;
            notifyListeners();
          }
        case 'directoryUnavailable':
          folderMessage = event['message'] as String;
          notifyListeners();
        case 'fatal':
          _storageReady = false;
          _failFolderRequests();
          // A stopped worker transfers nothing; no stale indicator.
          _syncing = const {};
          status = SyncStatus.attention;
          message = event['message'] as String;
          if (!(_ready?.isCompleted ?? true)) _ready!.complete();
          if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
          notifyListeners();
        case 'stopped':
          _storageReady = false;
          _failFolderRequests();
          // A stopped worker transfers nothing; no stale indicator.
          _syncing = const {};
          _stoppedCleanly = true;
          if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
      }
    });
    _workerStatus = ReceivePort()
      ..listen((_) {
        if (_stopped?.isCompleted ?? true) return;
        _storageReady = false;
        _input = null;
        _failFolderRequests();
        _syncing = const {};
        message = 'Sync worker stopped. Check the library before retrying folder creation.';
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
        _stopped?.complete();
        notifyListeners();
      });
    _worker = await Isolate.spawn(
      workerEntry,
      <String, Object?>{
        'output': _output!.sendPort,
        'profile': profile.path,
        'privateKey': key,
        'nativeLibrary': nativeLibrary,
        'settleStaging': placement.stagingInProfile,
        'networkPolicy': defaultNetworkPolicy,
      },
      onExit: _workerStatus!.sendPort,
      onError: _workerStatus!.sendPort,
    );
    try {
      await _ready!.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      // A folder check reported by the worker may outlast the start timeout.
      if (!_checking) rethrow;
      await _ready!.future;
    }
  }

  Future<void> openOnDesktop(
    Future<bool> Function() launch, {
    required bool directory,
  }) async {
    try {
      final ok = await launch();
      if (!ok) {
        throw const FileSystemException(
          'No default application accepted the request.',
        );
      }
      if (directory) {
        folderMessage = null;
        notifyListeners();
      }
    } catch (error) {
      if (directory) {
        folderMessage = error is UnsupportedError
            ? 'Folder opening is not available on this platform.'
            : 'Could not open the local folder. Make sure it still exists and a default file browser is installed. Storage choices are unchanged.';
      } else {
        message = 'No desktop application opened the working copy.';
      }
      notifyListeners();
    }
  }

  bool _stoppedCleanly = false;

  /// Asks the worker to stop at its next checkpoint and waits at most
  /// [stopTimeout]. A clean stop closed the manifest (WAL checkpointed); a
  /// timeout kills the isolate, which is crash-equivalent and recovered by
  /// the next start. Returns whether the stop was clean.
  Future<bool> stop() async {
    if (_worker == null) return true;
    _stoppedCleanly = false;
    _input?.send({'action': 'stop'});
    await _stopped!.future.timeout(stopTimeout, onTimeout: () {});
    lastStopClean = _stoppedCleanly;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _input = null;
    // A start still waiting for a worker that never became ready (e.g. one
    // stopped during "Checking folder after update…") returns now.
    _checking = false;
    if (!(_ready?.isCompleted ?? true)) _ready!.complete();
    _storageReady = false;
    _failFolderRequests();
    // No notification: stop() also runs from dispose().
    _syncing = const {};
    _output?.close();
    _output = null;
    _workerStatus?.close();
    _workerStatus = null;
    // A Pause chosen while a worker was starting and never became ready.
    if (lastStopClean) _flushPendingPause();
    return lastStopClean;
  }

  /// Retry after "Keychain unavailable" (the store may be unlocked now).
  Future<void> retrySecrets() async {
    if (secretsUnavailable == null) return;
    message = 'Checking the keychain...';
    notifyListeners();
    await start();
    notifyListeners();
  }

  bool _starting = false;
  bool? _pendingPause;

  /// Pause or resume synchronization. Persisted by the worker before it is
  /// acknowledged; while the worker is starting it is sent once ready (or
  /// written directly if it never becomes ready); without a worker it is
  /// written directly. Never dropped.
  void setPaused(bool value) {
    paused = value;
    if (value) status = SyncStatus.paused;
    if (_input != null) {
      _input!.send({'action': value ? 'pause' : 'resume'});
    } else if (_starting || _worker != null) {
      _pendingPause = value;
    } else {
      _writePaused(value);
    }
    notifyListeners();
  }

  void _flushPendingPause() {
    final value = _pendingPause;
    if (value == null) return;
    _pendingPause = null;
    final input = _input;
    if (input != null) {
      input.send({'action': value ? 'pause' : 'resume'});
    } else {
      _writePaused(value);
    }
  }

  void _writePaused(bool value) {
    final store = Manifest(profile);
    try {
      store.setSetting('paused', value ? '1' : '0');
    } finally {
      store.close();
    }
  }

  /// The window became visible: list the cloud now rather than at the
  /// idle cadence.
  /// The window was shown (desktop) or the app opened (Android, where
  /// [verify] also asks for a full verification pass, decision #130 (3)).
  void windowShown({bool verify = false}) =>
      _input?.send({'action': 'visible', if (verify) 'verify': true});

  /// The platform's last connectivity report (Android): on Wi-Fi or
  /// Ethernet; null before the first report.
  bool? get onWifi => _onWifi;

  /// The platform's connectivity report (Android): on Wi-Fi or Ethernet, or
  /// not. Kept and re-sent to every worker start, so a worker never guesses.
  void reportNetwork({required bool wifi}) {
    _onWifi = wifi;
    _input?.send({'action': 'network', 'wifi': wifi});
  }

  /// "Wi-Fi only" ('wifi') or "Wi-Fi or mobile data" ('any'), persisted in
  /// the profile by the worker (decision #108 Q4).
  void setNetworkPolicy(String value) {
    if (value != 'wifi' && value != 'any') {
      throw ArgumentError.value(value, 'value', 'wifi or any');
    }
    networkPolicy = value;
    final input = _input;
    if (input != null) {
      input.send({'action': 'networkPolicy', 'value': value});
    } else {
      final store = Manifest(profile);
      try {
        store.setSetting('network', value);
      } finally {
        store.close();
      }
    }
    notifyListeners();
  }

  /// One background run (Android WorkManager, spec #28 A4): a complete
  /// pass that lists the cloud and verifies every local file, answered when
  /// it ends. Without a running worker it answers at once ('ran': false).
  Future<Map<String, dynamic>> backgroundRun({
    Duration timeout = const Duration(minutes: 8),
  }) async {
    final input = _input;
    if (input == null) return {'ran': false, 'stopped': true};
    final request = uniqueId();
    final result = Completer<Map<String, dynamic>>();
    _backgroundRuns[request] = result;
    input.send({'action': 'background', 'request': request});
    return result.future.timeout(
      timeout,
      onTimeout: () {
        _backgroundRuns.remove(request);
        return {'ran': true, 'timedOut': true};
      },
    );
  }

  Future<String> createFolder({
    required String parent,
    required String name,
    required Retention retention,
  }) {
    if (!canCreateFolder) {
      return Future.error(
        const FileSystemException(
          'Local storage is not ready. Check the root and storage upgrade status.',
        ),
      );
    }
    final request = uniqueId();
    final result = Completer<String>();
    _folderRequests[request] = result;
    _input!.send({
      'action': 'createFolder',
      'request': request,
      'parent': parent,
      'name': name,
      'value': retention.name,
    });
    return result.future.timeout(
      folderCommandTimeout,
      onTimeout: () {
        _folderRequests.remove(request);
        _storageReady = false;
        notifyListeners();
        throw const FileSystemException(
          'Creation confirmation timed out. The folder may have been created; check the library before retrying.',
        );
      },
    );
  }

  /// Renames a local item whose name is not allowed on other devices
  /// (decision #120) through the worker; returns the new path. Shares the
  /// folder-request channel ('folderCreated' / 'folderCreateFailed').
  Future<String> renameLocal(String path, String name) {
    if (!canCreateFolder) {
      return Future.error(
        const FileSystemException(
          'Local storage is not ready. Check the root and storage upgrade status.',
        ),
      );
    }
    final request = uniqueId();
    final result = Completer<String>();
    _folderRequests[request] = result;
    _input!.send({
      'action': 'renameLocal',
      'request': request,
      'path': path,
      'name': name,
    });
    return result.future
        .then((target) {
          onLocalRename?.call(path, target);
          return target;
        })
        .timeout(
          folderCommandTimeout,
          onTimeout: () {
            _folderRequests.remove(request);
            throw const FileSystemException(
              'Rename confirmation timed out. Check the library before retrying.',
            );
          },
        );
  }

  /// One household-administration request (spec #27) through the worker,
  /// which holds this device's certificate. A 403 `not-admin` hides Admin.
  Future<AdminResponse> admin(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) {
    final input = _input;
    if (input == null || pairingState != 'paired') {
      return Future.error(
        const CloudFailure('Connect to the server to use Admin.'),
      );
    }
    final request = uniqueId();
    final result = Completer<AdminResponse>();
    _adminRequests[request] = result;
    input.send({
      'action': 'admin',
      'request': request,
      'method': method,
      'path': path,
      'body': ?body,
    });
    return result.future
        .timeout(
          adminReplyTimeout,
          onTimeout: () {
            _adminRequests.remove(request);
            throw const CloudFailure(
              'The server did not answer in time. Refresh to see the current state.',
            );
          },
        )
        .then((response) {
          if (response.status == 403 && response.map['error'] == 'not-admin') {
            adminRoleRemoved();
          }
          return response;
        });
  }

  /// Whether the update feed can be asked: the worker runs with this
  /// device's certificate (spec #28 G1, spec #37).
  bool get releaseFeedReady => _input != null && pairingState == 'paired';

  Future<Map> _release(
    Map<String, Object?> command,
    Duration timeout, {
    void Function(int received)? progress,
    void Function(String request)? sent,
  }) {
    final input = _input;
    if (input == null || !releaseFeedReady) {
      return Future.error(
        const CloudFailure('Pair this device to check for updates.'),
      );
    }
    final request = uniqueId();
    final result = Completer<Map>();
    _releaseRequests[request] = result;
    if (progress != null) _releaseProgress[request] = progress;
    input.send({...command, 'request': request});
    sent?.call(request);
    return result.future.timeout(
      timeout,
      onTimeout: () {
        _releaseRequests.remove(request);
        _releaseProgress.remove(request);
        // A download given up here stops in the worker too, so its file is
        // not rewritten and the next attempt is not refused as a second one.
        _input?.send({'action': 'releaseCancel', 'request': request});
        throw const CloudFailure('The server did not answer in time.');
      },
    );
  }

  @override
  bool get documentsReady => _input != null && _storageReady;

  @override
  void Function(String from, String to)? onLocalRename;

  /// One documents provider command (spec #28 A5) through the worker. An
  /// open may download a Cloud-only file first, so it waits longer.
  @override
  Future<Map<String, Object?>> documentsCommand(
    String op,
    Map<String, Object?> args,
  ) {
    final input = _input;
    if (input == null) {
      return Future.error(
        const DocumentsFailure(
          'unavailable',
          'AnJ Cloud is starting. Try again in a moment.',
        ),
      );
    }
    final request = uniqueId();
    final result = Completer<Map<String, Object?>>();
    _documentsRequests[request] = result;
    input.send({
      'action': 'documents',
      'request': request,
      'op': op,
      'args': args,
    });
    return result.future.timeout(
      op == 'open' ? const Duration(minutes: 10) : const Duration(seconds: 60),
      onTimeout: () {
        _documentsRequests.remove(request);
        throw const DocumentsFailure(
          'unavailable',
          'AnJ Cloud did not answer in time. Try again shortly.',
        );
      },
    );
  }

  /// The running package download's request, for [cancelReleaseDownload].
  String? _activeDownload;

  /// Stops the running package download at once; its [downloadRelease]
  /// throws [ReleaseCancelled] once the worker has removed the file.
  void cancelReleaseDownload() {
    final request = _activeDownload;
    if (request != null) {
      _input?.send({'action': 'releaseCancel', 'request': request});
    }
  }

  /// The update feed's current release for [target] through the worker,
  /// which holds this device's certificate; null when none is published.
  Future<ReleaseManifest?> releaseManifest(String target) async {
    final event = await _release({
      'action': 'releaseCheck',
      'target': target,
    }, const Duration(seconds: 45));
    if (event['ok'] != true) throw CloudFailure(event['message'] as String);
    final manifest = event['manifest'];
    return manifest == null ? null : ReleaseManifest.fromJson(manifest, target);
  }

  /// Downloads [manifest]'s package to [destination] through the worker,
  /// which checks its size and SHA-256 while it streams; throws
  /// [ReleaseRefused] when they differ (the file is removed).
  Future<void> downloadRelease(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
  }) async {
    final command = <String, Object?>{
      'action': 'releaseDownload',
      'target': manifest.target,
      'manifest': manifest.toJson(),
      'path': destination.path,
    };
    // A package of up to 512 MiB at a slow but moving pace; the worker
    // abandons a stalled download long before this.
    String? request;
    final Map event;
    try {
      event = await _release(
        command,
        const Duration(hours: 2),
        progress: progress,
        sent: (id) => request = _activeDownload = id,
      );
    } finally {
      if (_activeDownload == request) _activeDownload = null;
    }
    if (event['ok'] == true) return;
    final message = event['message'] as String;
    if (event['cancelled'] == true) throw const ReleaseCancelled();
    throw event['refused'] == true
        ? ReleaseRefused(message)
        : CloudFailure(message);
  }

  void _closeLateDescriptor(int fd, Object? token) {
    try {
      platformAdapters().rootFilesystem(nativeLibrary).closeFd(fd);
    } catch (_) {}
    if (token is String) {
      _input?.send({
        'action': 'documents',
        'request': uniqueId(),
        'op': 'closed',
        'args': {'token': token},
      });
    }
  }

  /// Ask the gateway whether this account holds the admin role.
  Future<void> refreshAdmin() async {
    try {
      final response = await admin('GET', '/v1/account');
      final admin_ = response.status == 200 && response.map['admin'] == true;
      if (isAdmin && !admin_) adminNotice = 'Your admin role was removed.';
      if (admin_ != isAdmin) {
        isAdmin = admin_;
        notifyListeners();
      }
    } catch (_) {
      // Unpaired, offline or an older gateway: the section stays as it is.
    }
  }

  /// A 403 `not-admin` from any admin call hides the section at once.
  void adminRoleRemoved() {
    if (!isAdmin) return;
    isAdmin = false;
    adminNotice = 'Your admin role was removed.';
    notifyListeners();
  }

  /// The Downloader's state and actions (spec #42 F4), created when the UI
  /// first asks for it; from then on the gateway is probed once per session
  /// (at the next worker start or state report, while paired).
  FetchJobs get fetchJobs {
    final existing = _fetchJobs;
    if (existing != null) return existing;
    final created = _fetchJobs = FetchJobs(
      MessageFetchTransport(_fetchCommand),
      requestSync: requestSyncPass,
      preferences: FetchPreferences(profile),
    );
    // Not during the caller's build: the probe notifies.
    scheduleMicrotask(_probeFetch);
    return created;
  }

  FetchJobs? _fetchJobs;

  /// Probes the Downloader's availability for the paired server; a
  /// probe already answered for this server does nothing.
  void _probeFetch() {
    final jobs = _fetchJobs;
    if (jobs == null || _input == null) return;
    unawaited(jobs.probe(pairingState == 'paired' ? serverOrigin : null));
  }

  /// One fetch job request through the worker, which holds this device's
  /// certificate. Answered with the worker's `fetchResult` event, or with a
  /// failure made here when no worker can send it.
  Future<Map> _fetchCommand(Map<String, Object?> command) {
    final input = _input;
    if (input == null || pairingState != 'paired') {
      return Future.value({'ok': false, 'error': FetchError.notConnected.name});
    }
    final request = uniqueId();
    final result = Completer<Map>();
    _fetchRequests[request] = result;
    input.send({...command, 'request': request});
    return result.future.timeout(
      fetchTimeout,
      onTimeout: () {
        _fetchRequests.remove(request);
        return {'ok': false, 'error': FetchError.network.name};
      },
    );
  }

  /// Asks the worker for one sync pass that lists the cloud now (as when
  /// the window is shown), so a file the server just placed appears without
  /// waiting for the schedule. While paused it lists nothing.
  void requestSyncPass() => _input?.send({'action': 'visible'});

  /// Why Manage sharing is unavailable right now, or null (spec #26).
  String? get sharingUnavailable => pairingState != 'paired'
      ? 'Pair this device to manage sharing'
      : paused
      ? 'Resume sync to manage sharing'
      : status == SyncStatus.offline || _input == null
      ? 'Connect to the server to manage sharing'
      : accountRights == 'read'
      ? 'This device can only view'
      : null;

  /// One Manage sharing request (`load`, `create`, `update`, `remove`),
  /// sent by the worker through the pause gate.
  Future<Object?> sharing(
    String op, {
    String? path,
    String? recipient,
    String? permission,
    String? share,
  }) {
    final input = _input;
    if (input == null) {
      return Future.error(
        const CloudFailure('Sync is not running. Try again shortly.'),
      );
    }
    final request = uniqueId();
    final result = Completer<Object?>();
    _sharingRequests[request] = result;
    input.send({
      'action': 'sharing',
      'request': request,
      'op': op,
      'path': ?path,
      'recipient': ?recipient,
      'permission': ?permission,
      'share': ?share,
    });
    return result.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _sharingRequests.remove(request);
        throw const CloudFailure(
          'The server did not answer in time. Reopen to see the current state.',
        );
      },
    );
  }

  Future<Map<String, dynamic>> bulkCommand(
    String action,
    List<Map<String, dynamic>> targets,
  ) {
    if (!canCreateFolder) {
      return Future.error(
        const FileSystemException('Local storage is not ready.'),
      );
    }
    for (final target in targets) {
      validateRelative(target['path'] as String);
    }
    final request = uniqueId();
    final result = Completer<Map<String, dynamic>>();
    _bulkRequests[request] = result;
    _input!.send({
      'action': 'bulk',
      'value': action,
      'targets': targets,
      'request': request,
    });
    return result.future.timeout(
      folderCommandTimeout,
      onTimeout: () {
        _bulkRequests.remove(request);
        throw const FileSystemException(
          'Batch confirmation timed out. Check the library before retrying.',
        );
      },
    );
  }

  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {
    if (action == 'retention' || action == 'delete') {
      validateRelative(path);
    }
    _input?.send({
      'action': action,
      'path': path,
      'value': value,
      'sessions': sessions,
      // How Open will hand the working copy out (decision #184).
      if (action == 'open') 'providerTracked': launcher.handsOutThroughProvider,
    });
  }

  /// Spec #34 P1: a new profile with no stored root creates
  /// `<home>/anj-cloud/` without a picker. A refusal (overlap, or the folder
  /// already exists) is shown with **Use another folder**; nothing falls
  /// back to another location.
  Future<void> _automaticRoot() async {
    final parent = placement.defaultParent();
    if (parent == null) return;
    settingUpRoot = true;
    notifyListeners();
    try {
      await configureRoot(parent, automatic: true);
      rootProblem = null;
    } on FileSystemException catch (error) {
      rootProblem = error.path == null || error.message.contains(error.path!)
          ? error.message
          : '${error.message} (${error.path})';
    } catch (_) {
      rootProblem =
          'The anj-cloud folder could not be created in $parent. Use another folder.';
    } finally {
      settingUpRoot = false;
    }
    if (rootProblem != null) message = 'Use another folder to continue.';
    notifyListeners();
  }

  /// Refuses a [parent] that is not an existing folder, with the real reason:
  /// missing, not a folder (a file, or a path through one), or not readable.
  static void _checkParent(String parent) {
    final String resolved;
    try {
      resolved = Directory(parent).resolveSymbolicLinksSync();
    } on FileSystemException catch (error) {
      final os = error.osError;
      final detail = os == null || os.message.isEmpty ? '' : ': ${os.message}';
      final reason = switch (os?.errorCode) {
        2 || 3 => 'The parent folder does not exist. Create it, or choose a folder that does.',
        13 || 5 => 'The parent folder cannot be read: access is denied.',
        20 => 'The parent folder is not a folder (part of its path is a file).',
        _ => 'The parent folder cannot be used$detail.',
      };
      throw FileSystemException(reason, parent);
    }
    if (FileSystemEntity.typeSync(resolved) != FileSystemEntityType.directory) {
      throw FileSystemException(
        'The parent is a file, not a folder. Choose a folder.',
        parent,
      );
    }
  }

  /// Creates the root `<parent>/anj-cloud/` and starts sync. [automatic]
  /// (spec #34 P1) refuses an existing `anj-cloud/` instead of adopting it,
  /// except the one this profile began creating before an interruption.
  Future<void> configureRoot(
    String parent, {
    List<String> knownRoots = const [],
    bool automatic = false,
  }) async {
    // Said before anything is stopped or opened, in words rather than the
    // platform's "cannot resolve symbolic links".
    _checkParent(parent);
    await stop();
    final store = Manifest(profile);
    String? creating;
    try {
      if (store.setting('root') != null) {
        throw const FileSystemException(
          'This profile already owns a root. Use a separate profile to choose another.',
        );
      }
      var requireNew = false;
      if (automatic) {
        creating = p.join(
          Directory(parent).resolveSymbolicLinksSync(),
          'anj-cloud',
        );
        if (FileSystemEntity.typeSync(creating, followLinks: false) ==
            FileSystemEntityType.notFound) {
          store.setSetting('rootCreating', creating);
        }
        requireNew = store.setting('rootCreating') != creating;
      }
      final native = platformAdapters().rootFilesystem(nativeLibrary);
      final RootTree tree;
      try {
        // The platform's location rules first, so a refused place is never
        // created (macOS: protected, provider, snapshot, non-APFS).
        final refusal = rootLocation.refuseRoot(
          p.join(Directory(parent).resolveSymbolicLinksSync(), 'anj-cloud'),
        );
        if (refusal != null) throw FileSystemException(refusal, parent);
        tree = RootTree.setup(
          parent,
          store.setting('profileId')!,
          native,
          knownRoots: [...knownRoots, profile.resolveSymbolicLinksSync()],
          // Spec #34 P3: the placement decides (Linux and macOS stage in
          // the profile, Windows keeps the sibling).
          profileDir: placement.stagingInProfile
              ? profile.resolveSymbolicLinksSync()
              : null,
          requireNew: requireNew,
        );
      } catch (_) {
        if (creating != null &&
            FileSystemEntity.typeSync(creating, followLinks: false) ==
                FileSystemEntityType.notFound) {
          store.deleteSetting('rootCreating');
        }
        rethrow;
      }
      root = tree.root.path;
      store.transaction(() {
        store.setSetting('root', root!);
        store.setSetting('staging', tree.staging.path);
        store.setSetting('retention', 'local');
        store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
        store.deleteSetting('rootCreating');
      });
      tree.close();
    } finally {
      store.close();
    }
    rootProblem = null;
    // Async file calls only, so a macOS Desktop privacy prompt cannot freeze
    // the window (delta review I2). It runs before the worker starts: the
    // outcome is written to the manifest, which a running pass holds
    // (mac-test run 6: "database is locked" when written after start).
    await _desktopShortcut(root!);
    await start();
    notifyListeners();
  }

  /// Spec #34 P2: once per profile, when its root is created, a symbolic
  /// link **AnJ Cloud** to the synced folder in the desktop directory. The
  /// outcome is recorded in `desktopShortcut`, so a link the user deleted is
  /// never recreated; an existing entry of that name is never replaced. A
  /// refusal (macOS: the user denied Desktop access) is recorded as
  /// `failed` and never retried. The link calls are asynchronous, so they
  /// run off the UI isolate's thread.
  Future<void> _desktopShortcut(String target) async {
    if (_setting('desktopShortcut') != null) return;
    final outcome = await makeDesktopShortcut(
      target,
      placement.desktopDirectory(),
    );
    // The root is already committed: a failed save of the outcome (macOS:
    // a worker another path started while a Desktop prompt was pending
    // holds the manifest, "database is locked") leaves it unrecorded,
    // which reads like no shortcut, and never fails root setup (PR #100
    // review L1).
    try {
      final store = Manifest(profile);
      try {
        saveDesktopShortcutOutcome(store, outcome);
      } finally {
        store.close();
      }
    } catch (error) {
      stderr.writeln('anj-cloud: desktop shortcut outcome not saved: $error');
    }
  }

  String? _setting(String key) {
    final store = Manifest(profile);
    try {
      return store.setting(key);
    } finally {
      store.close();
    }
  }

  /// Pair this device with [address] using an invitation [code].
  ///
  /// A pinned code (decision #151, spec #35) carries the household CA's pin:
  /// the CA is fetched from the server, accepted only if it matches, and the
  /// server approves the device by itself; this waits for that approval.
  /// A legacy code (rule 6, until it expires) needs the trust anchor of an
  /// earlier pairing or [caPath], and the admin's fingerprint approval;
  /// pairing again with it collects the certificate once approved.
  Future<void> pair(String address, String code, {String? caPath}) async {
    busy = true;
    awaitingFingerprintApproval = false;
    notifyListeners();
    await stop();
    final store = Manifest(profile);
    PairingClient? client;
    try {
      final requestedOrigin = normalizeServerOrigin(address);
      final origin = Uri.parse(requestedOrigin);
      final boundOrigin = store.setting('accountOrigin');
      if (boundOrigin != null && requestedOrigin != boundOrigin) {
        throw const FormatException(
          'This root belongs to another server. Create a new profile; account migration is not supported.',
        );
      }
      final normalized = normalizeInvitation(code);
      final pin = invitationCaPin(normalized);
      final List<int> trust;
      String? pinnedCa;
      if (pin != null) {
        // A paired profile keeps its trust anchor: a code pinned to any other
        // CA is refused before anything is fetched (spec #35 review L2).
        final anchor = ca;
        if (boundOrigin != null && anchor != null && anchor.isNotEmpty) {
          List<int>? der;
          try {
            der = singleCertificateDer(await File(anchor).readAsBytes());
          } on FileSystemException {
            der = null;
          }
          if (der == null || !samePin(caPinOf(der), pin)) {
            throw const PairingRefused(notThisServer);
          }
        }
        // Rule 2: nothing is stored unless the server's CA matches the code.
        pinnedCa = await fetchPinnedCa(origin, pin);
        trust = utf8.encode(pinnedCa);
      } else {
        final legacy = (caPath != null && caPath.isNotEmpty) ? caPath : ca;
        if (legacy == null || legacy.isEmpty) {
          throw const PairingRefused(
            'This is an older code that needs a CA file. Ask for a new code.',
          );
        }
        trust = await File(legacy).readAsBytes();
      }
      final identity = DeviceIdentity(store, secrets);
      await identity.prepare();
      fingerprint = store.setting('fingerprint');
      if (store.setting('keyRecovery') != null) {
        pairingState = 'new device key; obtain a new invitation';
      }
      client = PairingClient(
        origin,
        await identity.contextFor(trust, clientIdentity: false),
      );
      await secrets.write(identity.invitationRef, normalized);
      final csr = store.setting('csr')!;
      var result = await client.enroll(
        normalized,
        csr,
        label: await _deviceLabel(),
      );
      // A legacy code keeps today's behaviour: the anchor it used is the
      // profile's from the first answer. A pinned code's CA becomes the
      // profile's trust anchor only once the device is paired (review L2).
      final String? legacyAnchor = pinnedCa == null
          ? p.absolute((caPath != null && caPath.isNotEmpty) ? caPath : ca!)
          : null;
      if (legacyAnchor != null) {
        server = requestedOrigin;
        ca = legacyAnchor;
        store.setSetting('server', requestedOrigin);
        store.setSetting('ca', legacyAnchor);
      }
      if (pin != null) {
        final deadline = DateTime.now().add(pairingWait);
        while (result['state'] == 'pending' &&
            DateTime.now().isBefore(deadline)) {
          pairingState = 'pending';
          message = 'Waiting for the server to approve this device…';
          notifyListeners();
          await Future<void>.delayed(pairingPoll);
          result = await client.enroll(normalized, csr);
        }
      }
      pairingState = result['state'] as String;
      if (result['fingerprint'] != null &&
          result['fingerprint'] != fingerprint) {
        throw const FormatException('Server pairing fingerprint differs.');
      }
      if (pairingState == 'approved') {
        final uid = result['uid'];
        final rights = result['rights'];
        final deviceId = result['device_id'];
        if (uid is! String ||
            uid.isEmpty ||
            (rights != 'read' && rights != 'write') ||
            deviceId is! String ||
            deviceId.isEmpty) {
          throw const FormatException(
            'Approval omitted the authoritative account binding.',
          );
        }
        final previousUid = store.setting('accountUid');
        if (previousUid != null && previousUid != uid) {
          throw const FormatException(
            'This root belongs to another account. Create a new profile; account migration is not supported.',
          );
        }
        final expiry = await identity.verifyCertificate(
          result['certificate'] as String,
          result['fingerprint'] as String,
        );
        final trustPath = legacyAnchor ?? _storePinnedCa(pinnedCa!);
        server = requestedOrigin;
        ca = trustPath;
        // A device's first pairing shows the folder screen before any sync
        // (decision #118); once confirmed, a re-pair never does. "First"
        // means the screen was never confirmed and nothing is synchronized:
        // the unpaired worker may already have recorded local rows (Android
        // starts it at first open), and a key reset before the choice pairs
        // again with the account binding kept.
        final firstSync =
            pairingOptions.firstSync != null &&
            store.setting(firstSyncSetting) != 'done' &&
            store.entries.values.every((entry) => entry.etag == null);
        store.transaction(() {
          if (firstSync) store.setSetting(firstSyncSetting, 'pending');
          store.deleteSetting('keyRecovery');
          store.setSetting('certificate', result['certificate'] as String);
          store.setSetting('certificateExpires', expiry.toIso8601String());
          store.setSetting('accountUid', uid);
          store.setSetting('accountOrigin', requestedOrigin);
          store.setSetting('accountRights', rights.toString());
          accountRights = rights.toString();
          store.setSetting('deviceId', deviceId);
          store.setSetting('server', requestedOrigin);
          store.setSetting('ca', trustPath);
        });
        if (firstSync) firstSyncPending = true;
        await secrets.delete(identity.invitationRef);
        // The device holds a certificate now: it is paired, as a restart
        // would read it. 'approved' is only the enrollment answer; leaving
        // it here kept admin() (and with it the Admin check on the worker's
        // ready event and the 5-minute timer) refusing every call until a
        // restart (SC-063).
        pairingState = 'paired';
      }
      awaitingFingerprintApproval = pin == null && pairingState == 'pending';
      message = pairingState == 'paired'
          ? 'Paired.'
          : pairingState != 'pending'
          ? 'Pairing: $pairingState'
          : pin == null
          ? 'Ask your admin to approve the fingerprint below, then press Pair again.'
          : 'The server has not approved this device yet. Press Pair again to keep waiting.';
    } on PairingRefused catch (refusal) {
      message = refusal.message;
      rethrow;
    } on CloudFailure catch (failure) {
      message = failure.status == 400
          ? 'Code not valid. Ask for a new code.'
          : failure.status == 429
          ? pairingLimitMessage(failure.retryAfter)
          : 'Pairing failed. Check the server address and the network, then try again. Retry uses the same device key.';
      rethrow;
    } on SecretStoreUnavailable catch (error) {
      message = error.message;
      rethrow;
    } on FormatException catch (error) {
      message = error.message;
      rethrow;
    } catch (_) {
      message = 'Pairing failed. Check the server address, the code, the network and the keyring. Retry uses the same device key.';
      // A secret store that stopped working (Android Keystore): offer the
      // reset instead of a pairing that can only fail again (PR #60 F5).
      final keyRef = store.setting('profileId') == null
          ? null
          : DeviceIdentity(store, secrets).privateKeyRef;
      if (keyRef != null && canResetIdentity) await _probeSecrets(keyRef);
      rethrow;
    } finally {
      // The form keeps this outcome: the restarted worker replaces [message].
      pairingMessage = message;
      client?.close();
      store.close();
      busy = false;
      await start();
      notifyListeners();
    }
  }

  /// Reads the device key once to learn whether the store works at all.
  Future<void> _probeSecrets(String keyRef) async {
    try {
      await secrets.read(keyRef);
      keyUnavailable = false;
    } catch (_) {
      keyUnavailable = true;
    }
  }

  /// "Reset this device's pairing" (PR #60 review F5): the device key cannot
  /// be read, so the secret store is wiped by the platform's route around it
  /// and the device pairs again with a new key, which an admin approves
  /// again. The profile records the key recovery first (the reset may
  /// restart the app); the account binding, the root and its files stay.
  Future<void> resetDeviceIdentity() async {
    final secrets = this.secrets;
    if (secrets is! SecretStoreReset) {
      throw UnsupportedError('This platform cannot reset its secret store.');
    }
    if (!keyUnavailable) {
      throw StateError('The device key is readable; nothing to reset.');
    }
    await stop();
    final store = Manifest(profile);
    try {
      store.transaction(() {
        for (final key in [
          'csr',
          'fingerprint',
          'certificate',
          'certificateExpires',
        ]) {
          store.deleteSetting(key);
        }
        store.setSetting('keyRecovery', 'new invitation required');
        // A reset before the folder choice: pairing comes first again, and
        // the next approval shows the folder screen again.
        if (store.setting(firstSyncSetting) == 'pending') {
          store.deleteSetting(firstSyncSetting);
        }
      });
    } finally {
      store.close();
    }
    fingerprint = null;
    firstSyncPending = false;
    pairingState = 'new device key; obtain a new invitation';
    await (secrets as SecretStoreReset).resetAll();
    keyUnavailable = false;
    message =
        "This device's key was reset. Ask your admin for a new pairing code.";
    notifyListeners();
    await start();
    notifyListeners();
  }

  Future<String> _deviceLabel() async {
    // The platform's own name for this device (pairing options, then the
    // adapter's label: macOS's Computer Name, the host name elsewhere),
    // clipped as the gateway counts (spec #31 M3's pairingLabel).
    String label;
    try {
      label = await (pairingOptions.deviceLabel?.call() ?? deviceLabel());
    } catch (_) {
      label = '';
    }
    label = pairingLabel(label).trim();
    if (label.isEmpty) label = pairingLabel(Platform.localHostname);
    return label;
  }

  /// The verified household CA as the profile's trust anchor file.
  String _storePinnedCa(String pem) {
    final target = File(p.join(profile.path, 'household-ca.crt'));
    final temporary = File('${target.path}.tmp');
    temporary.writeAsStringSync(pem, flush: true);
    temporary.renameSync(target.path);
    return target.path;
  }

  /// The first-sync screen's listing (decisions #118, #163): the root and
  /// inside Documents, Music and Videos, with sizes, over this device's new
  /// certificate. Only while
  /// [firstSyncPending]; no worker runs, so this is the only request.
  Future<FirstSyncListing> firstSyncListing() async {
    if (!firstSyncPending) {
      throw const CloudFailure('The first sync was already chosen.');
    }
    final store = Manifest(profile);
    final identity = DeviceIdentity(store, secrets);
    DavCloud? cloud;
    try {
      cloud = DavCloud(
        Uri.parse(store.setting('server')!),
        await identity.context(File(store.setting('ca')!)),
      );
      final top = await cloud.topLevel();
      final inside = {
        for (final item in top.items)
          if (item.kind == ItemKind.directory && isTopFolder(item.path))
            item.path: await cloud.levelWithSizes(item.path),
      };
      return FirstSyncListing.fromListings(top.items, top.sizes, inside);
    } catch (_) {
      // The key may have become unreadable before the choice: the screen
      // then offers the reset instead of stranding the user (F2).
      if (canResetIdentity) {
        await _probeSecrets(identity.privateKeyRef);
        notifyListeners();
      }
      rethrow;
    } finally {
      cloud?.client.close(force: true);
      store.close();
    }
  }

  /// Records the first-sync choice (paths in [keepLocal] stay Local, the
  /// rest of [folders] are Cloud; decision #163) and starts sync.
  Future<void> confirmFirstSync(
    Iterable<String> folders,
    Set<String> keepLocal,
  ) async {
    if (!firstSyncPending) return;
    final store = Manifest(profile);
    try {
      applyFirstSyncChoice(store, folders, keepLocal);
    } finally {
      store.close();
    }
    firstSyncPending = false;
    message = 'Starting sync.';
    notifyListeners();
    await start();
    notifyListeners();
  }

  @override
  void dispose() {
    _adminPoll?.cancel();
    _fetchJobs?.dispose();
    unawaited(stop());
    super.dispose();
  }
}

/// The canonical HTTPS origin for a pairing [address]. Surrounding whitespace
/// is ignored and a missing scheme defaults to HTTPS. Raw authority validation
/// happens before [Uri] can canonicalize it: encoded/backslash forms, credentials,
/// malformed ports, non-root paths, queries and fragments are rejected. IPv6
/// literals must be bracketed so they cannot be misread as a host and port.
String normalizeServerOrigin(String address) {
  final input = address.trim();
  Never invalid() => throw const FormatException(
    'Use an HTTPS server origin without a path, credentials, query or fragment.',
  );

  if (input.isEmpty ||
      input.contains(RegExp(r'\s')) ||
      input.contains('%') ||
      input.contains('\\')) {
    invalid();
  }
  final explicitScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://')
      .firstMatch(input);
  if (explicitScheme != null &&
      explicitScheme.group(0)!.toLowerCase() != 'https://') {
    invalid();
  }
  final remainder = input.substring(explicitScheme?.end ?? 0);
  final delimiter = remainder.indexOf(RegExp(r'[/?#]'));
  final authority = delimiter < 0
      ? remainder
      : remainder.substring(0, delimiter);
  final suffix = delimiter < 0 ? '' : remainder.substring(delimiter);
  if (authority.isEmpty ||
      authority.contains('@') ||
      (suffix.isNotEmpty && suffix != '/')) {
    invalid();
  }

  String? rawPort;
  if (authority.startsWith('[')) {
    final closing = authority.indexOf(']');
    if (closing < 0) invalid();
    final literal = InternetAddress.tryParse(authority.substring(1, closing));
    if (literal == null || literal.type != InternetAddressType.IPv6) invalid();
    final after = authority.substring(closing + 1);
    if (after.isNotEmpty) {
      if (!after.startsWith(':')) invalid();
      rawPort = after.substring(1);
    }
  } else {
    if (authority.contains('[') || authority.contains(']')) invalid();
    final separator = authority.indexOf(':');
    if (separator >= 0 && authority.indexOf(':', separator + 1) >= 0) {
      invalid();
    }
    final host = separator < 0 ? authority : authority.substring(0, separator);
    if (host.isEmpty) invalid();
    if (separator >= 0) rawPort = authority.substring(separator + 1);
  }
  final port = rawPort == null ? null : int.tryParse(rawPort);
  if (rawPort != null &&
      (!RegExp(r'^[0-9]+$').hasMatch(rawPort) ||
          port == null ||
          port > 65535)) {
    invalid();
  }

  final origin = Uri.parse('https://$authority$suffix');
  if (origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      (origin.path.isNotEmpty && origin.path != '/')) {
    invalid();
  }
  return origin.origin;
}

/// The pairing label the gateway accepts: control characters removed and at
/// most 80 characters (code points, as the gateway counts them). A Linux
/// host name passes unchanged when 80 characters or fewer, as before.
String pairingLabel(String label) => String.fromCharCodes(
  label.runes.where((c) => c >= 32 && c != 127).take(80),
);
