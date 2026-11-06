import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_platform.dart';

/// The DAV client's sharing surface (spec #26) over real TLS: the listing's
/// permissions and share types, and the gateway's JSON sharing routes.
void main() {
  if (skipSuite('sharing DAV over a TLS fixture', opensslSkip)) return;
  late Directory fixture;
  late File ca;
  late File key;
  late HttpServer server;
  late DavCloud api;
  late Future<void> Function(HttpRequest) handler;
  final seen = <(String, String, String)>[];

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-sharing-dav-');
    ca = File('${fixture.path}/server.crt');
    key = File('${fixture.path}/server.key');
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
    if (result.exitCode != 0) throw StateError('TLS fixture setup failed.');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));
  setUp(() async {
    seen.clear();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(ca.path)
        ..usePrivateKey(key.path),
    );
    server.listen((request) async {
      seen.add((
        request.method,
        request.uri.toString(),
        await utf8.decoder.bind(request).join(),
      ));
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

  Future<void> reply(HttpRequest request, int status, Object? body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  test('the listing asks for and keeps permissions and share types', () async {
    handler = (request) async {
      request.response.statusCode = 207;
      String item(
        String href, {
        String? permissions,
        bool shared = false,
        bool dir = true,
      }) =>
          '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
          '<d:resourcetype>${dir ? '<d:collection/>' : ''}</d:resourcetype><d:getetag>"e"</d:getetag>'
          '${permissions == null ? '' : '<oc:permissions>$permissions</oc:permissions>'}'
          '<oc:share-types>${shared ? '<oc:share-type>0</oc:share-type>' : ''}</oc:share-types>'
          '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
      final path = request.uri.path.endsWith('/')
          ? request.uri.path
          : '${request.uri.path}/';
      request.response.write(
        '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
        '${path == '/dav/' ? item('/dav/') + item('/dav/Family/', permissions: 'RGDNVCK', shared: true) + item('/dav/Shared/', permissions: 'RGDNVCK') : ''}'
        '${path == '/dav/Family/' ? item('/dav/Family/') : ''}'
        '${path == '/dav/Shared/' ? item('/dav/Shared/') + item('/dav/Shared/Photos/', permissions: 'SGDN') : ''}'
        '${path == '/dav/Shared/Photos/' ? item('/dav/Shared/Photos/') + item('/dav/Shared/Photos/a.txt', permissions: 'SG', dir: false) + item('/dav/Shared/Photos/b.txt', permissions: 'rw', dir: false) : ''}'
        '</d:multistatus>',
      );
      await request.response.close();
    };
    final items = {for (final item in await api.snapshot()) item.path: item};
    expect(seen.first.$3, contains('<oc:permissions/><oc:share-types/>'));
    expect(
      (items['Family']!.permissions, items['Family']!.shared),
      ('RGDNVCK', true),
    );
    expect(
      (items['Shared/Photos']!.permissions, items['Shared/Photos']!.shared),
      ('SGDN', false),
    );
    expect(items['Shared/Photos/a.txt']!.permissions, 'SG');
    expect(items['Shared/Photos/b.txt']!.permissions, isNull);
    expect(permissionsViewOnly('SGDN', directory: true), isTrue);
    expect(permissionsViewOnly('SGDNVCK', directory: true), isFalse);
    expect(permissionsViewOnly('SG', directory: false), isTrue);
    expect(permissionsViewOnly('SGDNVW', directory: false), isFalse);
  });

  test(
    'sharing routes: JSON bodies, no query strings, curated errors',
    () async {
      handler = (request) async {
        switch ((request.method, request.uri.path)) {
          case ('GET', '/v1/household/users'):
            await reply(request, 200, [
              {'id': 'bob', 'display_name': 'Bob'},
            ]);
          case ('GET', '/v1/shares/outgoing'):
            await reply(request, 200, [
              {
                'share_id': '3',
                'path': 'Family',
                'recipient_id': 'bob',
                'recipient_display_name': 'Bob',
                'permission': 'view',
              },
            ]);
          case ('GET', '/v1/shares/incoming'):
            await reply(request, 200, [
              {
                'share_id': '4',
                'path': 'Shared/Photos',
                'owner_display_name': 'Alice',
                'permission': 'edit',
                'owner_unavailable': true,
              },
            ]);
          case ('POST', '/v1/shares'):
            await reply(request, 409, {
              'error': 'This person already has access; change their permission instead',
            });
          case ('PATCH', '/v1/shares/3'):
            await reply(request, 200, {
              'share_id': '3',
              'path': 'Family',
              'recipient_id': 'bob',
              'recipient_display_name': 'Bob',
              'permission': 'edit',
            });
          case ('DELETE', '/v1/shares/3'):
            await reply(request, 503, {
              'error': 'Writes are paused pending operator recovery',
            });
          default:
            await reply(request, 404, {'error': 'Not found'});
        }
      };
      expect((await api.householdUsers()).single.displayName, 'Bob');
      final outgoing = (await api.outgoingShares()).single;
      expect(
        (outgoing.path, outgoing.recipientName, outgoing.permission),
        ('Family', 'Bob', SharePermission.view),
      );
      final incoming = (await api.incomingShares())!.single;
      expect(
        (incoming.path, incoming.ownerName, incoming.ownerUnavailable),
        ('Shared/Photos', 'Alice', true),
      );
      await expectLater(
        api.createShare('Family', 'bob', SharePermission.edit),
        throwsA(
          isA<CloudFailure>()
              .having((e) => e.status, 'status', 409)
              .having(
                (e) => e.message,
                'message',
                contains('already has access'),
              ),
        ),
      );
      expect(jsonDecode(seen.last.$3), {
        'path': 'Family',
        'recipient_id': 'bob',
        'permission': 'edit',
      });
      expect(
        (await api.updateShare('3', SharePermission.edit)).permission,
        SharePermission.edit,
      );
      expect(jsonDecode(seen.last.$3), {'permission': 'edit'});
      await expectLater(
        api.removeShare('3'),
        throwsA(isA<CloudFailure>().having((e) => e.status, 'status', 503)),
      );
      await expectLater(api.removeShare('../3'), throwsA(isA<CloudFailure>()));
      expect(seen.every((request) => !request.$2.contains('?')), isTrue);
    },
  );

  test(
    'an older gateway without sharing routes: no incoming list, no error',
    () async {
      handler = (request) => reply(request, 404, {'error': 'Not found'});
      expect(await api.incomingShares(), isNull);
    },
  );

  test('decision #155: rename for everyone is its own POST', () async {
    handler = (request) async {
      switch ((request.method, request.uri.path)) {
        case ('POST', '/v1/shares/incoming/4/rename'):
          await reply(request, 200, {
            'state': 'renamed',
            'path': 'Documents/Taxes 2025',
          });
        case ('POST', '/v1/shares/incoming/5/rename'):
          await reply(request, 409, {'error': "The owner's device is needed"});
        case ('POST', '/v1/shares/incoming/6/rename'):
          await reply(request, 200, {'state': 'renamed', 'path': 'Elsewhere'});
        default:
          await reply(request, 404, {'error': 'Share not found'});
      }
    };
    expect(
      await api.renameForEveryone('4', 'Taxes 2025'),
      'Documents/Taxes 2025',
    );
    expect(jsonDecode(seen.last.$3), {'name': 'Taxes 2025'});
    await expectLater(
      api.renameForEveryone('6', 'x'),
      throwsA(isA<CloudFailure>()),
    );
    await expectLater(
      api.renameForEveryone('5', 'x'),
      throwsA(
        isA<CloudFailure>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.message, 'message', contains("owner's device")),
      ),
    );
    await expectLater(
      api.renameForEveryone('../4', 'x'),
      throwsA(isA<CloudFailure>()),
    );
  });

  test('an incoming path outside its allowed places is refused', () async {
    for (final path in [
      'Elsewhere',
      'Shared',
      'Shared/a/b',
      'Documents',
      'Documents/a/b',
      'Photos/x',
    ]) {
      handler = (request) => reply(request, 200, [
        {
          'share_id': '4',
          'path': path,
          'owner_display_name': 'Alice',
          'permission': 'edit',
        },
      ]);
      await expectLater(
        api.incomingShares(),
        throwsA(isA<CloudFailure>()),
        reason: path,
      );
    }
  });

  test(
    'spec #34 P6: placed shares are listed; leaving one is its own DELETE',
    () async {
      handler = (request) async {
        switch ((request.method, request.uri.path)) {
          case ('GET', '/v1/shares/incoming'):
            await reply(request, 200, [
              for (final path in ['Documents/Taxes', 'Music/Live', 'Videos/x'])
                {
                  'share_id': '4',
                  'path': path,
                  'owner_display_name': 'Sam',
                  'permission': 'view',
                },
            ]);
          case ('DELETE', '/v1/shares/incoming/4'):
            await reply(request, 200, {'state': 'left'});
          default:
            await reply(request, 404, {'error': 'Share not found'});
        }
      };
      expect(
        [for (final share in (await api.incomingShares())!) share.path],
        ['Documents/Taxes', 'Music/Live', 'Videos/x'],
      );
      await api.leaveShare('4');
      expect((seen.last.$1, seen.last.$2), ('DELETE', '/v1/shares/incoming/4'));
      await expectLater(
        api.leaveShare('5'),
        throwsA(isA<CloudFailure>().having((e) => e.status, 'status', 404)),
      );
      await expectLater(api.leaveShare('../4'), throwsA(isA<CloudFailure>()));
    },
  );
}
