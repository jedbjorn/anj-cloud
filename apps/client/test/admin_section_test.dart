import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/admin_api.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/pairing_code_qr.dart';
import 'package:anj_cloud/ui/app.dart';

import 'fakes.dart';
import 'layout_fixtures.dart';
import 'test_platform.dart';

const ownDevice = '11111111-1111-4111-8111-111111111111';
const amyDevice = '22222222-2222-4222-8222-222222222222';
const jedLaptop = '55555555-5555-4555-8555-555555555555';
const pendingId = '33333333-3333-4333-8333-333333333333';
const codeId = '44444444-4444-4444-8444-444444444444';
final deviceFingerprint = 'ab' * 32;

/// The gateway admin API as the Admin section sees it; records every request.
class FakeAdmin {
  final requests = <(String, String, Map<String, Object?>?)>[];
  bool notAdmin = false;
  bool pendingUser = false;
  bool failDevices = false;
  String? staleOn;

  Iterable<(String, String, Map<String, Object?>?)> mutations() =>
      requests.where((request) => request.$1 != 'GET');

  Future<AdminResponse> call(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    requests.add((method, path, body));
    if (notAdmin) {
      return const AdminResponse(403, {
        'error': 'not-admin',
        'message': 'Your admin role was removed.',
      });
    }
    if (method == 'GET' && failDevices && path == '/v1/admin/devices') {
      return const AdminResponse(500, {
        'error': 'internal',
        'message': 'Device list failed.',
      });
    }
    if (method == 'GET') return AdminResponse(200, _get(path));
    if (staleOn == path) {
      return const AdminResponse(409, {
        'error': 'stale',
        'message':
            'This changed since it was shown; the list has been refreshed.',
        'revision': 'r2',
      });
    }
    final destructive =
        path.endsWith('/revoke') ||
        path.endsWith('/reissue') ||
        path.endsWith('/deny') ||
        path.endsWith('/admin') ||
        path == '/v1/admin/settings' ||
        (path.endsWith('/enabled') && body?['enabled'] == false);
    if (destructive && body?['confirm'] == null) {
      return AdminResponse(428, {
        'error': 'confirmation-required',
        'message': 'Confirm',
        'title': path.endsWith('/revoke')
            ? 'Revoke the VM host (sam)?'
            : 'Confirm?',
        'effect': path.endsWith('/revoke')
            ? 'This device stops syncing at once and must be paired again to return.'
            : 'Server effect text.',
        'confirm_token': 'token-1',
        'second_factor_typed': path.contains(ownDevice) ? 'sam' : null,
      });
    }
    if (path == '/v1/admin/invitations') {
      return const AdminResponse(201, {
        'id': codeId,
        'uid': 'alex',
        'grant': 'write',
        'code': 'ABCD1234EFGH5678JKMN9012PQRS3456',
        'expires_at': '2026-11-03T12:00:00Z',
      });
    }
    if (path.endsWith('/approve')) {
      return body?['fingerprint'] == deviceFingerprint
          ? const AdminResponse(200, {'state': 'active'})
          : const AdminResponse(409, {
              'error': 'fingerprint-mismatch',
              'message': 'The fingerprint does not match the new device; nothing was approved.',
            });
    }
    return const AdminResponse(200, {'state': 'ok'});
  }

