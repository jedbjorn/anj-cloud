import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/controller.dart';
import '../ports/self_update.dart';
import 'release.dart';
import 'update_blocker.dart';

export 'update_blocker.dart' show controllerUpdateBlocker, updateStartsWhen;

/// Where the updater's checks and downloads go: in the app, the
/// controller's worker, which holds this device's certificate.
abstract interface class UpdateFeed implements Listenable {
  /// True while the feed can be asked (paired, worker running).
  bool get ready;
  Future<ReleaseManifest?> latest(String target);
  Future<void> download(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
  });
}

class ControllerUpdateFeed implements UpdateFeed {
  ControllerUpdateFeed(this.controller);
  final ClientController controller;
  @override
  bool get ready => controller.releaseFeedReady;
  @override
  Future<ReleaseManifest?> latest(String target) =>
      controller.releaseManifest(target);
  @override
  Future<void> download(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
  }) => controller.downloadRelease(manifest, destination, progress: progress);
  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}

enum DesktopUpdatePhase {
  /// This build cannot update itself (no receipt, no release key, not
  /// started by the installed manager).
  off,

  /// Nothing to offer.
  idle,

  /// A newer release is downloading in the background.
  downloading,

  /// Downloaded and verified: **Update available — Update now / Later**.
  ready,

  /// Update now was chosen; waiting for syncing or Finish editing to end.
  waiting,

  /// Handed to the installed manager; the app is quitting.
  installing,
}

/// The desktop in-app updater (spec #37 U-linux, decision #159). It checks
/// the household server's feed when the feed becomes ready (the app's start)
/// and every [checkEvery]; downloads a newer release in the background into
/// the profile's private [directory]; verifies it (Ed25519 signature against
/// the key built into this app, size, SHA-256, target, version code, then
/// the installed manager's own check); then shows one notice. Nothing is
/// installed without **Update now**. Any failed verification discards the
/// download and says only "Update could not be verified" in the status.
class DesktopUpdater extends ChangeNotifier {
  DesktopUpdater({
    required this.feed,
    required this.port,
    required this.directory,
    required this.loadKey,
    required this.quit,
    required this.blocker,
    this.busySignal,
    this.checkEvery = const Duration(hours: 6),
  });

  final UpdateFeed feed;
  final SelfUpdatePort port;

  /// `<profile>/updates`: private staging the manager also checks.
  final Directory directory;

  /// The built-in release key file's text (an asset); null when absent.
  final Future<String?> Function() loadKey;

  /// Quits the app cleanly (the lifecycle's Quit).
  final Future<void> Function() quit;

  /// Why an install must wait; null when it may start (see
  /// [controllerUpdateBlocker]).
  final String? Function() blocker;

  /// Notifies when [blocker] may have changed (the controller).
  final Listenable? busySignal;
  final Duration checkEvery;

  DesktopUpdatePhase phase = DesktopUpdatePhase.off;
  InstalledBuild? installed;
  ReleaseKey? key;

  /// The verified release on offer (ready, waiting, installing).
  ReleaseManifest? offered;

  /// The server's newest release advertises a minimum version above this
  /// one (spec #37 rule 5): shown as "Update required".
  bool required = false;

  /// Later was chosen for [offered]; the notice returns at the next
  /// scheduled check.
  bool dismissed = false;

  /// Status line: "Update could not be verified" or "Update could not be
  /// installed"; [detail] keeps the reason (shown on request).
  String? problem;
  String? detail;

  /// "Updated to version X" once after a successful update.
  String? updated;

  Timer? _timer;
  bool _checking = false;
  bool _wasReady = false;

  bool get enabled => phase != DesktopUpdatePhase.off;

  static const verifyFailed = 'Update could not be verified';
  static const installFailed = 'Update could not be installed';

