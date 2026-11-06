import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../ports/package_installer.dart';
import '../ports/transfer_policy.dart';
import '../state/model.dart';
import 'release.dart';
import 'update_blocker.dart';

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

  /// Stops the running [download]; it then throws [ReleaseCancelled].
  void cancelDownload();
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
  void cancelDownload() => controller.cancelReleaseDownload();
  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}

enum UpdatePhase {
  /// Nothing to show.
  idle,

  /// A check the user asked for is running (automatic checks are silent).
  checking,

  /// The user asked and the installed version is current.
  upToDate,

  /// A newer release is on the server; nothing is downloaded yet.
  available,

  /// The network setting holds the download (A4: "Waiting for Wi-Fi").
  waiting,
  downloading,

  /// The verified update waits until no file is moving and no Finish
  /// editing is pending (spec #37 rule 4, as on desktop): installing
  /// restarts the app. [AppUpdater.message] says what it waits for.
  waitingForSync,

  /// Signer, package and version checks on the downloaded file.
  verifying,

  /// Android needs "Install unknown apps" for AnJ Cloud first.
  permission,

  /// Android's own confirmation is showing.
  installing,

  /// The user declined Android's confirmation; the verified file is kept.
  declined,

  /// A check failed and the file was discarded; [AppUpdater.message] says why.
  refused,

  /// The check, download or installer failed; [AppUpdater.message] says why.
  failed,
}

