// Spec #28 A7 and spec #37: the client half of the G1 update feed over TLS, against a
// local HTTPS server that answers like services/access/releases.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/update/release.dart';

import 'test_platform.dart';

Future<void> openssl(List<String> args) async {
  final result = await Process.run(testOpenssl!, args);
  if (result.exitCode != 0) {
    throw StateError('Synthetic TLS fixture setup failed.');
  }
}

void main() {
  if (skipSuite(
    'Update feed client over a synthetic TLS gateway',
    opensslSkip,
  )) {
    return;
  }
  late Directory fixture;
  late File ca;
  late File serverKey;
  late HttpServer server;
  late DavCloud api;
  late Future<void> Function(HttpRequest) handler;
  final paths = <String>[];
  final package = List<int>.generate(700 * 1024, (i) => (i * 31) % 251);
  final digest = sha256.convert(package).toString();
  final signer = 'ab' * 32;
  Map<String, Object> manifestJson({String? sha, int? size}) => {
    'target': androidReleaseTarget,
    'version': '0.2.0',
    'version_code': 2,
    'size': size ?? package.length,
    'sha256': sha ?? digest,
    'signer_sha256': signer,
  };
  ReleaseManifest manifest({String? sha, int? size}) =>
      ReleaseManifest.fromJson(
        manifestJson(sha: sha, size: size),
        androidReleaseTarget,
      );

  Future<void> json(HttpRequest request, int status, Object body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('cache-control', 'no-store')
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> bytes(
    HttpRequest request,
    List<int> body, {
    String? etag,
    int? length,
  }) async {
    request.response
      ..statusCode = 200
      ..headers.set('etag', etag ?? '"$digest"')
      ..contentLength = length ?? body.length;
    request.response.add(body);
    await request.response.close();
  }

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-release-fixture-');
    ca = File('${fixture.path}/server.crt');
    serverKey = File('${fixture.path}/server.key');
    await openssl([
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      serverKey.path,
      '-out',
      ca.path,
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      // macOS's TLS policy requires serverAuth on a server certificate;
      // clientAuth keeps this self-signed anchor valid for client chains.
      '-addext',
      'extendedKeyUsage=serverAuth,clientAuth',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
    ]);
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  setUp(() async {
    paths.clear();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(ca.path)
        ..usePrivateKey(serverKey.path),
    );
    server.listen((request) async {
      paths.add(request.uri.path);
      await handler(request);
    });
    api = DavCloud(
      Uri.parse('https://127.0.0.1:${server.port}'),
      SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca.path),
    );
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  File target() => File('${fixture.path}/download-${paths.length}.apk');

  group('manifest', () {
    test('the served manifest, from the device route', () async {
      handler = (request) => json(request, 200, manifestJson());
      expect(await api.releaseManifest(androidReleaseTarget), manifest());
      expect(paths, ['/v1/client/releases/android-arm64']);
    });

    test(
      'a desktop manifest keeps its key id and signature (spec #37)',
      () async {
        final vector = jsonDecode(
          File('tool/testdata/release_signature_vector.json')
              .readAsStringSync(),
        ) as Map;
        final served = Map<String, Object?>.from(vector['manifest'] as Map)
          ..['min_client_version_code'] = 600;
        handler = (request) => json(request, 200, served);
        final manifest = await api.releaseManifest(linuxReleaseTarget);
        expect(paths, ['/v1/client/releases/linux-x86_64']);
        expect(manifest!.toJson(), served);
        expect(manifest.minClientVersionCode, 600);
      },
    );

    test('nothing published is no update, not a failure', () async {
      handler = (request) => json(request, 404, {'error': 'no_release'});
      expect(await api.releaseManifest(androidReleaseTarget), isNull);
    });

    test('refusals and unknown targets fail with a plain reason', () async {
      handler = (request) => json(request, 404, {'error': 'unknown_target'});
      await expectLater(
        api.releaseManifest(androidReleaseTarget),
        throwsA(
          isA<CloudFailure>().having(
            (e) => e.message,
            'message',
            contains('no updates for this device type'),
          ),
        ),
      );
      handler = (request) async {
        request.response.statusCode = 403;
        await request.response.close();
      };
      await expectLater(
        api.releaseManifest(androidReleaseTarget),
        throwsA(isA<CloudFailure>().having((e) => e.status, 'status', 403)),
      );
    });

    test('a manifest that breaks the gateway rule is refused', () async {
      for (final bad in <Map<String, Object>>[
        {...manifestJson(), 'target': 'linux-x86_64'},
        {...manifestJson(), 'sha256': 'AB' * 32},
        {...manifestJson(), 'version_code': 0},
        {...manifestJson(), 'size': ReleaseManifest.maxPackage + 1},
        {...manifestJson(), 'extra': 1},
        {...manifestJson()}..remove('signer_sha256'),
      ]) {
        handler = (request) => json(request, 200, bad);
        await expectLater(
          api.releaseManifest(androidReleaseTarget),
          throwsA(isA<CloudFailure>()),
          reason: '$bad',
        );
      }
    });

    test('a target outside the pattern is never requested', () async {
      handler = (request) => json(request, 200, manifestJson());
      await expectLater(
        api.releaseManifest('../dav'),
        throwsA(isA<CloudFailure>()),
      );
      expect(paths, isEmpty);
    });
  });

  group('package', () {
    test('streams to the file with its SHA-256 checked', () async {
      handler = (request) => bytes(request, package);
      final file = target();
      final seen = <int>[];
      await api.downloadRelease(manifest(), file, progress: seen.add);
      expect(file.readAsBytesSync(), package);
      expect(paths, ['/v1/client/releases/android-arm64/package']);
      expect(seen.last, package.length);
    });

    test('other bytes of the same size are refused and removed', () async {
      final other = [...package]..[1000] ^= 0xff;
      handler = (request) => bytes(request, other);
      final file = target();
      await expectLater(
        api.downloadRelease(manifest(), file),
        throwsA(
          isA<ReleaseRefused>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(file.existsSync(), isFalse);
    });

    test('a package larger than announced is refused', () async {
      handler = (request) => bytes(request, package);
      final file = target();
      await expectLater(
        api.downloadRelease(manifest(size: package.length - 10), file),
        throwsA(isA<ReleaseRefused>()),
      );
      expect(file.existsSync(), isFalse);
    });

    test('a cut-off download fails and leaves no file', () async {
      handler = (request) async {
        request.response
          ..statusCode = 200
          ..headers.set('etag', '"$digest"');
        request.response.add(package.sublist(0, 1000));
        await request.response.flush();
        await request.response.close();
      };
      final file = target();
      await expectLater(
        api.downloadRelease(manifest(), file),
        throwsA(isA<CloudFailure>()),
      );
      expect(file.existsSync(), isFalse);
    });

    test('a release published since the check is not downloaded', () async {
      handler = (request) => bytes(request, package, etag: '"${'cd' * 32}"');
      final file = target();
      await expectLater(
        api.downloadRelease(manifest(), file),
        throwsA(
          isA<CloudFailure>().having(
            (e) => e.message,
            'message',
            contains('newer update'),
          ),
        ),
      );
      expect(file.existsSync(), isFalse);
    });

    test('cancel aborts at once, removes the file; a retry works', () async {
      final stalled = Completer<void>();
      handler = (request) async {
        if (paths.length == 1) {
          request.response
            ..statusCode = 200
            ..headers.set('etag', '"$digest"')
            ..contentLength = package.length;
          request.response.add(package.sublist(0, 64 * 1024));
          await request.response.flush();
          await stalled.future; // never sends the rest
          return;
        }
        await bytes(request, package);
      };
      final file = target();
      final cancel = Completer<void>();
      final started = Completer<void>();
      final download = api.downloadRelease(
        manifest(),
        file,
        progress: (_) {
          if (!started.isCompleted) started.complete();
        },
        cancel: cancel.future,
      );
      await started.future;
      final clock = Stopwatch()..start();
      cancel.complete();
      await expectLater(download, throwsA(isA<ReleaseCancelled>()));
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(file.existsSync(), isFalse);
      stalled.complete();
      final again = target();
      await api.downloadRelease(manifest(), again);
      expect(again.readAsBytesSync(), package);
    });

    test('the renewable cloud forwards the feed', () async {
      handler = (request) => json(request, 200, manifestJson());
      final renewable = RenewableCloud(api);
      expect(await renewable.releaseManifest(androidReleaseTarget), manifest());
    });
  });
}