  Map<String, Object?> _get(String path) => switch (path.split('?').first) {
    '/v1/admin/users' => {
      'users': [
        {
          'uid': 'sam',
          'display_name': 'Sam',
          'enabled': true,
          'admin': true,
          'active_devices': 1,
          'revision': 'u1',
        },
        {
          'uid': 'alex',
          'display_name': 'Alex',
          'enabled': true,
          'admin': false,
          'active_devices': 1,
          'revision': 'u2',
        },
        if (pendingUser)
          {
            'uid': 'zoe',
            'display_name': 'Zoe',
            'enabled': false,
            'admin': false,
            'active_devices': 0,
            'setup_incomplete': true,
            'revision': 'u3',
          },
      ],
    },
    '/v1/admin/devices' => {
      'devices': [
        {
          'id': ownDevice,
          'uid': 'sam',
          'display_name': 'Sam',
          'label': 'the VM host',
          'grant': 'write',
          'state': 'active',
          'last_seen': '2026-11-03T10:00:00Z',
          'certificate_expires': '2036-11-01T00:00:00Z',
          'transition_leaves': 0,
          'this_device': true,
          'revision': 'd1',
        },
        {
          'id': amyDevice,
          'uid': 'alex',
          'display_name': 'Alex',
          'label': 'Pixel',
          'grant': 'write',
          'state': 'active',
          'last_seen': null,
          'certificate_expires': '2036-11-01T00:00:00Z',
          'transition_leaves': 0,
          'this_device': false,
          'revision': 'd2',
        },
        {
          'id': jedLaptop,
          'uid': 'sam',
          'display_name': 'Sam',
          'label': 'Laptop',
          'computer_name': 'laptop',
          'fingerprint_short': '6150cf05',
          'grant': 'read',
          'state': 'active',
          'last_seen': '2026-11-04T08:30:00Z',
          'certificate_expires': '2036-11-01T00:00:00Z',
          'transition_leaves': 0,
          'this_device': false,
          'revision': 'd3',
        },
      ],
    },
    '/v1/admin/invitations' => {
      'pending': [
        {
          'id': pendingId,
          'uid': 'alex',
          'grant': 'write',
          'label': 'Alex tablet',
          'expires_at': '2026-11-03T12:00:00Z',
          'revision': 'i1',
        },
      ],
      'codes': [
        {
          'id': codeId,
          'uid': 'alex',
          'grant': 'read',
          'label': null,
          'expires_at': '2026-11-03T12:00:00Z',
          'revision': 'i2',
        },
      ],
    },
    '/v1/admin/settings' => {
      'upload_limit_mib': 64,
      'upload_limit_bytes': 64 * 1024 * 1024,
      'min_mib': 1,
      'max_mib': 64,
      'revision': 's1',
    },
    '/v1/admin/health' => {
      'gateway': {
        'ready': true,
        'write_fence': {'state': 'clear', 'kind': null},
        'enroll_blocks_24h': 2,
      },
      'server': {
        'state': 'ok',
        'certificates': {
          'state': 'ok',
          'certificates': [
            {
              'name': 'issuer',
              'state': 'ok',
              'expires_at': '2036-11-01T00:00:00Z',
              'days_left': 3650,
            },
            {
              'name': 'server',
              'state': 'expiring',
              'expires_at': '2026-11-20T00:00:00Z',
              'days_left': 17,
            },
          ],
        },
        'pm2': {
          'state': 'ok',
          'apps': [
            {'name': 'gateway', 'status': 'online', 'restarts': 0},
            {'name': 'console', 'status': 'stopped', 'restarts': 3},
          ],
        },
        'backup': {'state': 'not-configured'},
        'ddns': {'state': 'not-configured'},
        'data_disk': {'state': 'ok', 'used_percent': 41.5},
        'reboot_pending': {'state': 'ok', 'pending': true},
        'emergency_stop': {'state': 'ok', 'stopped': false},
      },
    },
    '/v1/admin/audit' => {
      'entries': [
        {
          'seq': 2,
          'time': '2026-11-03T10:00:00Z',
          'actor_uid': 'sam',
          'action': 'device-revoke',
          'target_uid': 'alex',
          'result': 'ok',
        },
      ],
      'after': null,
    },
    _ => const {},
  };
}

/// Opens [uid]'s device list in the Users section (spec #34 P8).
Future<void> showDevices(WidgetTester tester, String uid) async {
  await tester.tap(find.byKey(ValueKey('admin-user-expand:$uid')));
  await tester.pumpAndSettle();
}