  File _archive(ReleaseManifest manifest) =>
      File('${directory.path}/${manifest.versionCode}.tar.gz');
  File _manifestFile(ReleaseManifest manifest) =>
      File('${directory.path}/${manifest.versionCode}.json');
  File get _result => File('${directory.path}/result.json');

  Future<void> start() async {
    try {
      installed = await port.installed();
      final text = await loadKey();
      key = text == null ? null : ReleaseKey.parse(text);
    } on FormatException {
      key = null;
    }
    _readResult();
    _clear();
    if (installed == null || key == null) {
      // A development build, or one made before the household key existed:
      // no checks, no notices.
      phase = DesktopUpdatePhase.off;
      notifyListeners();
      return;
    }
    phase = DesktopUpdatePhase.idle;
    feed.addListener(_feedChanged);
    _timer = Timer.periodic(
      checkEvery,
      (_) => unawaited(check(scheduled: true)),
    );
    notifyListeners();
    _feedChanged();
  }

  /// The manager's outcome from the previous run's Update now.
  void _readResult() {
    try {
      if (!_result.existsSync()) return;
      final data = jsonDecode(_result.readAsStringSync());
      if (data is Map && data['ok'] == true) {
        updated = 'Updated to version ${data['version']}';
      } else {
        problem = installFailed;
        detail = data is Map ? '${data['message']}' : null;
      }
    } on Object {
      problem = installFailed;
    }
  }

  /// Every file in the staging folder (a previous run's download or
  /// result); the folder is created private for the manager's check.
  void _clear() {
    try {
      if (directory.existsSync()) {
        for (final entry in directory.listSync()) {
          entry.deleteSync(recursive: true);
        }
      }
    } on FileSystemException {
      // Retried at the next download; a stale file is never trusted.
    }
  }

  void _feedChanged() {
    final ready = feed.ready;
    if (ready && !_wasReady) unawaited(check());
    _wasReady = ready;
  }

  /// One feed check (silent: an unreachable server just waits for the next).
  /// [scheduled]: the 6-hourly check, which brings a dismissed notice back.
  Future<void> check({bool scheduled = false}) async {
    final build = installed;
    if (_checking ||
        build == null ||
        !feed.ready ||
        phase == DesktopUpdatePhase.off ||
        phase == DesktopUpdatePhase.downloading ||
        phase == DesktopUpdatePhase.waiting ||
        phase == DesktopUpdatePhase.installing) {
      return;
    }
    _checking = true;
    try {
      final latest = await feed.latest(build.target);
      // Update now may have been chosen while the server answered (review
      // M2): the files handed to the manager are never touched again.
      if (!_mayChangeOffer) return;
      final floor = latest?.minClientVersionCode;
      required = floor != null && build.versionCode < floor;
      if (latest == null || latest.versionCode <= build.versionCode) {
        _discardOffer();
        phase = DesktopUpdatePhase.idle;
        notifyListeners();
        return;
      }
      if (phase == DesktopUpdatePhase.ready && latest == offered) {
        if (scheduled && dismissed) dismissed = false;
        notifyListeners();
        return;
      }
      await _fetch(latest);
    } on Object {
      // Offline, server restarting, an unreadable record: next check.
    } finally {
      _checking = false;
    }
  }

  /// Only idle or offering: never while waiting to install or installing,
  /// when the offered files belong to the hand-over.
  bool get _mayChangeOffer =>
      phase == DesktopUpdatePhase.idle || phase == DesktopUpdatePhase.ready;

