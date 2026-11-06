import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/gateway/device_crypto.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';

import 'fakes.dart';
import 'openssl_cli.dart' as cli;
import 'test_platform.dart';

const deviceId = '11111111-2222-4333-8444-555555555555';

void main() {
  const suite = 'certificate renewal over a synthetic TLS gateway';
  if (skipSuite(suite, opensslSkip)) return;
  late Directory fixture;
  late String deviceKey;
  late File deviceCsr;
  late String held;
  late HttpServer server;
  late Future<void> Function(HttpRequest) handler;
  final presented = <String?>[];

  Future<void> openssl(List<String> args) async {
    final result = await Process.run(testOpenssl!, args);
    if (result.exitCode != 0) {
      throw StateError('Synthetic TLS fixture setup failed.');
    }
  }

  String path(String name) => '${fixture.path}/$name';

  Future<void> issuer(String name) => openssl([
    'req',
    '-x509',
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:P-256',
    '-noenc',
    '-days',
    '30',
    '-subj',
    '/CN=$name',
    '-keyout',
    path('$name.key'),
    '-out',
    path('$name.crt'),
    '-addext',
    'basicConstraints=critical,CA:TRUE,pathlen:0',
    '-addext',
    'keyUsage=critical,keyCertSign,cRLSign',
  ]);

  var serial = 1;
  Future<String> sign(
    String csr, {
    String ca = 'issuer',
    String subject = deviceId,
    String usage = 'clientAuth',
    String days = '20',
    String? san,
    String constraints = 'basicConstraints=critical,CA:FALSE\n',
  }) async {
    final out = path('leaf-${serial++}.crt');
    File(path('leaf.ext')).writeAsStringSync(
      '[leaf]\n$constraints'
      'keyUsage=critical,digitalSignature\nextendedKeyUsage=$usage\n'
      '${san == null ? '' : 'subjectAltName=$san\n'}',
    );
    await openssl([
      'x509',
      '-req',
      '-in',
      csr,
      '-CA',
      path('$ca.crt'),
      '-CAkey',
      path('$ca.key'),
      '-set_serial',
      '$serial',
      '-days',
      days,
      '-subj',
      '/CN=$subject',
      '-extfile',
      path('leaf.ext'),
      '-extensions',
      'leaf',
      '-out',
      out,
    ]);
    return File(out).readAsStringSync();
  }

  Future<String> fingerprint(String key) async => sha256
      .convert(
        await cli.openssl([
          'pkey',
          '-pubin',
          '-outform',
          'DER',
        ], await cli.openssl(['pkey', '-pubout'], utf8.encode(key))),
      )
      .toString();

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-renewal-fixture-');
    await issuer('issuer');
    await issuer('stranger');
    await openssl([
      'req',
      '-new',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      path('server.key'),
      '-out',
      path('server.csr'),
      '-subj',
      '/CN=127.0.0.1',
    ]);
    File(path('server.crt')).writeAsStringSync(
      await sign(
        path('server.csr'),
        subject: '127.0.0.1',
        usage: 'serverAuth',
        san: 'IP:127.0.0.1',
      ),
    );
    // An existing Linux device's key: `openssl genpkey` PKCS#8 PEM.
    deviceKey = utf8.decode(
      await cli.openssl([
        'genpkey',
        '-algorithm',
        'EC',
        '-pkeyopt',
        'ec_paramgen_curve:P-256',
      ]),
    );
    File(path('device.key')).writeAsStringSync(deviceKey);
    deviceCsr = File(path('device.csr'));
    await openssl([
      'req',
      '-new',
      '-sha256',
      '-key',
      path('device.key'),
      '-subj',
      '/CN=x',
      '-out',
      deviceCsr.path,
    ]);
    held = await sign(deviceCsr.path, days: '7');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  setUp(() async {
    presented.clear();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(path('server.crt'))
        ..usePrivateKey(path('server.key'))
        ..setTrustedCertificates(path('issuer.crt')),
      requestClientCertificate: true,
    );
    server.listen((request) async {
      presented.add(request.certificate?.pem);
      if (request.certificate == null ||
          request.uri.path != '/v1/device/certificate') {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      await handler(request);
    });
  });
  tearDown(() => server.close(force: true));

  void respond(Object body, {int status = 200}) {
    handler = (request) async {
      request.response.statusCode = status;
      request.response.write(body is String ? body : jsonEncode(body));
      await request.response.close();
    };
  }

  Future<Manifest> profile({String? key, String? working}) async {
    final directory = Directory.systemTemp.createTempSync('anj-renewal-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final manifest = Manifest(directory);
    addTearDown(manifest.close);
    manifest.transaction(() {
      manifest.setSetting('server', 'https://127.0.0.1:${server.port}');
      manifest.setSetting('ca', path('issuer.crt'));
      manifest.setSetting('certificate', working ?? held);
      manifest.setSetting('certificateExpires', '2026-01-01T00:00:00.000Z');
      manifest.setSetting('deviceId', deviceId);
    });
    manifest.setSetting('fingerprint', await fingerprint(key ?? deviceKey));
    return manifest;
  }

  test(
    'adopts a verified reissue fetched with the working certificate',
    () async {
      final manifest = await profile();
      final renewed = await sign(deviceCsr.path, days: '300');
      respond({'device_id': deviceId, 'certificate': renewed, 'expires_at': 1});
      final result = await CertificatePickup(manifest, deviceKey).run();
      expect(result.outcome, PickupOutcome.renewed);
      expect(manifest.setting('certificate'), renewed);
      final expires = DateTime.parse(manifest.setting('certificateExpires')!);
      expect(expires, result.expires);
      expect(
        expires.difference(DateTime.now()).inDays,
        inInclusiveRange(298, 300),
      );
      // The fetch authenticated with the working (held) leaf.
      expect(presented.single!.trim(), held.trim());
      // The renewed identity is usable for mutual TLS against the same server.
      final second = await CertificatePickup(manifest, deviceKey).run();
      expect(second.outcome, PickupOutcome.unchanged);
      expect(presented.last!.trim(), renewed.trim());
    },
  );

  test(
    'a key generated in process pairs, authenticates and renews the same way',
    () async {
      const crypto = DartDeviceCrypto();
      final key = await crypto.generateKey();
      final csr = File(path('inprocess.csr'))
        ..writeAsStringSync(
          await crypto.certificationRequest(key, commonName: 'profile'),
        );
      final working = await sign(csr.path, days: '7');
      final manifest = await profile(key: key, working: working);
      final renewed = await sign(csr.path, days: '300');
      respond({'device_id': deviceId, 'certificate': renewed});
      final result = await CertificatePickup(manifest, key).run();
      expect(result.outcome, PickupOutcome.renewed);
      expect(presented.single!.trim(), working.trim());
      expect(result.expires, crypto.certificate(renewed).notAfter);
      final second = await CertificatePickup(manifest, key).run();
      expect(second.outcome, PickupOutcome.unchanged);
      expect(presented.last!.trim(), renewed.trim());
    },
  );

  test('rejects wrong key, wrong issuer, wrong device and wrong profile; keeps the working certificate', () async {
    final manifest = await profile();
    final otherKey = path('other.key');
    final otherCsr = path('other.csr');
    await openssl([
      'req',
      '-new',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      otherKey,
      '-out',
      otherCsr,
      '-subj',
      '/CN=x',
    ]);
    final cases = {
      'device key': await sign(otherCsr),
      'trusted issuer': await sign(deviceCsr.path, ca: 'stranger'),
      'different device': await sign(deviceCsr.path, subject: 'another-device'),
      'client certificate': await sign(deviceCsr.path, usage: 'serverAuth'),
      'not be an issuer': await sign(
        deviceCsr.path,
        constraints: 'basicConstraints=critical,CA:TRUE,pathlen:0\n',
      ),
      'must not be an': await sign(deviceCsr.path, constraints: ''),
      'exactly one': '$held\n${await sign(deviceCsr.path)}',
      'one certificate': '$deviceKey\n${await sign(deviceCsr.path)}',
    };
    for (final entry in cases.entries) {
      respond({'device_id': deviceId, 'certificate': entry.value});
      await expectLater(
        CertificatePickup(manifest, deviceKey).run(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(entry.key),
          ),
        ),
        reason: entry.key,
      );
      expect(manifest.setting('certificate'), held, reason: entry.key);
      expect(
        manifest.setting('certificateExpires'),
        '2026-01-01T00:00:00.000Z',
        reason: entry.key,
      );
    }
    respond({
      'device_id': 'another-device',
      'certificate': await sign(deviceCsr.path),
    });
    await expectLater(
      CertificatePickup(manifest, deviceKey).run(),
      throwsA(isA<FormatException>()),
    );
    expect(manifest.setting('certificate'), held);
  });

  test('server errors, malformed and oversized responses and an unreachable server keep the working certificate', () async {
    final manifest = await profile();
    for (final failure in <void Function()>[
      () => respond({'error': 'Service operation failed'}, status: 503),
      () => respond('not json'),
      () => respond(['a list']),
      () => respond('x' * (64 * 1024)),
      () => handler = (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await request.response.detachSocket().then((s) => s.destroy());
      },
    ]) {
      failure();
      await expectLater(
        CertificatePickup(manifest, deviceKey).run(),
        throwsA(anything),
      );
      expect(manifest.setting('certificate'), held);
    }
    await server.close(force: true);
    await expectLater(
      CertificatePickup(manifest, deviceKey).run(),
      throwsA(anything),
    );
    expect(manifest.setting('certificate'), held);
  });

  test(
    'a crash between fetch and persist converges on the next pickup',
    () async {
      final manifest = await profile();
      final renewed = await sign(deviceCsr.path, days: '300');
      respond({'device_id': deviceId, 'certificate': renewed});
      await expectLater(
        CertificatePickup(
          manifest,
          deviceKey,
          beforePersist: () => throw const FileSystemException('process lost'),
        ).run(),
        throwsA(isA<FileSystemException>()),
      );
      expect(manifest.setting('certificate'), held);
      await expectLater(
        CertificatePickup(manifest, deviceKey).run(stillWanted: () => false),
        throwsA(isA<CloudFailure>()),
      );
      expect(manifest.setting('certificate'), held);
      // The gateway keeps the previous leaf until the new one is used, so the
      // next pickup still authenticates and adopts the same reissue.
      final result = await CertificatePickup(manifest, deviceKey).run();
      expect(result.outcome, PickupOutcome.renewed);
      expect(manifest.setting('certificate'), renewed);
    },
  );

  test('a concurrent certificate change is never overwritten', () async {
    final manifest = await profile();
    final renewed = await sign(deviceCsr.path, days: '300');
    respond({'device_id': deviceId, 'certificate': renewed});
    await expectLater(
      CertificatePickup(
        manifest,
        deviceKey,
        beforePersist: () => manifest.setSetting('certificate', 're-paired'),
      ).run(),
      throwsA(isA<CloudFailure>()),
    );
    expect(manifest.setting('certificate'), 're-paired');
  });

  group('schedule', () {
    final now = DateTime.utc(2026, 11, 2);
    PickupResult result(PickupOutcome outcome, Duration remaining) =>
        PickupResult(outcome, 'pem', now.add(remaining));

    test('daily, hourly within 30 days; warning only within 14 days after repeated failure', () async {
      final outcomes = <Object>[];
      final warnings = <String?>[];
      final renewed = <PickupResult>[];
      final schedule = CertificateRenewal(
        (_) async {
          final next = outcomes.removeAt(0);
          if (next is Exception) throw next;
          return next as PickupResult;
        },
        expires: now.add(const Duration(days: 6)),
        onRenewed: renewed.add,
        onStatus: (warning, _) => warnings.add(warning),
        clock: () => now,
      );
      addTearDown(schedule.stop);
      expect(schedule.nextDelay, CertificateRenewal.hourly);
      outcomes.add(const CloudFailure('offline'));
      await schedule.runOnce();
      expect(warnings.last, isNull); // One failure is not "keeps failing".
      outcomes.add(result(PickupOutcome.unchanged, const Duration(days: 6)));
      await schedule.runOnce();
      expect(warnings.last, contains('renewal keeps failing'));
      outcomes.add(result(PickupOutcome.renewed, const Duration(days: 364)));
      await schedule.runOnce();
      expect(warnings.last, isNull);
      expect(renewed.single.expires, now.add(const Duration(days: 364)));
      expect(schedule.nextDelay, CertificateRenewal.daily);
      for (var i = 0; i < 3; i++) {
        outcomes.add(const CloudFailure('offline'));
        await schedule.runOnce();
      }
      // Far from expiry, failures stay silent.
      expect(warnings.last, isNull);
      schedule.expires = now.add(const Duration(days: 20));
      expect(schedule.nextDelay, CertificateRenewal.hourly);
    });

    test('stop prevents adoption callbacks from a pickup in flight', () async {
      final release = Completer<void>();
      var renewed = 0;
      var wanted = true;
      final schedule = CertificateRenewal(
        (stillWanted) async {
          await release.future;
          wanted = stillWanted();
          return result(PickupOutcome.renewed, const Duration(days: 300));
        },
        expires: now,
        onRenewed: (_) => renewed++,
        onStatus: (_, _) {},
        clock: () => now,
      );
      final running = schedule.runOnce();
      schedule.stop();
      release.complete();
      await running;
      expect((wanted, renewed), (false, 0));
    });
  });

  test(
    'renewable cloud switches identity and keeps upload read-back provenance',
    () async {
      final first = _SlowUploadCloud(readBack: true);
      final second = FakeCloud();
      final cloud = RenewableCloud(first);
      final upload = cloud.upload('a', File(path('device.csr')), etag: null);
      cloud.replace(second);
      first.release.complete();
      expect(await upload, '"slow"');
      expect(cloud.lastUploadReadBack, isTrue);
      expect(first.closed, isTrue);
      expect(identical(cloud.current, second), isTrue);
      second.put('b', 'bytes');
      expect((await cloud.snapshot()).map((item) => item.path), contains('b'));
    },
  );
}

class _SlowUploadCloud extends FakeCloud {
  _SlowUploadCloud({required this.readBack});
  final bool readBack;
  final release = Completer<void>();
  bool closed = false;
  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    await release.future;
    lastUploadReadBack = readBack;
    return '"slow"';
  }

  @override
  void close() => closed = true;
}
