// Spec #22 "Client during window": the nightly backup puts Nextcloud in
// maintenance mode, so every gateway request answers 503 for a few minutes.
// The client must treat that as transient: keep local files and pending
// changes, show no data-loss state, and resume on the next pass.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// The fixture backend in maintenance: every call fails exactly as the real
/// DAV transport reports a 503 (see the transport group below).
class MaintenanceCloud extends FakeCloud {
  bool maintenance = false;
  int refused = 0;

  @override
  void check() {
    super.check();
    if (maintenance) {
      refused++;
      throw CloudFailure(DavCloud.failureMessage(503), status: 503);
    }
  }

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    if (maintenance) {
      refused++;
      throw TransferInterrupted(
        DavCloud.failureMessage(503),
        TransferFailure.server,
        status: 503,
      );
    }
    return super.upload(path, source, etag: etag);
  }
}

void main() {
  group('real transport against a gateway answering 503', () {
    late Directory fixture;
    late File ca;
    late HttpServer server;
    late DavCloud api;

    setUpAll(() async {
      fixture = Directory.systemTemp.createTempSync('anj-maintenance-');
      ca = File('${fixture.path}/server.crt');
      final key = File('${fixture.path}/server.key');
      final result = await Process.run(testOpenssl!, [
        'req',
        '-x509',
        '-newkey',
        'ec',
        '-pkeyopt',
        'ec_paramgen_curve:P-256',
        '-noenc',
        '-keyout',
        key.path,
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
      expect(result.exitCode, 0);
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(ca.path)
          ..usePrivateKey(key.path),
      );
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 503;
        request.response.write('Service Unavailable');
        await request.response.close();
      });
      api = DavCloud(
        Uri.parse('https://127.0.0.1:${server.port}'),
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(ca.path),
      );
    });
    tearDownAll(() async {
      api.close();
      await server.close(force: true);
      fixture.deleteSync(recursive: true);
    });

    test('listing, download and upload report a retryable 503', () async {
      await expectLater(
        api.snapshot(),
        throwsA(
          isA<CloudFailure>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.message, 'message', contains('retained')),
        ),
      );
      await expectLater(
        api.download(
          'Documents/a.txt',
          File('${fixture.path}/d'),
          etag: '"v1"',
        ),
        throwsA(isA<CloudFailure>().having((e) => e.status, 'status', 503)),
      );
      final source = File('${fixture.path}/u')..writeAsStringSync('edit');
      await expectLater(
        api.upload('Documents/a.txt', source, etag: '"v1"'),
        throwsA(
          isA<TransferInterrupted>()
              .having((e) => e.kind, 'kind', TransferFailure.server)
              .having((e) => e.status, 'status', 503),
        ),
      );
      expect(source.readAsStringSync(), 'edit');
    });
  }, skip: opensslSkip);

  group('sync engine across a maintenance window', () {
    late Directory fixture;
    late RootTree tree;
    late Manifest store;
    late MaintenanceCloud cloud;
    late SyncEngine engine;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('anj-maintenance-sync-');
      final parent = Directory('${fixture.path}/a')..createSync();
      tree = RootTree.setup(parent.path, 'a', NativeRootFs());
      store = Manifest(Directory('${fixture.path}/profile-a'));
      store.setSetting('retention', 'local');
      cloud = MaintenanceCloud();
      engine = SyncEngine(store, tree, cloud);
    });
    tearDown(() {
      engine.close();
      fixture.deleteSync(recursive: true);
    });
    File local(String path) => File('${tree.root.path}/$path');

    test(
      '503 is transient: nothing deleted, work kept, sync resumes',
      () async {
        local('Documents/kept.txt').writeAsStringSync('synced before');
        local('Music/track.txt').writeAsStringSync('synced before');
        await engine.tick();
        expect(
          cloud.files.keys,
          containsAll(['Documents/kept.txt', 'Music/track.txt']),
        );
        final uploadsBefore = cloud.uploads;

        // The nightly window opens; local work continues.
        cloud.maintenance = true;
        local('Documents/kept.txt').writeAsStringSync('edited during window');
        local('Documents/new.txt').writeAsStringSync('created during window');
        for (var pass = 0; pass < 3; pass++) {
          await engine.tick();
        }
        expect(cloud.refused, greaterThan(0));
        expect(
          local('Documents/kept.txt').readAsStringSync(),
          'edited during window',
        );
        expect(
          local('Documents/new.txt').readAsStringSync(),
          'created during window',
        );
        expect(local('Music/track.txt').readAsStringSync(), 'synced before');
        expect(cloud.deletes, 0);
        expect(cloud.uploads, uploadsBefore);
        expect(
          store.operations.values.where((o) => o.kind == 'delete'),
          isEmpty,
        );
        final message = engine.message;
        expect(message, startsWith('Offline:'));
        expect(message, contains('Pending work is retained'));
        expect(
          message,
          isNot(
            matches(
              RegExp('lost|deleted|conflict|revoked', caseSensitive: false),
            ),
          ),
        );
        for (final entry in store.entries.values) {
          expect(entry.status.toLowerCase(), isNot(contains('conflict')));
        }

        // The window closes: the next pass uploads what was kept.
        cloud.maintenance = false;
        await engine.tick();
        await engine.tick();
        expect(
          String.fromCharCodes(cloud.files['Documents/kept.txt']!),
          'edited during window',
        );
        expect(
          String.fromCharCodes(cloud.files['Documents/new.txt']!),
          'created during window',
        );
        expect(cloud.deletes, 0);
        expect(local('Music/track.txt').existsSync(), isTrue);
      },
    );
  });
}