  Future<void> _fetch(ReleaseManifest latest) async {
    if (!_mayChangeOffer) return;
    final build = installed!;
    final refusal = desktopRefusal(
      latest,
      key,
      build.versionCode,
      build.target,
    );
    if (refusal != null) return _unverified(refusal);
    _discardOffer();
    phase = DesktopUpdatePhase.downloading;
    notifyListeners();
    final archive = _archive(latest);
    final manifest = _manifestFile(latest);
    try {
      await directory.create(recursive: true);
      await port.prepare(directory);
      await feed.download(latest, archive);
      await manifest.writeAsString(jsonEncode(latest.toJson()), flush: true);
      // The installed manager verifies exactly what it will install.
      await port.check(archive, manifest);
    } on ReleaseRefused catch (error) {
      return _unverified(error.message);
    } on SelfUpdateFailure catch (error) {
      return _unverified(error.message);
    } on Object {
      _delete(latest);
      phase = DesktopUpdatePhase.idle;
      notifyListeners();
      return;
    }
    offered = latest;
    dismissed = false;
    problem = detail = null;
    phase = DesktopUpdatePhase.ready;
    notifyListeners();
  }

  void _unverified(String reason) {
    _clear();
    offered = null;
    problem = verifyFailed;
    detail = reason;
    phase = DesktopUpdatePhase.idle;
    notifyListeners();
  }

  void _delete(ReleaseManifest manifest) {
    for (final file in [_archive(manifest), _manifestFile(manifest)]) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // Cleared at the next start.
      }
    }
  }

  void _discardOffer() {
    final previous = offered;
    if (previous != null) _delete(previous);
    offered = null;
  }

  /// Later: hide the notice until the next scheduled check.
  void later() {
    if (phase != DesktopUpdatePhase.ready) return;
    dismissed = true;
    notifyListeners();
  }

  /// Update now: once nothing is syncing and no Finish editing is pending,
  /// hand over to the manager and quit cleanly.
  Future<void> updateNow() async {
    final release = offered;
    if (phase != DesktopUpdatePhase.ready || release == null) return;
    phase = DesktopUpdatePhase.waiting;
    notifyListeners();
    await _idle();
    if (phase != DesktopUpdatePhase.waiting) return; // cancelled meanwhile
    phase = DesktopUpdatePhase.installing;
    notifyListeners();
    try {
      await port.handOver(_archive(release), _manifestFile(release), _result);
    } on SelfUpdateFailure catch (error) {
      problem = installFailed;
      detail = error.message;
      phase = DesktopUpdatePhase.ready;
      notifyListeners();
      return;
    }
    await quit();
  }

  /// Back from waiting to the offer.
  void cancelWaiting() {
    if (phase != DesktopUpdatePhase.waiting) return;
    phase = DesktopUpdatePhase.ready;
    notifyListeners();
  }

  /// What an install currently waits for (shown while [phase] is waiting).
  String? get waitingFor => blocker();

  Future<void> _idle() async {
    if (blocker() == null) return;
    final done = Completer<void>();
    void changed() {
      if (!done.isCompleted &&
          (blocker() == null || phase != DesktopUpdatePhase.waiting)) {
        done.complete();
      }
    }

    busySignal?.addListener(changed);
    addListener(changed);
    // Also re-checked periodically: not every change notifies.
    final poll = Timer.periodic(const Duration(seconds: 1), (_) => changed());
    try {
      await done.future;
    } finally {
      poll.cancel();
      busySignal?.removeListener(changed);
      removeListener(changed);
    }
    notifyListeners();
  }

  /// The banner: null when nothing is to be shown.
  String? get notice {
    final release = offered;
    if (release == null) return null;
    final label = required ? 'Update required' : 'Update available';
    return switch (phase) {
      DesktopUpdatePhase.ready when !dismissed =>
        '$label (version ${release.version})',
      DesktopUpdatePhase.waiting => updateStartsWhen(
        release.version,
        waitingFor,
      ),
      DesktopUpdatePhase.installing =>
        'Installing version ${release.version}: AnJ Cloud restarts by itself…',
      _ => null,
    };
  }

  /// The status line beside sync status: a failure, "Update required"
  /// without a verified offer, or a completed update.
  String? get status {
    if (problem != null) return problem;
    if (required && offered == null) return 'Update required';
    return updated;
  }

  void dismissStatus() {
    problem = detail = updated = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    feed.removeListener(_feedChanged);
    super.dispose();
  }
}
