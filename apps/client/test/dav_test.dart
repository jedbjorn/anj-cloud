import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/access/documents_service.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/android/android_documents.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  if (skipSuite('DAV client over a synthetic TLS gateway', opensslSkip)) return;
  late Directory fixture;
  late File ca;
  late File serverKey;
  late HttpServer server;
  late Uri origin;
  late Future<void> Function(HttpRequest) handler;
  late DavCloud api;
  final requests = <Map<String, String?>>[];
  Future<void> openssl(List<String> args) async {
    final result = await Process.run(testOpenssl!, args);
    if (result.exitCode != 0) {
      throw StateError('Synthetic TLS fixture setup failed.');
    }
  }

  SecurityContext trust() =>
      SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca.path);
  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChain(ca.path)
    ..usePrivateKey(serverKey.path)
    ..setTrustedCertificates(ca.path);
  Future<HttpServer> startServer({bool mutual = false}) async {
    final result = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext(),
      requestClientCertificate: mutual,
    );
    result.listen((request) async {
      if (mutual && request.certificate == null) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'match': request.headers.value('if-match'),
        'none': request.headers.value('if-none-match'),
        'depth': request.headers.value('depth'),
      });
      await handler(request);
    });
    return result;
  }

  String response(
    String href, {
    bool directory = false,
    int status = 200,
    String version = 'v1',
  }) =>
      '<d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype><d:getetag>&quot;$version&quot;</d:getetag><d:getcontentlength>4</d:getcontentlength></d:prop><d:status>HTTP/1.1 $status Result</d:status></d:propstat></d:response>';
  String listing(List<String> items) =>
      '<d:multistatus xmlns:d="DAV:">${items.join()}</d:multistatus>';
  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-dav-fixture-');
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
  tearDownAll(() {
    fixture.deleteSync(recursive: true);
  });
  setUp(() async {
    requests.clear();
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.set('etag', '"v2"');
      request.response.statusCode =
          request.method == 'PUT' || request.method == 'MKCOL' ? 201 : 204;
      await request.response.close();
    };
    server = await startServer();
    origin = Uri.parse('https://127.0.0.1:${server.port}');
    api = DavCloud(origin, trust());
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });
  test('real TLS transport preserves concrete conditional mutations', () async {
    final file = File('${fixture.path}/upload')..writeAsStringSync('test');
    expect(await api.upload('Documents/new.txt', file, etag: null), '"v2"');
    expect(await api.upload('Documents/new.txt', file, etag: '"v1"'), '"v2"');
    await api.mkdir('Documents/new folder');
    await api.deleteFile('Documents/new.txt', etag: '"v2"');
    expect(requests.map((r) => r['method']), ['PUT', 'PUT', 'MKCOL', 'DELETE']);
    expect(requests[0]['none'], '*');
    expect(requests[1]['match'], '"v1"');
    expect(requests[2]['none'], '*');
    expect(requests[3]['match'], '"v2"');
  });
  test('422 name-not-portable becomes NameNotPortable; other 422s do not', () async {
    var body =
        '{"error": "name-not-portable", "reason": "forbiddenName", "message": "x"}';
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 422;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    };
    final file = File('${fixture.path}/upload')..writeAsStringSync('test');
    await expectLater(
      api.upload('Documents/notes.txt', file, etag: null),
      throwsA(
        isA<NameNotPortable>()
            .having((e) => e.problem, 'problem', CloudNameProblem.forbiddenName)
            .having(
              (e) => e.message,
              'message',
              "Can't sync this name: the cloud does not allow this name",
            ),
      ),
    );
    body = '{"error": "name-not-portable", "reason": "tooLong"}';
    await expectLater(
      api.mkdir('Documents/folder'),
      throwsA(
        isA<NameNotPortable>().having(
          (e) => e.problem,
          'problem',
          CloudNameProblem.tooLong,
        ),
      ),
    );
    body = '{"error": "something-else"}';
    await expectLater(
      api.upload('Documents/notes.txt', file, etag: null),
      throwsA(
        isA<CloudFailure>()
            .having((e) => e is NameNotPortable, 'name', isFalse)
            .having((e) => e.status, 'status', 422),
      ),
    );
    body = 'not json';
    await expectLater(
      api.mkdir('Documents/folder'),
      throwsA(
        isA<CloudFailure>().having(
          (e) => e is NameNotPortable,
          'name',
          isFalse,
        ),
      ),
    );
  });
  test(
    'Depth1 traversal preserves spaces percent and Unicode without leaving DAV',
    () async {
      final child = Uri(pathSegments: ['dav', 'Documents', 'space % 雪.txt'])
          .path;
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 207;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write(
          request.uri.path == '/dav/'
              ? listing([
                  response('/dav/', directory: true),
                  response('/dav/Documents/', directory: true),
                ])
              : listing([
                  response('/dav/Documents/', directory: true),
                  response(child),
                ]),
        );
        await request.response.close();
      };
      final entries = await api.snapshot();
      expect(entries.map((e) => e.path), contains('Documents/space % 雪.txt'));
      expect(requests.every((r) => r['depth'] == '1'), isTrue);
    },
  );
  test(
    'foreign href and failed root propstat reject the entire listing',
    () async {
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 207;
        request.response.write(
          listing([
            response('/dav/', directory: true),
            response('https://foreign.invalid/dav/file'),
          ]),
        );
        await request.response.close();
      };
      await expectLater(api.snapshot(), throwsA(isA<CloudFailure>()));
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 207;
        request.response.write(
          listing([response('/dav/', directory: true, status: 403)]),
        );
        await request.response.close();
      };
      await expectLater(api.snapshot(), throwsA(isA<CloudFailure>()));
    },
  );
  test('listing sends an explicit PROPFIND body and reads file ID and modified time', () async {
    final bodies = <String>[];
    handler = (request) async {
      bodies.add(await utf8.decodeStream(request));
      request.response.statusCode = 207;
      // Nextcloud answers properties a resource lacks in a 404 propstat.
      request.response.write(
        '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
        '<d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getetag>"r"</d:getetag><oc:fileid>2</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '<d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>'
        '<d:response><d:href>/dav/a.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getetag>"a"</d:getetag><d:getcontentlength>3</d:getcontentlength>'
        '<d:getlastmodified>Mon, 02 Nov 2026 17:04:09 GMT</d:getlastmodified><oc:fileid>646</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
        '<d:response><d:href>/dav/legacy.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getetag>"l"</d:getetag><d:getlastmodified>not a date</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '<d:propstat><d:prop><oc:fileid/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>'
        '</d:multistatus>',
      );
      await request.response.close();
    };
    final items = {for (final item in await api.snapshot()) item.path: item};
    expect(bodies.single, listingPropfind);
    for (final property in [
      'd:resourcetype',
      'd:getetag',
      'd:getcontentlength',
      'd:getlastmodified',
      'oc:fileid',
    ]) {
      expect(bodies.single, contains('<$property/>'));
    }
    expect(items['a.txt']!.fileId, 646);
    expect(items['a.txt']!.size, 3);
    expect(
      items['a.txt']!.modified,
      DateTime.utc(2026, 11, 2, 17, 4, 9).millisecondsSinceEpoch ~/ 1000,
    );
    // Missing or malformed values leave the entry undated, never failed.
    expect(items['legacy.txt']!.fileId, isNull);
    expect(items['legacy.txt']!.modified, isNull);
  });
  test(
    'added times: pages parse, a 404 means none, a bad page fails',
    () async {
      var reply = (HttpRequest request) async {};
      handler = (request) => reply(request);
      reply = (request) async {
        expect(request.uri.path, '/v1/files/added');
        expect(request.uri.queryParameters, {'after': '7'});
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"added":{"646":1793639049.5,"700":1793639100},"cursor":12,"more":true,"reset":false}',
        );
        await request.response.close();
      };
      final page = (await api.addedSince(7))!;
      expect(page.added, {646: 1793639049, 700: 1793639100});
      expect((page.cursor, page.more, page.reset), (12, true, false));
      reply = (request) async {
        request.response.statusCode = 404;
        await request.response.close();
      };
      expect(await api.addedSince(0), isNull);
      for (final body in [
        'not json',
        '{"added":[],"cursor":1,"more":false}',
        '{"added":{"x":1},"cursor":1,"more":false}',
        '{"added":{"1":"soon"},"cursor":1,"more":false}',
        '{"added":{},"cursor":-1,"more":false}',
        '{"added":{},"cursor":1}',
      ]) {
        reply = (request) async {
          request.response.write(body);
          await request.response.close();
        };
        await expectLater(api.addedSince(0), throwsA(isA<CloudFailure>()));
      }
      reply = (request) async {
        request.response.statusCode = 403;
        await request.response.close();
      };
      await expectLater(
        api.addedSince(0),
        throwsA(isA<CloudFailure>().having((f) => f.status, 'status', 403)),
      );
    },
  );
  test('redirects are not followed and downloads remain guarded', () async {
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 302;
      request.response.headers.set('location', 'https://foreign.invalid/file');
      await request.response.close();
    };
    final output = File('${fixture.path}/redirect-target');
    await expectLater(
      api.download('file', output, etag: '"v1"'),
      throwsA(isA<CloudFailure>()),
    );
    expect(requests.length, 1);
    expect(requests.single['match'], '"v1"');
    expect(output.existsSync(), isFalse);
  });
  test(
    'TLS hostname mismatch fails without insecure certificate callback',
    () async {
      final wrong = DavCloud(origin.replace(host: 'localhost'), trust());
      try {
        await expectLater(wrong.snapshot(), throwsA(isA<HandshakeException>()));
      } finally {
        wrong.close();
      }
    },
  );
  Future<({File key, File cert})> enrolledIdentity() async {
    final clientKey = File('${fixture.path}/client.key');
    final csr = File('${fixture.path}/client.csr');
    final cert = File('${fixture.path}/client.crt');
    await openssl([
      'req',
      '-new',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      clientKey.path,
      '-out',
      csr.path,
      '-subj',
      '/CN=synthetic-client',
    ]);
    await openssl([
      'x509',
      '-req',
      '-in',
      csr.path,
      '-CA',
      ca.path,
      '-CAkey',
      serverKey.path,
      '-set_serial',
      '7',
      '-out',
      cert.path,
      '-days',
      '1',
    ]);
    return (key: clientKey, cert: cert);
  }

  test('mutual TLS succeeds only with a trusted client identity', () async {
    final identity = await enrolledIdentity();
    final mutual = await startServer(mutual: true);
    final address = origin.replace(port: mutual.port);
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 207;
      request.response.write(listing([response('/dav/', directory: true)]));
      await request.response.close();
    };
    final missing = DavCloud(address, trust());
    final enrolled = DavCloud(
      address,
      trust()
        ..usePrivateKey(identity.key.path)
        ..useCertificateChain(identity.cert.path),
    );
    try {
      await expectLater(missing.snapshot(), throwsA(isA<Exception>()));
      expect(await enrolled.snapshot(), isEmpty);
    } finally {
      missing.close();
      enrolled.close();
      await mutual.close(force: true);
    }
  });

  test(
    'Android foreground Open, pause, and reconnect while DAV walks are held',
    () async {
      final binding = _NetworkBinding();
      final identity = await enrolledIdentity();
      final mutual = await startServer(mutual: true);
      final parent = Directory('${fixture.path}/foreground-root')..createSync();
      final profile = Directory('${fixture.path}/foreground-profile');
      final fs = NativeRootFs();
      final tree = RootTree.setup(parent.path, 'foreground', fs);
      final store = Manifest(profile);
      final deviceOrigin = origin.replace(port: mutual.port).origin;
      const path = 'chosen.txt';
      const early = 'early.txt';
      const unread = 'unread.txt';
      for (final setting in {
        'root': tree.root.path,
        'staging': tree.staging.path,
        'rootIdentity': fs.rootInfo(tree.fd).identity,
        'retention': 'local',
        'profileId': 'foreground',
        'server': deviceOrigin,
        'accountOrigin': deviceOrigin,
        'accountUid': 'fixture-user',
        'ca': ca.path,
        'certificate': identity.cert.readAsStringSync(),
        'certificateExpires': DateTime.now()
            .add(const Duration(days: 365))
            .toIso8601String(),
      }.entries) {
        store.setSetting(setting.key, setting.value);
      }
      for (final name in [path, early, unread]) {
        store.entries[name] = Entry(name, ItemKind.file)
          ..etag = '"v1"'
          ..override = Retention.cloud
          ..status = 'cloud-only'
          ..size = 4;
      }
      store.save();
      store.close();
      tree.close();

      var walk = Completer<void>();
      var walking = Completer<void>();
      var viewed = Completer<String>();
      Completer<void>? rootReading;
      Completer<void>? rootRelease;
      Completer<void>? openReading;
      Completer<void>? openRelease;
      var version = 'v1';
      var folderVersion = 'v1';
      var offline = false;
      var denied = false;
      var rejectDownload = false;
      var dropSelected = false;
      var dropDownload = false;
      handler = (request) async {
        await request.drain<void>();
        final reply = request.response;
        final uri = request.uri.path;
        if (denied && uri.startsWith('/dav/')) {
          reply.statusCode = 403;
          await reply.close();
          return;
        }
        switch ((request.method, uri)) {
          case ('PROPFIND', '/dav/'):
            if (offline) {
              (await reply.detachSocket(writeHeaders: false)).destroy();
              return;
            }
            if (rootRelease case final wait?) {
              rootReading!.complete();
              await wait.future;
            }
            reply.statusCode = 207;
            reply.write(
              listing([
                response('/dav/', directory: true),
                for (final top in ['Documents', 'Music', 'Videos'])
                  response(
                    '/dav/$top/',
                    directory: true,
                    version: folderVersion,
                  ),
                response('/dav/Slow/', directory: true, version: folderVersion),
                response('/dav/$path', version: version),
                response('/dav/$early', version: 'v1'),
                response('/dav/$unread', version: 'v1'),
              ]),
            );
          case ('PROPFIND', '/dav/Slow'):
            if (!walking.isCompleted) walking.complete();
            await walk.future;
            reply.statusCode = 207;
            reply.write(listing([response('/dav/Slow/', directory: true)]));
          case ('PROPFIND', '/dav/Documents' || '/dav/Music' || '/dav/Videos'):
            reply.statusCode = 207;
            reply.write(listing([response('$uri/', directory: true)]));
          case (
            'PROPFIND',
            '/dav/chosen.txt' || '/dav/early.txt' || '/dav/unread.txt',
          ):
            expect(request.headers.value('depth'), '0');
            if (openRelease case final wait?) {
              openReading!.complete();
              await wait.future;
            }
            if (dropSelected) {
              (await reply.detachSocket(writeHeaders: false)).destroy();
              return;
            }
            reply.statusCode = 207;
            reply.write(listing([response(uri, version: version)]));
          case (
            'GET',
            '/dav/chosen.txt' || '/dav/early.txt' || '/dav/unread.txt',
          ):
            expect(request.headers.value('if-match'), '"$version"');
            if (dropDownload) {
              (await reply.detachSocket(writeHeaders: false)).destroy();
              return;
            }
            reply.statusCode = rejectDownload ? 412 : 200;
            if (!rejectDownload) {
              reply.headers.set('etag', '"$version"');
              reply.write('read');
            }
          case ('PUT', '/dav/changed.txt'):
            reply.statusCode = 201;
            reply.headers.set('etag', '"v1"');
          default:
            reply.statusCode = 404;
        }
        await reply.close();
      };

      final controller = ClientController(
        profile,
        secrets: MemorySecrets()
          ..values['anj-cloud:foreground:device-key'] = identity.key
              .readAsStringSync(),
        nativeLibrary: testNativeLibrary,
        launcher: AndroidLauncher(),
        androidForeground: true,
        defaultNetworkPolicy: 'wifi',
      );
      final service =
          AndroidDocuments.start(controller, profile.path) as DocumentsService;
      final messenger = binding.defaultBinaryMessenger;
      const apps = MethodChannel('cloud.anj/apps');
      messenger.setMockMethodCallHandler(apps, (call) async {
        expect(call.method, 'openDocument');
        final id = (call.arguments as Map)['id'] as String;
        expect(id, startsWith('w:'));
        final descriptor = await service.open(
          id,
          'r',
          const DocumentsCaller(CallerKind.document, documentRead: true),
        );
        final fd = descriptor['fd'] as int;
        try {
          viewed.complete(File('/proc/self/fd/$fd').readAsStringSync());
        } finally {
          fs.closeFd(fd);
          await service.closed(descriptor['token'] as String);
        }
        return true;
      });

      Future<void> until(
        bool Function() ready, {
        Duration timeout = const Duration(seconds: 5),
      }) async {
        final deadline = Stopwatch()..start();
        while (!ready()) {
          if (deadline.elapsed > timeout) {
            fail(
              'Foreground condition not reached: ${controller.status}, '
              '${controller.message}, ${controller.openNotice}, $requests',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      int rootReads() => requests
          .where((r) => r['method'] == 'PROPFIND' && r['path'] == '/dav/')
          .length;

      try {
        controller.reportNetwork(wifi: false, online: true);
        await controller.initialize();
        await walking.future.timeout(const Duration(seconds: 5));
        await until(() => controller.status == SyncStatus.checkingChanges);
        expect(
          controller.entries.any((entry) => entry['path'] == path),
          isTrue,
        );

        controller.windowShown(verify: true);
        controller.windowShown(verify: true);
        final background = controller.backgroundRun();
        controller.command('open', path);
        await until(() => controller.status == SyncStatus.waiting);
        expect(requests.where((r) => r['path'] == '/dav/$path'), isEmpty);

        version = 'v2';
        controller.reportNetwork(wifi: true, online: true);
        await until(() => controller.openNotice?.contains('changed') == true);
        expect(
          requests.where(
            (r) => r['method'] == 'GET' && r['path'] == '/dav/$path',
          ),
          isEmpty,
        );

        version = 'v1';
        rejectDownload = true;
        controller.command('open', path);
        await until(
          () =>
              requests.any(
                (r) => r['method'] == 'GET' && r['path'] == '/dav/$path',
              ) &&
              (controller.openNotice?.contains('changed') ?? false),
        );
        expect(viewed.isCompleted, isFalse);
        expect(controller.status, SyncStatus.checkingChanges);

        rejectDownload = false;
        controller.command('open', path);
        expect(await viewed.future.timeout(const Duration(seconds: 5)), 'read');
        expect(walk.isCompleted, isFalse);
        expect(controller.status, SyncStatus.checkingChanges);
        walk.complete();
        expect((await background)['listed'], isTrue);
        await until(() => controller.status == SyncStatus.upToDate);
        expect(requests.where((r) => r['path'] == '/dav/Slow'), hasLength(1));

        controller.setPaused(true);
        await until(
          () => controller.paused && controller.status == SyncStatus.paused,
        );
        final pausedRequests = requests
            .where((r) => r['path'] == '/dav/$path')
            .length;
        // A second uncached file is unnecessary: foreground Open must check
        // policy before reusing even an existing working copy.
        controller.command('open', path);
        await until(
          () => controller.openNotice?.contains('Resume sync') == true,
        );
        expect(
          requests.where((r) => r['path'] == '/dav/$path'),
          hasLength(pausedRequests),
        );

        offline = true;
        controller.setPaused(false);
        await until(() => controller.status == SyncStatus.offline);
        controller.reportNetwork(wifi: false, online: false);
        await until(() => controller.status == SyncStatus.offline);
        offline = false;
        denied = true;
        controller.reportNetwork(wifi: true, online: true);
        await until(() => controller.status == SyncStatus.accessDenied);
        final downloads = requests
            .where((r) => r['method'] == 'GET' && r['path'] == '/dav/$path')
            .length;
        controller.command('open', path);
        await until(() => controller.openNotice?.contains('revoked') == true);
        expect(
          requests.where(
            (r) => r['method'] == 'GET' && r['path'] == '/dav/$path',
          ),
          hasLength(downloads),
        );

        denied = false;
        for (var foreground = 0; foreground < 3; foreground++) {
          rootReading = Completer<void>();
          rootRelease = Completer<void>();
          controller.foregroundLeft();
          controller.windowShown(verify: true);
          await rootReading.future.timeout(const Duration(seconds: 5));
          await until(() => controller.status == SyncStatus.checkingServer);
          if (foreground == 0) {
            viewed = Completer<String>();
            controller.command('open', early);
            expect(
              await viewed.future.timeout(const Duration(seconds: 5)),
              'read',
            );
            expect(controller.status, SyncStatus.checkingChanges);
          }
          rootRelease.complete();
          rootRelease = null;
          // The last two returns have the same library and no background
          // command to force a full state event.
          await until(() => controller.status == SyncStatus.upToDate);
        }

        // Returning from Home joins WorkManager's authenticated run, which
        // still has a changed branch outstanding.
        folderVersion = 'v2';
        walk = Completer<void>();
        walking = Completer<void>();
        final beforeJoin = rootReads();
        controller.foregroundLeft();
        final workManager = controller.backgroundRun();
        await walking.future.timeout(const Duration(seconds: 5));
        controller.windowShown(verify: true);
        await until(() => controller.status == SyncStatus.checkingChanges);
        expect(rootReads(), beforeJoin + 1);
        walk.complete();
        expect((await workManager)['listed'], isTrue);
        await until(() => controller.status == SyncStatus.upToDate);
        expect(rootReads(), beforeJoin + 1);

        // Local work can start a listing between scheduled cloud checks.
        folderVersion = 'v3';
        walk = Completer<void>();
        walking = Completer<void>();
        File('${tree.root.path}/changed.txt').writeAsStringSync('local edit');
        await walking.future.timeout(const Duration(seconds: 10));
        controller.setPaused(true);
        await until(
          () =>
              controller.paused &&
              controller.message.contains(
                'Local changes sync after you resume',
              ),
        );
        final beforePause = requests.length;
        walk.complete();
        await until(
          () => controller.message.contains('will sync after you resume'),
        );
        expect(
          requests.skip(beforePause).where((r) => r['method'] == 'PROPFIND'),
          isEmpty,
        );
        controller.setPaused(false);
        final resumed = await controller.backgroundRun();
        expect(resumed['listed'], isTrue);
        await until(() => controller.status == SyncStatus.upToDate);
        expect(
          requests
              .skip(beforePause)
              .where((r) => r['method'] == 'PROPFIND')
              .map((r) => r['path']),
          containsAll([
            '/dav/',
            '/dav/Slow',
            '/dav/Videos',
            '/dav/Music',
            '/dav/Documents',
          ]),
        );

        // An obsolete Open failure cannot publish Reconnecting. A failure
        // from the current route must do so even with a DAV walk pending.
        controller.setNetworkPolicy('any');
        controller.reportNetwork(wifi: false, online: true, route: 1);
        folderVersion = 'v4';
        walk = Completer<void>();
        walking = Completer<void>();
        controller.windowShown(verify: true);
        await walking.future.timeout(const Duration(seconds: 5));
        await until(() => controller.status == SyncStatus.checkingChanges);
        openReading = Completer<void>();
        openRelease = Completer<void>();
        controller.command('open', path);
        await openReading.future.timeout(const Duration(seconds: 5));
        controller.reportNetwork(wifi: false, online: true, route: 2);
        dropSelected = true;
        openRelease.complete();
        openRelease = null;
        await until(
          () =>
              controller.openNotice?.contains('Could not open') == true &&
              controller.onWifi == false,
        );
        expect(controller.status, SyncStatus.checkingChanges);
        controller.command('open', path);
        await until(() => controller.status == SyncStatus.offline);
        expect(walk.isCompleted, isFalse);
        walk.complete();

        final beforeRoute = rootReads();
        dropSelected = false;
        controller.reportNetwork(wifi: false, online: true, route: 2);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(rootReads(), beforeRoute);
        expect(controller.status, SyncStatus.offline);
        // Validated mobile data to validated Wi-Fi must cut short backoff.
        controller.reportNetwork(wifi: true, online: true, route: 3);
        controller.reportNetwork(wifi: true, online: true, route: 3);
        await until(
          () => rootReads() > beforeRoute,
          timeout: const Duration(milliseconds: 1200),
        );
        await until(() => controller.status == SyncStatus.upToDate);
        expect(rootReads(), beforeRoute + 1);

        // Metadata can authenticate successfully and the conditional GET can
        // still lose the connection. Backoff retries with no lifecycle wake.
        final beforeDownload = rootReads();
        dropDownload = true;
        controller.command('open', unread);
        await until(() => controller.status == SyncStatus.offline);
        expect(
          requests.where(
            (r) => r['method'] == 'GET' && r['path'] == '/dav/$unread',
          ),
          hasLength(1),
        );
        dropDownload = false;
        await until(
          () => controller.status == SyncStatus.upToDate,
          timeout: const Duration(seconds: 12),
        );
        expect(rootReads(), beforeDownload + 1);
      } finally {
        if (!walk.isCompleted) walk.complete();
        if (rootRelease case final wait? when !wait.isCompleted) {
          wait.complete();
        }
        if (openRelease case final wait? when !wait.isCompleted) {
          wait.complete();
        }
        await controller.stop();
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(apps, null);
        await mutual.close(force: true);
      }
    },
    skip: linuxOnly('checks the Android provider descriptor through /proc'),
  );
  test('existing account profile refuses another UID before certificate activation', () async {
    final profile = Directory('${fixture.path}/bound-profile');
    final store = Manifest(profile);
    store.setSetting('profileId', 'bound-profile');
    store.setSetting('accountUid', 'original-user');
    store.setSetting('accountOrigin', origin.origin);
    store.close();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'state': 'approved',
          'uid': 'other-user',
          'rights': 'write',
          'device_id': 'synthetic-device',
          'certificate': 'not reached',
        }),
      );
      await request.response.close();
    };
    try {
      await expectLater(
        controller.pair(
          origin.toString(),
          '0123456789ABCDEFGHJKMNPQRSTVWXYZ',
          caPath: ca.path,
        ),
        throwsA(isA<FormatException>()),
      );
      final check = Manifest(profile);
      expect(check.setting('accountUid'), 'original-user');
      expect(check.setting('certificate'), isNull);
      check.close();
    } finally {
      controller.dispose();
    }
  });
  test('manifest activation settings roll back together on failure', () {
    final store = Manifest(Directory('${fixture.path}/atomic-profile'));
    try {
      expect(
        () => store.transaction(() {
          store.setSetting('certificate', 'public fixture');
          store.setSetting('accountUid', 'fixture-user');
          throw StateError('injected interruption');
        }),
        throwsStateError,
      );
      expect(store.setting('certificate'), isNull);
      expect(store.setting('accountUid'), isNull);
    } finally {
      store.close();
    }
  });
  test(
    'root cannot enclose the active profile manifest or lock file',
    () async {
      final parent = Directory('${fixture.path}/overlap')..createSync();
      final profile = Directory('${parent.path}/anj-cloud/private-profile');
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      try {
        await controller.initialize();
        await expectLater(
          controller.configureRoot(parent.path),
          throwsA(isA<FileSystemException>()),
        );
        final state = Manifest(profile);
        expect(state.setting('root'), isNull);
        state.close();
        expect(File('${profile.path}/manifest.sqlite').existsSync(), isTrue);
        expect(
          Directory('${parent.path}/anj-cloud/Documents').existsSync(),
          isFalse,
        );
      } finally {
        controller.dispose();
      }
    },
  );
  test(
    '413 is a size refusal with the reported limit; the source is retained',
    () async {
      final source = File('${fixture.path}/limited-source')
        ..writeAsStringSync('pending source');
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Anj-Upload-Limit', '67108864');
        request.response.write(
          jsonEncode({
            'error': 'transfer_limit',
            'actual_bytes': 67108865,
            'max_bytes': 67108864,
          }),
        );
        await request.response.close();
      };
      await expectLater(
        api.upload('oversized.bin', source, etag: null),
        throwsA(
          isA<UploadTooLarge>()
              .having((error) => error.limit, 'limit', 67108864)
              .having((error) => error.status, 'status', 413)
              .having(
                (error) => error.message,
                'message',
                'Too large for the server (limit 64 MB). It stays on this device.',
              ),
        ),
      );
      expect(source.readAsStringSync(), 'pending source');
      expect(api.uploadLimit, 67108864);
    },
  );
  test('an older gateway 413 (body only) still names the limit', () async {
    final source = File('${fixture.path}/old-413')..writeAsStringSync('x');
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 413;
      request.response.write(
        jsonEncode({'error': 'transfer_limit', 'max_bytes': 1048576}),
      );
      await request.response.close();
    };
    await expectLater(
      api.upload('old.bin', source, etag: null),
      throwsA(isA<UploadTooLarge>().having((e) => e.limit, 'limit', 1048576)),
    );
    expect(api.uploadLimit, isNull, reason: 'only the header sets it');
  });
  test(
    'a limit reported on any response stops oversized uploads locally',
    () async {
      handler = (request) async {
        await request.drain<void>();
        request.response.headers.set('X-Anj-Upload-Limit', '8');
        request.response.statusCode = 207;
        request.response.write(listing([response('/dav/', directory: true)]));
        await request.response.close();
      };
      await api.snapshot();
      expect(api.uploadLimit, 8);
      requests.clear();
      final source = File('${fixture.path}/nine-bytes')
        ..writeAsStringSync('123456789');
      await expectLater(
        api.upload('nine.bin', source, etag: null),
        throwsA(isA<UploadTooLarge>().having((e) => e.size, 'size', 9)),
      );
      expect(requests, isEmpty, reason: 'not a byte sent');
    },
  );
  test('a server that hangs up mid-body is a write interruption', () async {
    final source = File('${fixture.path}/large-source');
    final sink = source.openSync(mode: FileMode.write);
    sink.truncateSync(32 * 1024 * 1024);
    sink.closeSync();
    handler = (request) async {
      // An older gateway: refuse without reading the body, then hang up.
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    };
    await expectLater(
      api.upload('large.bin', source, etag: null),
      throwsA(
        isA<TransferInterrupted>().having(
          (e) => e.kind,
          'kind',
          TransferFailure.write,
        ),
      ),
    );
  });
  test('server errors on upload are interruptions with their status', () async {
    final source = File('${fixture.path}/small')..writeAsStringSync('x');
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 503;
      await request.response.close();
    };
    await expectLater(
      api.upload('small.bin', source, etag: null),
      throwsA(
        isA<TransferInterrupted>()
            .having((e) => e.kind, 'kind', TransferFailure.server)
            .having((e) => e.status, 'status', 503),
      ),
    );
  });
  test(
    'grouped manual and QR invitations submit the same canonical secret',
    () async {
      const code = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      final submitted = <String>[];
      handler = (request) async {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        submitted.add(body['code'] as String);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'state': 'pending'}));
        await request.response.close();
      };
      final client = PairingClient(origin, trust());
      try {
        await client.enroll(code, 'public fixture CSR', label: 'fixture');
        await client.enroll(
          '0123-4567-89ab-cdef-ghjk-mnpq-rstv-wxyz',
          'public fixture CSR',
        );
        expect(submitted, [code, code]);
      } finally {
        client.close();
      }
    },
  );
}
