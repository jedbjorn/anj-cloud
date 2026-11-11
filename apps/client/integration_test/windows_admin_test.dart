import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/platform/windows/dpapi_secrets.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Admin and layout in the real Windows app window, at the
/// console session's display scale, against a review stack through the
/// reverse forward. Run by deploy/windows_admin_fixture.py through
/// tool/windows/w6_run.ps1 (unelevated). ANJ_W6_CONFIG names its JSON:
/// {"origin", "ca", "code_alice", "work" (absent), "signal", "scale"}.
///
/// Alice's device is paired and granted admin by the driver. Through the
/// Admin section she invites Bob; Bob's device pairs here with that code
/// alone and the server approves it (code-only pairing); she
/// changes his role both ways (Cancel first) and revokes his device; Bob,
/// not an admin, sees no Admin section and gets 403. No overflow (the
/// binding fails the test on one) and no control cut off at the sides, on
/// every screen visited.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Admin on Windows at the display scale', (tester) async {
    final config = jsonDecode(
      File(Platform.environment['ANJ_W6_CONFIG']!).readAsStringSync(),
    ) as Map<String, dynamic>;
    final origin = config['origin'] as String;
    if (!RegExp(r'^https://127\.0\.0\.1:\d+$').hasMatch(origin)) {
      throw StateError('Use the review stack through the reverse forward.');
    }
    final ca = config['ca'] as String;
    final scale = config['scale'] as int;
    final bobLabel =
        'Bob W6 $scale-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final work = Directory(config['work'] as String);
    if (work.existsSync()) {
      throw StateError('The work directory must be absent.');
    }
    work.createSync(recursive: true);
    final signal = Directory(config['signal'] as String)
      ..createSync(recursive: true);
    final events = <Map<String, Object?>>[];
    // Pairing codes never reach the evidence: the known ones, and anything
    // shaped like one (32 symbols of the code alphabet, grouped or not).
    final codes = <String>{config['code_alice'] as String};
    final codeShape = RegExp(
      r'(?:[0-9A-HJKMNP-TV-Z][\s-]?){31}[0-9A-HJKMNP-TV-Z]',
    );
    String redact(String text) {
      for (final code in codes) {
        if (code.isNotEmpty) text = text.replaceAll(code, '[code]');
      }
      return text.replaceAll(codeShape, '[code]');
    }

    void record(String claim, [Map<String, Object?> facts = const {}]) {
      events.add({'claim': claim, ...facts});
      File(p.join(signal.path, 'progress.json')).writeAsStringSync(
        redact(const JsonEncoder.withIndent('  ').convert(events)),
        flush: true,
      );
      // ignore: avoid_print
      print('W6 claim: $claim');
    }

    List<String> visibleTexts() => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        if (t.data != null && t.data!.trim().isNotEmpty) t.data!,
    ].take(80).toList();

    Future<void> until(Finder finder, {int seconds = 60}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (finder.evaluate().isNotEmpty) return;
      }
      throw StateError('Timed out waiting for $finder');
    }

    void clean(String what) {
      expect(tester.takeException(), isNull, reason: what);
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      for (final element
          in find
              .byWidgetPredicate(
                (w) =>
                    w is ButtonStyleButton ||
                    w is IconButton ||
                    w is PopupMenuButton ||
                    w is TextField,
              )
              .evaluate()) {
        final box = element.renderObject;
        if (box is! RenderBox || !box.hasSize || !box.attached) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        expect(
          rect.left >= -0.5 && rect.right <= width + 0.5,
          isTrue,
          reason: '$what: ${element.widget.runtimeType} at $rect of $width',
        );
      }
    }

    Future<void> screenshot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(signal.path, 'shot-$scale-$name.png'))
            .writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
      });
    }

    final secrets = DpapiSecrets(
      directory: p.join(work.path, 'secrets'),
      makePrivate: (path) => windowsRootFilesystem().privateDir(path),
    );
    Future<ClientController> prepared(String label) async {
      final controller = ClientController(
        Directory(p.join(work.path, 'profile-$label')),
        secrets: secrets,
      );
      await controller.initialize();
      final parent = Directory(p.join(work.path, 'files-$label'))..createSync();
      await controller.configureRoot(parent.path);
      await controller.stop();
      return controller;
    }

    // The code carries the CA pin; the server approves the device once the
    // console backend has provisioned it, and pair() waits for that. The
    // first-sync screen of a first pairing is confirmed with its defaults.
    Future<void> paired(ClientController controller, String code) async {
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      while (controller.pairingState != 'paired') {
        if (DateTime.now().isAfter(deadline)) throw StateError('No approval.');
        try {
          await controller.pair(origin, code, caPath: ca);
        } catch (error) {
          if (!'$error'.contains('(429)')) rethrow;
        }
        await controller.stop();
        final state = controller.pairingState;
        if (state == 'paired') break;
        // Still waiting for the server, or asked to slow down: once more
        // after a pause. Any other answer (denied, expired) ends the run.
        if (state != 'pending') {
          throw StateError('Pairing ended as "$state", not paired.');
        }
        await Future<void>.delayed(const Duration(seconds: 7));
      }
      if (controller.firstSyncPending) {
        final choice = await controller.firstSyncListing();
        await controller.confirmFirstSync(choice.paths, choice.paths.toSet());
        await controller.stop();
      }
    }

    addTearDown(() {
      if (events.isEmpty || events.last['claim'] != 'done') {
        try {
          record('stopped', {'texts': visibleTexts()});
        } catch (_) {}
      }
    });

    // ---- Alice: paired and made admin by the driver ----------------------
    late ClientController alice;
    await tester.runAsync(() async {
      alice = await prepared('alice');
      await paired(alice, config['code_alice'] as String);
      // The driver reads the device from this and grants Alice admin.
      File(p.join(signal.path, 'fingerprint-alice.json'))
          .writeAsStringSync(jsonEncode({'fingerprint': alice.fingerprint}));
      alice.dispose();
      alice = ClientController(
        Directory(p.join(work.path, 'profile-alice')),
        secrets: secrets,
      );
      await alice.initialize();
      await alice.start();
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!alice.isAdmin) {
        if (DateTime.now().isAfter(deadline)) throw StateError('Not admin.');
        await Future<void>.delayed(const Duration(seconds: 3));
        await alice.refreshAdmin();
      }
    });
    record('alice paired and admin');

    await tester.pumpWidget(CloudApp(controller: alice));
    await until(find.byKey(const ValueKey('open-admin')));
    final dpr = tester.view.devicePixelRatio;
    final logical = tester.view.physicalSize / dpr;
    expect((dpr * 100).round(), scale, reason: 'the console scale applies');
    clean('home');
    await screenshot('home');
    record('home shown', {
      'device_pixel_ratio': dpr,
      'logical_size': '${logical.width.round()}x${logical.height.round()}',
    });
    // The driver takes a whole-desktop screenshot meanwhile.
    await tester.pump(const Duration(seconds: 5));

    Future<void> openAdmin() async {
      await tester.tap(find.byKey(const ValueKey('open-admin')));
      await until(find.text('Alice (anj-fixture-alice)'));
    }

    Future<void> view(AdminView view) async {
      await tester.tap(find.text(view.label).first);
      await tester.pump(const Duration(seconds: 1));
    }

    await openAdmin();
    for (final v in AdminView.values) {
      await view(v);
      await tester.pump(const Duration(seconds: 2));
      clean('Admin ${v.label}');
      await screenshot('admin-${v.name}');
    }
    record('every Admin section fits');

    // ---- Bob's device: invited in the UI, paired by the code alone -------
    await view(AdminView.invitations);
    await until(find.byKey(const ValueKey('admin-create-invitation')));
    await tester.tap(find.byKey(const ValueKey('admin-create-invitation')));
    await until(find.byKey(const ValueKey('admin-invite-user')));
    await tester.tap(find.byKey(const ValueKey('admin-invite-user')));
    await until(find.text('Bob (anj-fixture-bob)'));
    await tester.tap(find.text('Bob (anj-fixture-bob)').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.byKey(const ValueKey('admin-invite-label')),
      bobLabel,
    );
    clean('invitation dialog');
    await tester.tap(find.byKey(const ValueKey('admin-invite-create')));
    // This run's row only: an earlier, interrupted run may have left a
    // pending device of Bob's on the stack.
    await until(find.byKey(const ValueKey('admin-invite-code')));
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('admin-invite-code')))
        .data!;
    codes.add(code);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));

    late ClientController bob;
    await tester.runAsync(() async {
      bob = await prepared('bob');
      await paired(bob, code);
    });
    expect(bob.pairingState, 'paired');
    // Nothing of this run waits for an approval any more: the list has
    // loaded (its heading shows) and has no pending row at all for Bob.
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.textContaining(bobLabel), findsNothing);
    expect(
      find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> &&
            key.value.startsWith('admin-approve:');
      }),
      findsNothing,
    );
    clean('invitations after pairing');
    await screenshot('paired');
    record('Bob invited in the UI and his device paired by the code alone');

    // ---- Bob is not an admin: no section, and 403 ------------------------
    await tester.runAsync(() async {
      bob.dispose();
      bob = ClientController(
        Directory(p.join(work.path, 'profile-bob')),
        secrets: secrets,
      );
      await bob.initialize();
      await bob.start();
      await Future<void>.delayed(const Duration(seconds: 3));
      await bob.refreshAdmin();
    });
    expect(bob.isAdmin, isFalse);
    final refused = await tester.runAsync(
      () => bob.admin('GET', '/v1/admin/users'),
    );
    expect(refused!.status, 403);
    expect(refused.map['error'], 'not-admin');
    record('a non-admin gets 403', {'status': refused.status});
    // Bob's own window: no Admin entry.
    Navigator.of(tester.element(find.byType(AdminPage))).pop();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CloudApp(controller: bob));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    clean('non-admin home');
    await screenshot('non-admin-home');
    record('a non-admin sees no Admin section');

    // ---- role change, Cancel first, then both ways -----------------------
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CloudApp(controller: alice));
    await until(find.byKey(const ValueKey('open-admin')));
    await openAdmin();
    final confirmations = <Map<String, String>>[];
    Future<void> confirm({required bool ok, required String what}) async {
      await until(find.byKey(const ValueKey('admin-confirm-ok')));
      final dialog = find.byType(AlertDialog);
      final texts = [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: dialog, matching: find.byType(Text)),
        ))
          if (t.data != null) t.data!,
      ];
      confirmations.add({
        'action': what,
        'title': texts.first,
        'effect': texts[1],
      });
      clean('$what confirmation');
      // Cancel and OK of one action each keep their own shot.
      await screenshot('confirm-$what-${ok ? 'ok' : 'cancel'}');
      await tester.tap(
        find.byKey(ValueKey(ok ? 'admin-confirm-ok' : 'admin-confirm-cancel')),
      );
      await tester.pump(const Duration(seconds: 2));
    }

    Future<void> role(String choice, {required bool ok}) async {
      await tester.tap(find.byTooltip('Actions for Bob'));
      await until(find.text(choice));
      await tester.tap(find.text(choice).last);
      await confirm(ok: ok, what: choice.toLowerCase().replaceAll(' ', '-'));
    }

    await role('Make admin', ok: false);
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isFalse, reason: 'Cancel sent nothing');
    await role('Make admin', ok: true);
    await until(find.text('anj-fixture-bob is now an admin.'));
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await role('Remove admin', ok: true);
    await until(find.text('anj-fixture-bob is no longer an admin.'));
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isFalse);
    record(
      'role change both ways after the server confirmation; Cancel sent '
      'nothing',
    );

    // ---- revoke Bob's device ---------------------------------------------
    // Devices are listed under their user.
    await view(AdminView.users);
    await until(
      find.byKey(const ValueKey('admin-user-expand:anj-fixture-bob')),
    );
    await tester.tap(
      find.byKey(const ValueKey('admin-user-expand:anj-fixture-bob')),
    );
    await until(find.text(bobLabel));
    clean('user devices');
    await screenshot('user-devices');
    final card = find.ancestor(
      of: find.text(bobLabel),
      matching: find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith('admin-device:');
      }),
    );
    await tester.tap(
      find.descendant(of: card.first, matching: find.text('Revoke')),
    );
    await confirm(ok: true, what: 'revoke');
    await until(find.text('Revoked $bobLabel.'));
    final after = await tester.runAsync(() async {
      try {
        return (await bob.admin('GET', '/v1/account')).status;
      } catch (error) {
        return error.runtimeType.toString();
      }
    });
    expect(after, isNot(200));
    record('Bob\'s device revoked after the confirmation', {
      'bob_after': after,
      'confirmations': confirmations,
    });

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await bob.stop();
      await alice.stop();
    });
    bob.dispose();
    alice.dispose();
    record('done');
  });
}
