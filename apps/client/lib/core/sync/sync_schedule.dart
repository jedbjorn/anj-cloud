import 'dart:io';
import 'dart:math';

import '../gateway/cloud_api.dart';
import '../state/model.dart';
import '../gateway/sharing.dart';
import '../gateway/admin_api.dart';
import 'name_policy.dart';
import 'sync_engine.dart';

/// When the worker lists the cloud (decision #40): about every [idle] while
/// nothing happens, at once when asked (window shown, resume, explicit tick),
/// every [fast] for [fastWindow] after this client changed something, and
/// with exponential backoff plus jitter while the cloud is unreachable.
/// Local changes still trigger a listing between due times, except while
/// backing off. Paused workers do not consult the schedule at all.
class RemoteSchedule {
  RemoteSchedule({
    this.idle = const Duration(seconds: 30),
    this.fast = const Duration(seconds: 3),
    this.fastWindow = const Duration(seconds: 30),
    this.backoffBase = const Duration(seconds: 5),
    this.backoffMax = const Duration(minutes: 5),
    Duration Function()? clock,
    Random? random,
  }) : _clock = clock ?? _monotonic(),
       _random = random ?? Random();

  final Duration idle;
  final Duration fast;
  final Duration fastWindow;
  final Duration backoffBase;
  final Duration backoffMax;
  final Duration Function() _clock;
  final Random _random;

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  Duration _due = Duration.zero;
  Duration? _fastUntil;
  int _failures = 0;

  /// Consecutive failed listings; non-zero means the cloud is unreachable.
  int get failures => _failures;
  bool get offline => _failures > 0;

  /// Time until the next listing is due (zero when due now).
  Duration get untilDue {
    final remaining = _due - _clock();
    return remaining.isNegative ? Duration.zero : remaining;
  }

  RemotePolicy policy() {
    final now = _clock();
    if (now >= _due) return RemotePolicy.always;
    return offline ? RemotePolicy.never : RemotePolicy.ifLocalWork;
  }

  /// Window shown, resume or an explicit refresh: list on the next pass,
  /// even while backing off (the backoff resumes if it fails again).
  void requestNow() => _due = _clock();

  /// This client changed something: confirm quickly for a short while.
  void mutated() {
    final now = _clock();
    _fastUntil = now + fastWindow;
    final quick = fast < idle ? fast : idle;
    if (!offline && _due > now + quick) _due = now + quick;
  }

  /// Records the outcome of one pass.
  void completed({required bool listed, required bool failed}) {
    final now = _clock();
    if (failed) {
      _failures++;
      final exponent = min(_failures - 1, 16);
      var delay = backoffBase * (1 << exponent);
      if (delay > backoffMax) delay = backoffMax;
      // +-25% jitter so many clients do not retry in lockstep.
      final factor = 0.75 + _random.nextDouble() * 0.5;
      _due = now + delay * factor;
    } else if (listed) {
      _failures = 0;
      final fastUntil = _fastUntil;
      final quick = fast < idle ? fast : idle;
      _due = now + (fastUntil != null && now < fastUntil ? quick : idle);
    }
  }
}

/// Network gate in front of the real cloud. While paused every call fails
/// before any request is made, so no command or pass can reach the server.
class PausableCloud with ForwardSharing, ForwardAdmin implements CloudApi {
  PausableCloud(this.inner);
  final CloudApi inner;
  bool paused = false;

  /// Sharing calls (spec #26) are refused while paused like file sync (#53).
  @override
  CloudApi get sharingTarget => inner;
  @override
  void beforeSharing() => _check();

  /// Calls attempted while paused (test seam).
  int refused = 0;

  /// "Wi-Fi only" on mobile data (decision #108 Q4): uploads and downloads
  /// fail with [TransfersHeld] before any request; listings, deletions,
  /// folder creation, sharing and admin calls still pass (spec #28 R3).
  bool bytesHeld = false;

  /// Byte transfers refused while [bytesHeld] (test seam).
  int heldTransfers = 0;

  void _checkBytes() {
    _check();
    if (bytesHeld) {
      heldTransfers++;
      throw const TransfersHeld();
    }
  }

  void _check() {
    if (paused) {
      refused++;
      throw const CloudFailure(
        'Sync is paused. Resume sync to connect. Local changes are retained.',
      );
    }
  }

  @override
  Future<List<RemoteItem>> snapshot() async {
    _check();
    return inner.snapshot();
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    _checkBytes();
    return inner.download(path, target, etag: etag);
  }

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    _checkBytes();
    return inner.upload(path, source, etag: etag);
  }

  @override
  bool get lastUploadReadBack => inner.lastUploadReadBack;
  @override
  int? get uploadLimit => inner.uploadLimit;
  @override
  Future<void> mkdir(String path) {
    _check();
    return inner.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    _check();
    return inner.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) {
    _check();
    return inner.move(from, to, etag: etag);
  }

  @override
  bool get safeFolderDeletion => inner.safeFolderDeletion;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) {
    _check();
    return inner.deleteFolder(path, versions: versions);
  }

  /// File metadata: refused while paused like every other request (#53).
  @override
  Future<AddedPage?> addedSince(int after) async {
    _check();
    return inner.addedSince(after);
  }

  @override
  void close() => inner.close();
}

/// The five user-facing states shown in the tray and the window.
enum SyncStatus {
  upToDate('Up to date'),
  syncing('Syncing'),
  paused('Paused'),
  offline('Offline'),

  /// Android "Wi-Fi only" on mobile data with files to transfer (#108 Q4).
  waiting('Waiting for Wi-Fi'),
  attention('Needs attention');

  const SyncStatus(this.label);
  final String label;
}

/// Pure projection used by the worker; most significant state wins.
SyncStatus deriveStatus({
  required bool paused,
  required bool offline,
  required bool unpaired,
  required String message,
  required Iterable<Entry> entries,
  required Iterable<Operation> operations,
}) {
  if (paused) return SyncStatus.paused;
  if (unpaired ||
      message.startsWith('Paused:') ||
      message.startsWith('Storage upgrade pending') ||
      entries.any(
        (e) =>
            e.conflict != null ||
            isSizeRefusal(e.status) ||
            isNameRefusal(e.status),
      )) {
    return SyncStatus.attention;
  }
  if (offline) return SyncStatus.offline;
  if (entries.any((e) => e.status == waitingForWifiStatus) ||
      operations.any(
        (o) => o.data['presentationError'] == waitingForWifiStatus,
      )) {
    return SyncStatus.waiting;
  }
  const passive = {
    'artifact',
    'retained',
    'excluded-entry',
    'excluded-operation',
    'working',
  };
  if (operations.any((o) => !passive.contains(o.kind)) ||
      entries.any((e) {
        final status = e.status.toLowerCase();
        // Retained Cloud releases wait on the user's files, not on sync.
        if (status.startsWith('cloud pending')) return false;
        return status == 'queued' ||
            status.contains('pending') ||
            status.endsWith('queued');
      })) {
    return SyncStatus.syncing;
  }
  return SyncStatus.upToDate;
}
