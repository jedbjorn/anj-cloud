import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'trash_api.dart';

import 'admin_api.dart';
import 'cloud_api.dart';
import 'dav_api.dart';
import 'fetch_api.dart';
import 'releases_api.dart';
import 'device_crypto.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../update/release.dart';
import 'sharing.dart';

enum PickupOutcome { renewed, unchanged }

class PickupResult {
  const PickupResult(this.outcome, this.certificate, this.expires);
  final PickupOutcome outcome;
  final String certificate;
  final DateTime expires;
}

/// Fetches the device's current leaf over its existing mTLS identity
/// (`GET /v1/device/certificate`, spec #19) and adopts it only after it is
/// proven to be the same device: same private key, chained to the pinned
/// issuer as a client certificate, same subject identity. The working
/// certificate is replaced in one manifest transaction, and only if it is still
/// the one used for the fetch; every failure leaves it in place.
class CertificatePickup {
  CertificatePickup(
    this.manifest,
    this.privateKey, {
    this.crypto = const DartDeviceCrypto(),
    DateTime Function()? clock,
    this.beforePersist,
  }) : clock = clock ?? DateTime.now;
  final Manifest manifest;
  final String privateKey;
  final DeviceCrypto crypto;
  final DateTime Function() clock;

  /// Test seam: runs after verification, immediately before the write.
  final void Function()? beforePersist;

  static const _maxResponse = 32 * 1024;

  /// Builds the mutual-TLS context for [certificate] with the pinned issuer.
  SecurityContext context(String certificate) =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(
          File(manifest.setting('ca')!).readAsBytesSync(),
        )
        ..usePrivateKeyBytes(utf8.encode(privateKey))
        ..useCertificateChainBytes(utf8.encode(certificate));

  Future<PickupResult> run({bool Function()? stillWanted}) async {
    final current = manifest.setting('certificate');
    final server = manifest.setting('server');
    if (current == null || server == null || manifest.setting('ca') == null) {
      throw const CloudFailure('Device is not paired.');
    }
    final origin = Uri.parse(server);
    if (origin.scheme != 'https' || origin.userInfo.isNotEmpty) {
      throw const FormatException('Use an HTTPS server origin.');
    }
    final body = await _fetch(origin, current);
    final certificate = body['certificate'];
    final deviceId = manifest.setting('deviceId');
    if (certificate is! String ||
        (deviceId != null && body['device_id'] != deviceId)) {
      throw const FormatException(
        'Certificate response is not for this device.',
      );
    }
    if (certificate.trim() == current.trim()) {
      return PickupResult(
        PickupOutcome.unchanged,
        current,
        DateTime.parse(manifest.setting('certificateExpires')!),
      );
    }
    final expires = await verify(certificate, current);
    if (stillWanted != null && !stillWanted()) {
      throw const CloudFailure('Certificate pickup stopped before saving.');
    }
    beforePersist?.call();
    manifest.transaction(() {
      // Compare-and-swap: re-pairing or another pickup may have replaced it.
      if (manifest.setting('certificate') != current) {
        throw const CloudFailure('Device certificate changed during pickup.');
      }
      manifest.setSetting('certificate', certificate);
      manifest.setSetting('certificateExpires', expires.toIso8601String());
    });
    return PickupResult(PickupOutcome.renewed, certificate, expires);
  }

