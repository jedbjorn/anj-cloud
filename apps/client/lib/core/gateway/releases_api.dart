import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../state/model.dart';
import '../update/release.dart';

/// The gateway's update feed (spec #28 G1, `services/access/releases.py`)
/// over this device's certificate, like `/dav/`:
///
///     GET /v1/client/releases/{target}            the current manifest
///     GET /v1/client/releases/{target}/package    its bytes
///
/// Not file sync: the pause gate does not apply (as for Admin), and the
/// download is a transfer only for the network setting, which the updater
/// asks before it calls [downloadRelease].
abstract interface class ReleaseTransport {
  /// The served manifest for [target]; null when nothing is published.
  Future<ReleaseManifest?> releaseManifest(String target);

  /// Streams the package of [manifest] to [destination], hashing it as it
  /// arrives. Throws [ReleaseRefused] when the bytes differ from the
  /// manifest (size or SHA-256), [ReleaseCancelled] once [cancel]
  /// completes (the connection is aborted at once) and [CloudFailure] when
  /// the download fails; in every case [destination] is removed.
  Future<void> downloadRelease(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
    Future<void>? cancel,
  });
}

/// How long the gateway may take to answer, and how long a download may
/// see no bytes before it is abandoned (the gateway's own chunk limit is
/// 120 s; a phone link that stalls this long is better retried).
const releaseAnswerTimeout = Duration(seconds: 30);
const releaseIdleTimeout = Duration(seconds: 60);

final _target = RegExp(r'^[a-z0-9]+-[a-z0-9_]+$');

Uri releaseUri(Uri origin, String target, {bool package = false}) {
  if (!_target.hasMatch(target)) {
    throw const CloudFailure('Invalid update target.');
  }
  return origin.replace(
    pathSegments: ['v1', 'client', 'releases', target, if (package) 'package'],
  );
}

String _failure(int status) => switch (status) {
  401 ||
  403 => 'The server refused this device. Check pairing in Device pairing.',
  429 => 'The server is limiting update requests. Try again in a minute.',
  _ => 'Checking for updates failed ($status).',
};

Future<HttpClientResponse> _get(
  HttpClient client,
  Uri uri, {
  void Function(HttpClientRequest request)? opened,
}) async {
  final request = await client.getUrl(uri);
  request.followRedirects = false;
  opened?.call(request);
  try {
    return await request.close().timeout(releaseAnswerTimeout);
  } on TimeoutException {
    request.abort();
    throw const CloudFailure('The server did not answer. Try again later.');
  }
}

Future<String> _small(HttpClientResponse response) async {
  final data = <int>[];
  await for (final chunk in response.timeout(releaseAnswerTimeout)) {
    if (data.length + chunk.length > 16 * 1024) {
      throw const CloudFailure('The update record is too large.');
    }
    data.addAll(chunk);
  }
  return utf8.decode(data, allowMalformed: true);
}

/// [ReleaseTransport.releaseManifest] on [client] (the device's mTLS client).
Future<ReleaseManifest?> fetchReleaseManifest(
  HttpClient client,
  Uri origin,
  String target,
) async {
  final response = await _get(client, releaseUri(origin, target));
  final text = await _small(response);
  Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    data = null;
  }
  if (response.statusCode == 404) {
    if (data is Map && data['error'] == 'no_release') return null;
    if (data is Map && data['error'] == 'unknown_target') {
      throw const CloudFailure(
        'The server offers no updates for this device type.',
      );
    }
    throw const CloudFailure('This server has no update feed.');
  }
  if (response.statusCode != 200) {
    throw CloudFailure(
      _failure(response.statusCode),
      status: response.statusCode,
    );
  }
  try {
    return ReleaseManifest.fromJson(data, target);
  } on FormatException catch (error) {
    throw CloudFailure(error.message);
  }
}

/// [ReleaseTransport.downloadRelease] on [client].
Future<void> downloadReleasePackage(
  HttpClient client,
  Uri origin,
  ReleaseManifest manifest,
  File destination, {
  void Function(int received)? progress,
  Future<void>? cancel,
}) async {
  RandomAccessFile? file;
  var cancelled = false;
  HttpClientRequest? request;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      request?.abort(const ReleaseCancelled());
    }),
  );
  try {
    if (cancelled) throw const ReleaseCancelled();
    final response = await _get(
      client,
      releaseUri(origin, manifest.target, package: true),
      opened: (opened) => request = opened,
    );
    if (cancelled) throw const ReleaseCancelled();
    if (response.statusCode != 200) {
      await response.drain<void>().catchError((_) {});
      if (response.statusCode == 404) {
        throw const CloudFailure(
          'The update is no longer on the server. Check again.',
        );
      }
      throw CloudFailure(
        _failure(response.statusCode),
        status: response.statusCode,
      );
    }
    // The gateway tags the package with its SHA-256: another tag means the
    // operator published a newer release since the check.
    final etag = response.headers.value(HttpHeaders.etagHeader);
    if (etag != null && etag != '"${manifest.sha256}"') {
      await response.drain<void>().catchError((_) {});
      throw const CloudFailure(
        'The server has a newer update than the one shown. Check again.',
      );
    }
    if (response.contentLength != -1 &&
        response.contentLength != manifest.size) {
      await response.drain<void>().catchError((_) {});
      throw const ReleaseRefused(
        'The download is not the size the server announced.',
      );
    }
    file = await destination.open(mode: FileMode.writeOnly);
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    var received = 0;
    await for (final chunk in response.timeout(releaseIdleTimeout)) {
      if (cancelled) throw const ReleaseCancelled();
      received += chunk.length;
      if (received > manifest.size) {
        throw const ReleaseRefused(
          'The download is larger than the server announced.',
        );
      }
      hashing.add(chunk);
      await file.writeFrom(chunk);
      progress?.call(received);
    }
    if (received != manifest.size) {
      throw const CloudFailure('The download was cut off. Try again.');
    }
    hashing.close();
    await file.flush();
    await file.close();
    file = null;
    if (digest.value.toString() != manifest.sha256) {
      throw const ReleaseRefused(
        "The download does not match the update's SHA-256 checksum.",
      );
    }
  } catch (error) {
    try {
      await file?.close();
    } on IOException {
      /* Already failing; the file is removed next. */
    }
    if (destination.existsSync()) destination.deleteSync();
    if (cancelled) throw const ReleaseCancelled();
    if (error is TimeoutException) {
      throw const CloudFailure('The download stalled. Try again.');
    }
    if (error is IOException) {
      throw const CloudFailure('The download failed. Try again.');
    }
    rethrow;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