/// The in-app updater (spec #28 A7, decisions #108 Q6 and #131). It checks
/// the household server's feed when the app opens, every [checkEvery] while
/// it runs and when the user asks. Nothing is downloaded or installed
/// without the user: Download and install starts the download, every check
/// runs before Android is asked anything, and Android's own confirmation is
/// the approval of the install itself.
///
/// The downloaded package lives in app-private cache ([downloads]) only
/// while this process runs: start clears it, and any failed check removes
/// it at once.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    required this.feed,
    required this.installer,
    required this.downloads,
    this.policy = const AnyNetworkPolicy(),
    this.target = androidReleaseTarget,
    this.checkEvery = const Duration(hours: 6),
    this.recheckAfter = const Duration(minutes: 15),
    this.installGrace = const Duration(seconds: 60),
    this.blocker,
    this.busySignal,
    this.policyRecheck = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final UpdateFeed feed;
  final PackageInstallerPort installer;
  final Directory downloads;

  /// The network setting's hook for the download (A4 wires its own).
  final TransferPolicy policy;
  final String target;
  final Duration checkEvery;

  /// Opening the app again checks only when the last check is older.
  final Duration recheckAfter;

  /// Back in the app while Android's confirmation is still unanswered (left
  /// with Home, or it never opened): after this long in the foreground the
  /// session is abandoned, so the panel never waits forever.
  final Duration installGrace;

  /// What the install must not interrupt; null when nothing (the app wires
  /// `controllerUpdateBlocker`, shared with the desktop updater).
  final String? Function()? blocker;

  /// Notifies when [blocker] may have changed (the controller).
  final Listenable? busySignal;

  /// How often a running download asks [policy] again, so a switch to
  /// mobile data under "Wi-Fi only" stops it (review L4).
  final Duration policyRecheck;
  final DateTime Function() _now;

  UpdatePhase phase = UpdatePhase.idle;

  /// The release on offer (or being downloaded, verified, installed).
  ReleaseManifest? manifest;

  /// The installed app, from the most recent check.
  PackageFacts? installedApp;
  int received = 0;
  String? message;

  Timer? _timer;
  DateTime? _lastCheck;
  bool _checking = false;
  bool _wasReady = false;
  File? _verified;
  bool _cancelling = false;
  Timer? _installTimer;

  /// Bumped when an install is cancelled, so its late answer is ignored.
  int _installAttempt = 0;

  static const _working = {
    UpdatePhase.downloading,
    UpdatePhase.verifying,
    UpdatePhase.installing,
  };

  /// Downloading, verifying or installing: no new check or action starts.
  bool get busy => _working.contains(phase);

  void start() {
    _clearDownloads();
    // Sessions a killed process left behind hold their copy of the package.
    unawaited(installer.discardSessions().catchError((Object _) {}));
    feed.addListener(_feedChanged);
    _timer = Timer.periodic(checkEvery, (_) => unawaited(check()));
    _feedChanged();
  }

  /// The first moment the feed can be asked is the app's opening check.
  void _feedChanged() {
    final ready = feed.ready;
    if (ready && !_wasReady) unawaited(check());
    _wasReady = ready;
  }

  /// The app came to the foreground: back from the "Install unknown apps"
  /// screen, the install continues; otherwise a check when one is due.
  Future<void> resumed() async {
    if (phase == UpdatePhase.installing) {
      _installTimer?.cancel();
      _installTimer = Timer(installGrace, () {
        if (phase == UpdatePhase.installing) unawaited(cancelInstall());
      });
      return;
    }
    if (phase == UpdatePhase.permission) {
      if (await installer.canRequestInstalls()) await _install();
      return;
    }
    final last = _lastCheck;
    if (last == null || _now().difference(last) >= recheckAfter) {
      await check();
    }
  }

  /// The app left the foreground (Android's confirmation in front of it,
  /// or the user went elsewhere): no install timeout runs meanwhile.
  void left() {
    _installTimer?.cancel();
    _installTimer = null;
  }

  Future<void> check({bool manual = false}) async {
    if (_checking || busy) return;
    if (!feed.ready) {
      if (manual) {
        _set(UpdatePhase.failed, 'Pair this device to check for updates.');
      }
      return;
    }
    _checking = true;
    final before = phase;
    if (manual) _set(UpdatePhase.checking);
    try {
      final installed = installedApp = await installer.installed();
      final latest = await feed.latest(target);
      _lastCheck = _now();
      if (latest == null || latest.versionCode <= installed.versionCode) {
        _discardVerified();
        manifest = null;
        _set(manual ? UpdatePhase.upToDate : UpdatePhase.idle);
      } else if (!manual &&
          latest == manifest &&
          const {
            UpdatePhase.available,
            UpdatePhase.waiting,
            UpdatePhase.waitingForSync,
            UpdatePhase.permission,
            UpdatePhase.declined,
            UpdatePhase.refused,
          }.contains(before)) {
        // The same release: keep what the user is looking at, including the
        // reason a download of it was refused.
      } else {
        if (latest != manifest) _discardVerified();
        manifest = latest;
        _set(UpdatePhase.available);
      }
    } catch (error) {
      // Automatic checks fail silently (offline, server restarting); the
      // next one retries.
      if (manual) {
        _set(UpdatePhase.failed, 'Could not check for updates: $error');
      }
    } finally {
      _checking = false;
    }
  }

  /// The user's approval to fetch the offered release. Verification follows
  /// at once; Android then asks the user to confirm the install.
  Future<void> downloadAndInstall() async {
    final release = manifest;
    if (release == null || busy || _checking) return;
    final blocked = await policy.transferBlocked();
    if (blocked != null) {
      _set(UpdatePhase.waiting, blocked);
      return;
    }
    _discardVerified();
    _clearDownloads();
    // The download and the installer's session copy exist at once.
    final needed = 2 * release.size;
    int? free;
    try {
      free = await installer.freeBytes(downloads.path);
    } catch (_) {
      free = null;
    }
    if (free != null && free < needed) {
      _set(
        UpdatePhase.failed,
        'Not enough free space for the update: it needs ${sizeLabel(needed)} '
        'free and ${sizeLabel(free)} is available. Free up space, then check '
        'again.',
      );
      return;
    }
    final file = File(
      p.join(downloads.path, 'anj-cloud-${release.versionCode}.apk'),
    );
    received = 0;
    _cancelling = false;
    String? heldBy;
    _set(UpdatePhase.downloading);
    // The network can change under a running download: under "Wi-Fi only"
    // leaving Wi-Fi stops it, as for every other transfer.
    var asking = false;
    final recheck = Timer.periodic(policyRecheck, (_) async {
      if (asking || heldBy != null || phase != UpdatePhase.downloading) return;
      asking = true;
      try {
        final reason = await policy.transferBlocked();
        if (reason != null && phase == UpdatePhase.downloading) {
          heldBy = reason;
          _cancelling = true;
          feed.cancelDownload();
        }
      } catch (_) {
        /* Asked again at the next tick. */
      } finally {
        asking = false;
      }
    });
    try {
      await feed.download(
        release,
        file,
        progress: (bytes) {
          received = bytes;
          notifyListeners();
        },
      );
    } on ReleaseRefused catch (refusal) {
      _remove(file);
      _set(UpdatePhase.refused, refusal.message);
      return;
    } catch (error) {
      _remove(file);
      final held = heldBy;
      if (held != null) {
        _set(UpdatePhase.waiting, held);
      } else if (error is ReleaseCancelled || _cancelling) {
        // Back to the offer; Download and install starts afresh.
        _set(UpdatePhase.available);
      } else {
        _set(UpdatePhase.failed, 'The update could not be downloaded: $error');
      }
      return;
    } finally {
      recheck.cancel();
      _cancelling = false;
    }
    // A download that completed as the network changed needs no more
    // bytes: it goes on to verification.
    _verified = file;
    await _verifyAndInstall();
  }

  /// Cancel while downloading.
  void cancelDownload() {
    if (phase != UpdatePhase.downloading) return;
    _cancelling = true;
    feed.cancelDownload();
  }

  /// Cancel while Android's confirmation is pending (or never opened):
  /// abandons the session and keeps the verified file for Install again.
  Future<void> cancelInstall() async {
    if (phase != UpdatePhase.installing) return;
    _installAttempt++;
    left();
    try {
      await installer.cancelInstall();
    } catch (_) {
      /* The session is gone either way at the next start. */
    }
    _set(UpdatePhase.declined);
  }

  /// After a declined confirmation: verify the kept file again and ask
  /// Android again.
  Future<void> installAgain() async {
    if (phase != UpdatePhase.declined || _verified == null) return;
    await _verifyAndInstall();
  }

  Future<void> _verifyAndInstall() async {
    final release = manifest;
    final file = _verified;
    if (release == null || file == null) return;
    _set(UpdatePhase.verifying);
    String? reason;
    try {
      final installed = installedApp = await installer.installed();
      reason = androidRefusal(
        release,
        installed,
        await installer.inspect(file.path),
      );
    } catch (_) {
      reason = 'The download could not be checked.';
    }
    if (reason != null) {
      _discardVerified();
      _set(UpdatePhase.refused, reason);
      return;
    }
    await _install();
  }

  Future<void> _install() async {
    final release = manifest;
    final file = _verified;
    if (release == null || file == null) return;
    // Installing replaces and restarts the app: never during an upload or
    // a pending Finish editing (review M3; the desktop updater's rule).
    if (!await _syncIdle(release)) return;
    if (!await installer.canRequestInstalls()) {
      _set(UpdatePhase.permission);
      return;
    }
    _set(UpdatePhase.installing);
    final attempt = ++_installAttempt;
    InstallResult result;
    try {
      result = await installer.install(
        file.path,
        sha256: release.sha256,
        size: release.size,
      );
    } catch (error) {
      result = InstallResult(InstallOutcome.failed, '$error');
    }
    if (attempt != _installAttempt) return; // cancelled meanwhile
    left();
    switch (result.outcome) {
      case InstallOutcome.installed:
        _discardVerified();
        manifest = null;
        _set(UpdatePhase.idle, 'Update installed.');
      case InstallOutcome.declined:
        _set(UpdatePhase.declined);
      case InstallOutcome.failed:
        _discardVerified();
        _set(
          UpdatePhase.failed,
          result.message ?? 'Android did not install the update.',
        );
    }
  }

  /// Waits in [UpdatePhase.waitingForSync] until [blocker] clears. False
  /// when the wait ended another way (Later, or a check replaced the offer).
  Future<bool> _syncIdle(ReleaseManifest release) async {
    final busyWith = blocker;
    if (busyWith == null || busyWith() == null) return true;
    _set(
      UpdatePhase.waitingForSync,
      updateStartsWhen(release.version, busyWith()),
    );
    final done = Completer<void>();
    void changed() {
      if (done.isCompleted) return;
      final reason = busyWith();
      if (reason == null ||
          phase != UpdatePhase.waitingForSync ||
          manifest != release) {
        done.complete();
      } else {
        final text = updateStartsWhen(release.version, reason);
        if (text != message) _set(UpdatePhase.waitingForSync, text);
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
    return phase == UpdatePhase.waitingForSync &&
        manifest == release &&
        _verified != null;
  }

  /// Opens Android's "Install unknown apps" screen for AnJ Cloud.
  Future<void> openPermissionSettings() => installer.openInstallPermission();

  /// Later, Cancel or Dismiss: the offer goes away (the next check may show
  /// it again) and a kept download is removed.
  void dismiss() {
    if (busy) return;
    _discardVerified();
    _set(UpdatePhase.idle);
  }

  void _set(UpdatePhase next, [String? text]) {
    phase = next;
    message = text;
    notifyListeners();
  }

  void _discardVerified() {
    final file = _verified;
    _verified = null;
    if (file != null) _remove(file);
  }

  static void _remove(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      /* Cleared at the next start. */
    }
  }

  void _clearDownloads() {
    try {
      downloads.createSync(recursive: true);
      for (final entry in downloads.listSync(followLinks: false)) {
        entry.deleteSync(recursive: true);
      }
    } on FileSystemException {
      /* A download into it fails visibly. */
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _installTimer?.cancel();
    feed.removeListener(_feedChanged);
    super.dispose();
  }
}