  Future<Map<String, dynamic>> _fetch(Uri origin, String current) async {
    final client = HttpClient(context: context(current))
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        origin.replace(path: '/v1/device/certificate', query: null),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final data = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (data.length + chunk.length > _maxResponse) {
          throw const CloudFailure('Certificate response is too large.');
        }
        data.addAll(chunk);
      }
      if (response.statusCode != 200) {
        throw CloudFailure(
          'Certificate pickup failed (${response.statusCode}).',
          status: response.statusCode,
        );
      }
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Malformed certificate response.');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  /// Proves [candidate] belongs to this device; returns its expiry.
  Future<DateTime> verify(String candidate, String current) async {
    final blocks = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----')
        .allMatches(candidate);
    if (candidate.length > 16 * 1024 ||
        blocks.length != 1 ||
        blocks.single.group(1) != 'CERTIFICATE') {
      throw const FormatException('Expected exactly one certificate.');
    }
    final DeviceCertificate leaf;
    final DeviceCertificate working;
    final String keyPrint;
    try {
      leaf = crypto.certificate(candidate);
      working = crypto.certificate(current);
      keyPrint = keyFingerprint(await crypto.publicKeyInfo(privateKey));
    } on FormatException {
      throw const FormatException('Certificate could not be read.');
    }
    // 1. Same key: the leaf's public key is the one derived from our private key.
    final leafPrint = keyFingerprint(leaf.publicKeyInfo);
    final pinned = manifest.setting('fingerprint');
    if (leafPrint != keyPrint || (pinned != null && pinned != keyPrint)) {
      throw const FormatException(
        'Certificate does not match this device key.',
      );
    }
    // 2. Chains to the pinned issuer only (no system stores) as a client leaf.
    try {
      final anchors = crypto.certificates(
        await File(manifest.setting('ca')!).readAsString(),
      );
      await crypto.verifyClientCertificate(leaf, anchors, at: clock().toUtc());
    } on Exception {
      throw const FormatException(
        'Certificate is not a client certificate from the trusted issuer.',
      );
    }
    // A leaf, never an issuer: basicConstraints must be present with CA:FALSE,
    // matching the gateway's profile check.
    if (leaf.isCa != false) {
      throw const FormatException('Certificate must not be an issuer.');
    }
    // 3. Same device identity as the working certificate (and the paired ID).
    final subject = leaf.subject;
    final deviceId = manifest.setting('deviceId');
    if (subject != working.subject ||
        (deviceId != null && subject != 'CN=$deviceId')) {
      throw const FormatException('Certificate is for a different device.');
    }
    final expires = leaf.notAfter;
    if (!expires.isAfter(clock().toUtc())) {
      throw const FormatException('Certificate has expired.');
    }
    return expires;
  }
}