Future<void> openAdmin(
  WidgetTester tester,
  FakeAdmin api, {
  ThemeData? theme,
  AdminView view = AdminView.users,
  VoidCallback? onNotAdmin,
  String server = 'https://gateway.example.com',
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AdminPage(
                    call: api.call,
                    onNotAdmin: onNotAdmin ?? () {},
                    server: server,
                    initial: view,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  test('admin requests outlast the gateway hold, actions its backend timeout, '
      'the app the worker', () {
    // SC-041 F1: each request is answered within OPERATION_HOLD (well inside
    // production HAProxy's 120 s idle limit); a slow approve or user add is
    // polled and shows its real result, never "Server did not respond." while
    // the gateway still completes it (PR #43 review L2).
    final console = File('../../services/access/console.py').readAsStringSync();
    double constant(String name) => double.parse(
      RegExp(
        '^$name = ([0-9.]+)',
        multiLine: true,
      ).firstMatch(console)!.group(1)!,
    );
    expect(
      adminRequestTimeout.inSeconds,
      greaterThan(constant('OPERATION_HOLD')),
    );
    expect(adminReplyTimeout, greaterThan(adminRequestTimeout));
    expect(
      adminActionDeadline.inSeconds,
      greaterThan(constant('BACKEND_TIMEOUT')),
    );
  }, skip: checkoutFile('../../services/access/console.py'));

  group('long admin actions are polled', () {
    const operation = '0123456789abcdef0123456789abcdef';

    test('202 is followed to the action\'s own response', () async {
      final sent = <(String, String, Map<String, Object?>?)>[];
      var polls = 0;
      final client = AdminClient((method, path, {body}) async {
        sent.add((method, path, body));
        if (method == 'POST') {
          return const AdminResponse(202, {'operation': operation});
        }
        polls += 1;
        return polls < 3
            ? const AdminResponse(202, {'operation': operation})
            : const AdminResponse(201, {'uid': 'zoe', 'state': 'created'});
      });
      final result = await client.mutate('POST', '/v1/admin/users', {
        'uid': 'zoe',
        'display_name': 'Zoe',
      }, confirm: (_) async => '');
      expect(result, {'uid': 'zoe', 'state': 'created'});
      expect(sent.map((request) => '${request.$1} ${request.$2}'), [
        'POST /v1/admin/users',
        'GET /v1/admin/operations/$operation',
        'GET /v1/admin/operations/$operation',
        'GET /v1/admin/operations/$operation',
      ]);
      expect(sent.skip(1).every((request) => request.$3 == null), isTrue);
      expect(adminPathAllowed('/v1/admin/operations/$operation'), isTrue);
    });

    test('a confirmed action is polled too, and a refusal is shown', () async {
      final client = AdminClient((method, path, {body}) async {
        if (path.startsWith('/v1/admin/operations/')) {
          return const AdminResponse(409, {
            'error': 'last-admin',
            'message': 'Make another user an admin first.',
          });
        }
        if (body?['confirm'] == null) {
          return const AdminResponse(428, {
            'title': 'Disable alex?',
            'effect': 'Nothing is deleted.',
            'confirm_token': 'token',
          });
        }
        return const AdminResponse(202, {'operation': operation});
      });
      await expectLater(
        client.mutate('POST', '/v1/admin/users/alex/enabled', {
          'enabled': false,
        }, confirm: (_) async => ''),
        throwsA(
          isA<AdminFailure>()
              .having((failure) => failure.reason, 'reason', 'last-admin')
              .having((failure) => failure.status, 'status', 409),
        ),
      );
    });

    test(
      'an action past the deadline stops polling with a plain message',
      () async {
        var now = DateTime(2026, 11, 4, 12);
        var polls = 0;
        final client = AdminClient((method, path, {body}) async {
          if (path.startsWith('/v1/admin/operations/')) {
            polls += 1;
            now = now.add(const Duration(seconds: 25));
          }
          return const AdminResponse(202, {'operation': operation});
        }, now: () => now);
        await expectLater(
          client.get('/v1/admin/health'),
          throwsA(
            isA<AdminFailure>().having(
              (failure) => failure.message,
              'message',
              contains('still working'),
            ),
          ),
        );
        expect(polls, (adminActionDeadline.inSeconds / 25).ceil());
      },
    );

    test('an unknown operation is shown, never retried forever', () async {
      final client = AdminClient((method, path, {body}) async {
        if (path.startsWith('/v1/admin/operations/')) {
          return const AdminResponse(404, {
            'error': 'operation-unknown',
            'message': 'The server no longer has this action\'s result.',
          });
        }
        return const AdminResponse(202, {'operation': operation});
      });
      await expectLater(
        client.get('/v1/admin/health'),
        throwsA(
          isA<AdminFailure>().having(
            (failure) => failure.reason,
            'reason',
            'operation-unknown',
          ),
        ),
      );
    });
  });

  for (final (name, theme) in [
    ('light', ThemeData(brightness: Brightness.light, useMaterial3: true)),
    ('dark', ThemeData(brightness: Brightness.dark, useMaterial3: true)),
  ]) {
    testWidgets('every section renders in the $name theme', (tester) async {
      final api = FakeAdmin();
      await openAdmin(tester, api, theme: theme);
      for (final view in AdminView.values) {
        await tester.tap(find.text(view.label).first);
        await tester.pumpAndSettle();
        expect(find.text(view.label), findsWidgets, reason: view.label);
        expect(tester.takeException(), isNull);
      }
      expect(api.mutations(), isEmpty);
    });
  }

  testWidgets('users, devices and health show the gateway facts', (
    tester,
  ) async {
    final api = FakeAdmin();
    await openAdmin(tester, api);
    expect(find.text('Sam (sam)'), findsOneWidget);
    expect(find.textContaining('Admin'), findsWidgets);
    await showDevices(tester, 'sam');
    await showDevices(tester, 'alex');
    expect(find.text('the VM host · This device'), findsOneWidget);
    expect(find.textContaining('Last seen never'), findsOneWidget);
    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();
    expect(find.textContaining('console: stopped (3 restarts)'), findsOne);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('not configured'), findsNWidgets(2));
    expect(find.textContaining('(17 days)'), findsOneWidget);
  });

  testWidgets('devices are listed under their user; the Devices tab is gone '
      '(spec #34 P8)', (tester) async {
    final api = FakeAdmin();
    await openAdmin(tester, api);
    expect(find.text('Devices'), findsNothing);
    expect(
      AdminView.values.map((view) => view.label),
      isNot(contains('Devices')),
    );
    // Collapsed: no device rows yet, one devices request with the users.
    expect(find.byKey(const ValueKey('admin-device:$ownDevice')), findsNothing);
    expect(
      api.requests.where((r) => r.$2 == '/v1/admin/devices'),
      hasLength(1),
    );
    await showDevices(tester, 'sam');
    final sam = find.byKey(const ValueKey('admin-user-devices:sam'));
    expect(
      find.descendant(
        of: sam,
        matching: find.text('the VM host · This device'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sam, matching: find.text('Laptop')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sam,
        matching: find.textContaining('View only · Active · Last seen'),
      ),
      findsOneWidget,
    );
    // Spec #35: the computer name and short fingerprint its alert named.
    expect(
      find.descendant(
        of: sam,
        matching: find.textContaining("Computer 'laptop' (fp 6150cf05)"),
      ),
      findsOneWidget,
    );
    expect(find.text('Pixel'), findsNothing, reason: "Alex's device");
    await showDevices(tester, 'alex');
    final alex = find.byKey(const ValueKey('admin-user-devices:alex'));
    expect(find.descendant(of: alex, matching: find.text('Pixel')), findsOne);
    expect(
      find.descendant(of: alex, matching: find.text('Laptop')),
      findsNothing,
    );
    expect(
      find.descendant(of: alex, matching: find.textContaining('the VM host')),
      findsNothing,
    );
    // Revoke from the user's list: the server confirmation, then the call.
    await tester.tap(find.byKey(const ValueKey('admin-revoke:$jedLaptop')));
    await tester.pumpAndSettle();
    expect(find.text('Revoke the VM host (sam)?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-confirm-ok')));
    await tester.pumpAndSettle();
    expect(api.mutations().last.$2, '/v1/admin/devices/$jedLaptop/revoke');
    expect(api.mutations().last.$3, {'expect': 'd3', 'confirm': 'token-1'});
    expect(find.text('Revoked Laptop.'), findsOneWidget);
    // Still open after the refresh.
    expect(find.descendant(of: sam, matching: find.text('Laptop')), findsOne);
    // Hide again.
    await showDevices(tester, 'sam');
    expect(find.text('Laptop'), findsNothing);
  });

  testWidgets('a failing device list keeps the users and their actions; '
      'the open list says devices are unavailable', (tester) async {
    final api = FakeAdmin()..failDevices = true;
    await openAdmin(tester, api);
    expect(find.text('Sam (sam)'), findsOneWidget);
    expect(find.text('Alex (alex)'), findsOneWidget);
    expect(find.byTooltip('Actions for Alex'), findsOneWidget);
    await showDevices(tester, 'sam');
    expect(
      find.byKey(const ValueKey('admin-devices-error:sam')),
      findsOneWidget,
    );
    expect(find.textContaining('Devices unavailable'), findsOneWidget);
    expect(find.text('No paired devices.'), findsNothing);
    // Recovered on the next refresh.
    api.failDevices = false;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('the VM host · This device'), findsOneWidget);
    expect(find.textContaining('Devices unavailable'), findsNothing);
  });

  testWidgets('a half-created account is listed as Setup incomplete and '
      'Finish setup adds it again', (tester) async {
    final api = FakeAdmin()..pendingUser = true;
    await openAdmin(tester, api);
    expect(find.text('Zoe (zoe)'), findsOneWidget);
    expect(find.text('Setup incomplete — add again to finish'), findsOneWidget);
    expect(find.byTooltip('Actions for Zoe'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('admin-finish-user:zoe')));
    await tester.pumpAndSettle();
    expect(api.mutations().single.$2, '/v1/admin/users');
    expect(api.mutations().single.$3, {'uid': 'zoe', 'display_name': 'Zoe'});
    expect(find.text('Finished adding Zoe.'), findsOneWidget);
  });

  testWidgets('a destructive action shows the server text; Cancel sends '
      'nothing more', (tester) async {
    final api = FakeAdmin();
    await openAdmin(tester, api);
    await showDevices(tester, 'alex');
    await tester.tap(find.byKey(const ValueKey('admin-revoke:$amyDevice')));
    await tester.pumpAndSettle();
    expect(find.text('Revoke the VM host (sam)?'), findsOneWidget);
    expect(
      find.text(
        'This device stops syncing at once and must be paired again to return.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('admin-confirm-cancel')));
    await tester.pumpAndSettle();
    final posts = api.mutations().toList();
    expect(posts, hasLength(1));
    expect(posts.single.$3, {'expect': 'd2'});
  });

  testWidgets('Confirm resends with the token; own device needs the typed id', (
    tester,
  ) async {
    final api = FakeAdmin();
    await openAdmin(tester, api);
    await showDevices(tester, 'sam');
    await tester.tap(find.byKey(const ValueKey('admin-revoke:$ownDevice')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('admin-confirm-ok'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('admin-confirm-typed')),
      'jde',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('admin-confirm-typed')),
      'sam',
    );
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final posts = api.mutations().toList();
    expect(posts, hasLength(2));
    expect(posts.last.$3, {
      'expect': 'd1',
      'confirm': 'token-1',
      'typed': 'sam',
    });
    expect(find.text('Revoked the VM host.'), findsOneWidget);
  });

  testWidgets('an invitation shows the paired server and copies it separately '
      'from the one-time code', (tester) async {
    const server = 'https://gateway.example.com';
    const code = 'ABCD-1234-EFGH-5678-JKMN-9012-PQRS-3456';
    final api = FakeAdmin();
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await openAdmin(tester, api, view: AdminView.invitations, server: server);
    expect(find.textContaining('ABCD'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('admin-create-invitation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-invite-user')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alex (alex)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('admin-invite-label')),
      'Alex phone',
    );
    await tester.tap(find.byKey(const ValueKey('admin-invite-create')));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOne);
    expect(find.text('Server address'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('admin-invite-server')),
          )
          .data,
      server,
    );
    expect(
      find.textContaining('server address and pairing code'),
      findsOneWidget,
    );
    expect(
      find.textContaining('QR code supplies only the pairing code'),
      findsOne,
    );
    // The QR payload remains only the code for the app's scan (#97 review M3).
    expect(
      tester
          .widget<PairingCodeQr>(find.byKey(const ValueKey('admin-invite-qr')))
          .code,
      'ABCD1234EFGH5678JKMN9012PQRS3456',
    );
    await tester.tap(find.byKey(const ValueKey('admin-invite-copy-server')));
    await tester.pump();
    expect(clipboard, server);
    await tester.tap(find.byKey(const ValueKey('admin-invite-copy-code')));
    await tester.pump();
    expect(clipboard, code);
    expect(find.textContaining('it works once'), findsOneWidget);
    expect(api.mutations().single.$3, {
      'uid': 'alex',
      'grant': 'write',
      'label': 'Alex phone',
    });
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'phone dialog must fit');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ABCD'), findsNothing);
  });

  testWidgets(
    'CloudApp invitations use the active paired origin, not the build '
    'default',
    (tester) async {
      const activeOrigin = 'https://paired-family.anj-cloud.test';
      expect(activeOrigin, isNot(ClientController.householdOrigin));
      final api = FakeAdmin();
      final controller = layoutController()
        ..server = activeOrigin
        ..adminCall = api.call;
      addTearDown(controller.dispose);
      String? clipboard;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open-admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AdminView.invitations.label).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-create-invitation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-invite-user')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alex (alex)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-invite-create')));
      await tester.pumpAndSettle();

      expect(api.mutations().single.$2, '/v1/admin/invitations');
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('admin-invite-server')),
            )
            .data,
        activeOrigin,
      );
      expect(
        find.text(ClientController.householdOrigin),
        findsNothing,
        reason: 'the build default must not replace the active paired origin',
      );
      await tester.tap(find.byKey(const ValueKey('admin-invite-copy-server')));
      await tester.pump();
      expect(clipboard, activeOrigin);
      expect(
        tester
            .widget<PairingCodeQr>(
              find.byKey(const ValueKey('admin-invite-qr')),
            )
            .code,
        'ABCD1234EFGH5678JKMN9012PQRS3456',
        reason: 'the QR still carries only the pairing code',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('approve: the fingerprint field starts empty and refuses '
      'short input', (tester) async {
    final api = FakeAdmin();
    await openAdmin(tester, api, view: AdminView.invitations);
    await tester.tap(find.byKey(const ValueKey('admin-approve:$pendingId')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('admin-fingerprint'));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('admin-fingerprint-approve')));
    await tester.pump();
    expect(find.textContaining('Type all 64 characters'), findsOneWidget);
    await tester.enterText(field, 'ab' * 20);
    await tester.tap(find.byKey(const ValueKey('admin-fingerprint-approve')));
    await tester.pump();
    expect(api.mutations(), isEmpty);
    final grouped = [
      for (var i = 0; i < 64; i += 4) deviceFingerprint.substring(i, i + 4),
    ].join(' ').toUpperCase();
    await tester.enterText(field, grouped);
    await tester.tap(find.byKey(const ValueKey('admin-fingerprint-approve')));
    await tester.pumpAndSettle();
    expect(api.mutations().single.$3, {
      'fingerprint': deviceFingerprint,
      'expect': 'i1',
    });
    expect(find.text('Approved Alex tablet.'), findsOneWidget);
  });

  testWidgets('a wrong fingerprint shows the server refusal', (tester) async {
    final api = FakeAdmin();
    await openAdmin(tester, api, view: AdminView.invitations);
    await tester.tap(find.byKey(const ValueKey('admin-approve:$pendingId')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('admin-fingerprint')),
      'cd' * 32,
    );
    await tester.tap(find.byKey(const ValueKey('admin-fingerprint-approve')));
    await tester.pumpAndSettle();
    expect(find.textContaining('nothing was approved'), findsOneWidget);
  });

  testWidgets('upload limit: local bounds, then the server confirmation', (
    tester,
  ) async {
    final api = FakeAdmin();
    await openAdmin(tester, api, view: AdminView.settings);
    final field = find.byKey(const ValueKey('admin-upload-limit'));
    expect(tester.widget<TextField>(field).controller!.text, '64');
    await tester.enterText(field, '65');
    await tester.tap(find.byKey(const ValueKey('admin-upload-limit-save')));
    await tester.pump();
    expect(find.textContaining('large-transfer support'), findsOneWidget);
    expect(api.mutations(), isEmpty);
    await tester.enterText(field, '32');
    await tester.tap(find.byKey(const ValueKey('admin-upload-limit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-confirm-ok')));
    await tester.pumpAndSettle();
    expect(api.mutations().last.$3, {
      'upload_limit_mib': 32,
      'expect': 's1',
      'confirm': 'token-1',
    });
  });

  testWidgets('a stale target refreshes the list and says so', (tester) async {
    final api = FakeAdmin()..staleOn = '/v1/admin/users/alex/admin';
    await openAdmin(tester, api);
    int listed() => api.requests
        .where((r) => r.$1 == 'GET' && r.$2 == '/v1/admin/users')
        .length;
    final before = listed();
    await tester.tap(find.byTooltip('Actions for Alex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make admin'));
    await tester.pumpAndSettle();
    expect(find.textContaining('the list has been refreshed'), findsOneWidget);
    expect(listed(), before + 1);
  });

  testWidgets('a 403 not-admin closes Admin and reports it', (tester) async {
    final api = FakeAdmin();
    var notified = 0;
    await openAdmin(tester, api, onNotAdmin: () => notified++);
    api.notAdmin = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(notified, 1);
    expect(find.byType(AdminPage), findsNothing);
  });

  testWidgets('keyboard only: Tab to Revoke, Enter opens the confirmation, '
      'Escape cancels', (tester) async {
    final api = FakeAdmin();
    await openAdmin(tester, api);
    await showDevices(tester, 'alex');
    final target = find.byKey(const ValueKey('admin-revoke:$amyDevice'));
    var reached = false;
    for (var i = 0; i < 60 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      reached =
          focused != null &&
          find
              .descendant(of: target, matching: find.byType(Focus))
              .evaluate()
              .any((element) => element == focused);
    }
    expect(reached, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Revoke the VM host (sam)?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Revoke the VM host (sam)?'), findsNothing);
    expect(api.mutations(), hasLength(1), reason: 'no confirmed request');
  });

  testWidgets('screen-reader labels on actions and status', (tester) async {
    final handle = tester.ensureSemantics();
    final api = FakeAdmin();
    await openAdmin(tester, api, view: AdminView.health);
    expect(find.bySemanticsLabel(RegExp('Needs attention')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^OK')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Not configured')), findsNWidgets(2));
    expect(find.bySemanticsLabel(RegExp('Send test alert')), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    await tester.tap(find.text('Users'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Actions for Alex'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the app shows Admin only for an admin and hides it with a '
      'notice when the role goes', (tester) async {
    final controller = ClientController(
      Directory('/unused-admin-profile'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.pump();
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    controller.isAdmin = true;
    controller.notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('open-admin')), findsOneWidget);
    controller.adminRoleRemoved();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    expect(find.text('Your admin role was removed.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('fingerprints are normalized only when complete', () {
    expect(normalizeFingerprint(deviceFingerprint), deviceFingerprint);
    expect(
      normalizeFingerprint(
        deviceFingerprint.toUpperCase().replaceAllMapped(
          RegExp('.{4}'),
          (m) => '${m[0]}:',
        ),
      ),
      deviceFingerprint,
    );
    expect(normalizeFingerprint('ab' * 31), isNull);
    expect(normalizeFingerprint(''), isNull);
    expect(adminPathAllowed('/v1/admin/devices/$ownDevice/revoke'), isTrue);
    expect(adminPathAllowed('/v1/admin/audit?after=12&limit=100'), isTrue);
    expect(adminPathAllowed('/dav/Documents'), isFalse);
    expect(adminPathAllowed('/v1/admin/../shares'), isFalse);
  });
}