/// Schedules pickups: at start, then daily, hourly within 30 days of expiry.
/// Reports a warning only when expiry is within 14 days and pickups keep
/// failing to deliver a renewed certificate.
class CertificateRenewal {
  CertificateRenewal(
    this.attempt, {
    required this.expires,
    required this.onRenewed,
    required this.onStatus,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// One pickup; throws on failure.
  final Future<PickupResult> Function(bool Function() stillWanted) attempt;
  final void Function(PickupResult result) onRenewed;

  /// Called after every attempt with the current warning (or null).
  final void Function(String? warning, DateTime expires) onStatus;
  final DateTime Function() clock;
  DateTime expires;
  Timer? _timer;
  bool _stopped = false;
  bool _running = false;

  /// Consecutive attempts that left the device within the warning window.
  int unsuccessful = 0;

  static const daily = Duration(days: 1);
  static const hourly = Duration(hours: 1);
  static const hourlyWindow = Duration(days: 30);
  static const warningWindow = Duration(days: 14);

  Duration get nextDelay =>
      expires.difference(clock()) <= hourlyWindow ? hourly : daily;

  String? get warning =>
      expires.difference(clock()) <= warningWindow && unsuccessful >= 2
      ? 'Device certificate expires ${expires.toUtc().toIso8601String()} and renewal keeps failing. Sync continues until then; ask the server owner to reissue it.'
      : null;

  void start() => _schedule(Duration.zero);

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  /// When the next scheduled pickup is due (null before [start]).
  DateTime? dueAt;

  /// Runs the pickup now if its time has passed. A background run (Android,
  /// spec #28 A4) waits for it, including while paused: a process frozen
  /// between runs would otherwise end the run before the overdue timer's
  /// pickup finished.
  Future<void> runIfDue() async {
    final running = _inFlight;
    if (running != null) return running;
    final due = dueAt;
    if (due != null && !clock().isBefore(due)) await runOnce();
  }

  /// The pickup in progress, so [runIfDue] waits for it instead of
  /// returning while it still runs (a paused cold start: the start-up
  /// pickup is already under way when the background run asks).
  Future<void>? _inFlight;

  void _schedule(Duration delay) {
    if (_stopped) return;
    dueAt = clock().add(delay);
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(runOnce()));
  }

  Future<void> runOnce() {
    if (_stopped) return Future.value();
    return _inFlight ??= _runOnce().whenComplete(() => _inFlight = null);
  }

  Future<void> _runOnce() async {
    if (_running || _stopped) return;
    _running = true;
    try {
      final result = await attempt(() => !_stopped);
      if (_stopped) return;
      expires = result.expires;
      if (result.outcome == PickupOutcome.renewed) onRenewed(result);
      unsuccessful = expires.difference(clock()) <= warningWindow
          ? unsuccessful + 1
          : 0;
    } catch (_) {
      // The working certificate is untouched; try again on schedule.
      unsuccessful++;
    } finally {
      _running = false;
    }
    if (_stopped) return;
    onStatus(warning, expires);
    _schedule(nextDelay);
  }
}

/// The worker's cloud, whose TLS identity can be replaced after a pickup
/// without restarting the sync engine. In-flight requests finish on the
/// previous client; new requests use the renewed certificate.
class RenewableCloud
    with ForwardSharing, ForwardAdmin, ForwardTrash
    implements CloudApi, ReleaseTransport, FetchTransport {
  RenewableCloud(this._current);
  CloudApi _current;
  @override
  CloudApi get sharingTarget => _current;
  bool _readBack = false;
  CloudApi get current => _current;

  void replace(CloudApi next) {
    final previous = _current;
    _current = next;
    if (previous is DavCloud) {
      previous.client.close();
    } else {
      previous.close();
    }
  }

  @override
  Future<List<RemoteItem>> snapshot() => _current.snapshot();
  @override
  Future<void> download(String path, File target, {required String etag}) =>
      _current.download(path, target, etag: etag);
  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    // Read-back provenance belongs to the client that performed the upload.
    final target = _current;
    try {
      return await target.upload(path, source, etag: etag);
    } finally {
      _readBack = target.lastUploadReadBack;
    }
  }

  @override
  bool get lastUploadReadBack => _readBack;
  @override
  int? get uploadLimit => _current.uploadLimit;
  @override
  Future<void> mkdir(String path) => _current.mkdir(path);
  @override
  Future<void> deleteFile(String path, {required String etag}) =>
      _current.deleteFile(path, etag: etag);
  @override
  Future<void> move(String from, String to, {required String etag}) =>
      _current.move(from, to, etag: etag);
  @override
  bool get safeFolderDeletion => _current.safeFolderDeletion;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) => _current.deleteFolder(path, versions: versions);
  @override
  Future<AddedPage?> addedSince(int after) => _current.addedSince(after);

  /// The update feed over the current certificate (spec #28 G1, spec #37).
  ReleaseTransport get _releases {
    final target = _current;
    if (target is ReleaseTransport) return target as ReleaseTransport;
    throw const CloudFailure('Updates are not available on this connection.');
  }

  @override
  Future<ReleaseManifest?> releaseManifest(String target) =>
      _releases.releaseManifest(target);
  @override
  Future<void> downloadRelease(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
    Future<void>? cancel,
  }) => _releases.downloadRelease(
    manifest,
    destination,
    progress: progress,
    cancel: cancel,
  );

  /// Media fetch job routes (spec #42) over the current certificate.
  FetchTransport get _fetch {
    final target = _current;
    if (target is FetchTransport) return target as FetchTransport;
    throw const FetchFailure(FetchError.notConnected);
  }

  @override
  Future<List<FetchJob>?> listFetchJobs() async => _fetch.listFetchJobs();
  @override
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  }) async => _fetch.submitFetchJobs(urls, kind, resolution: resolution);
  @override
  Future<void> deleteFetchJob(String id) async => _fetch.deleteFetchJob(id);
  @override
  Future<void> clearFetchJobs() async => _fetch.clearFetchJobs();
  @override
  void close() => _current.close();
}
