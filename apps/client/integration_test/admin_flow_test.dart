import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Spec #27 Admin section against a throwaway review stack with the console
/// backend running: the real client, worker, mTLS gateway and backend.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Admin section on a live review stack', (tester) async {
    final configFile = File(Platform.environment['ANJ_LIVE_ADMIN_CONFIG']!);
    if ((configFile.statSync().mode & 0077) != 0) {
      throw StateError('Live fixture configuration must be private.');
    }
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final runtime = config['runtime'] as String;
    final project = config['project'] as String;
    final port = config['port'] as int;
    final evidence = Directory(config['evidence'] as String)
      ..createSync(recursive: true);
    if (!RegExp(r'^anj-cloud-review-[a-z0-9-]+$').hasMatch(project)) {
      throw StateError('Use a throwaway review project, never the dev stack.');
    }
    final origin = Uri.parse('https://127.0.0.1:$port');
    final ca = File('$runtime/deploy/.local/$project/operator/issuer.crt');
    final fixture = Directory(config['fixture'] as String);
    if (fixture.existsSync()) throw StateError('Fixture path must be absent.');
    fixture.createSync(recursive: true);
    final events = <Map<String, Object?>>[];
    void record(String claim, [Map<String, Object?> facts = const {}]) {
      events.add({'claim': claim, ...facts});
      File('${evidence.path}/gui-progress.json')
          .writeAsStringSync(jsonEncode(events), flush: true);
      stdout.writeln('Admin GUI: $claim');
    }

    Future<Object?> python(String module, List<String> arguments) async {
      final result = await Process.run(
        '$runtime/deploy/.local/access-venv/bin/python',
        ['-m', module, '--project', project, '--port', '$port', ...arguments],
        workingDirectory: runtime,
      );
      if (result.exitCode != 0) {
        throw StateError('$module ${arguments.first} failed: ${result.stderr}');
      }
      return jsonDecode(result.stdout as String);
    }

    Future<void> until(Finder finder, {int seconds = 60}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (finder.evaluate().isNotEmpty) return;
      }
      throw StateError('Timed out waiting for $finder');
    }

    Future<void> screenshot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find
            .ancestor(
              of: find.byType(AdminPage),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${evidence.path}/gui-$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
      });
    }

    // Pair Alice's device with the operator, then make her the admin through
    // the recovery CLI (the same gateway rules and audit as the app).
    final secrets = _MemorySecrets();
    final profile = Directory('${fixture.path}/profile');
    var controller = ClientController(profile, secrets: secrets);
    await tester.runAsync(() async {
      await controller.initialize();
      final parent = Directory('${fixture.path}/files')..createSync();
      await controller.configureRoot(parent.path);
      await controller.stop();
      final invitation = await python('deploy.access_operator', [
        'invite',
        'anj-fixture-alice',
        '--rights',
        'write',
      ]) as Map;
      // Spec #35: a pinned code. Without a console backend the gateway
      // cannot approve it by itself; the operator approves it below.
      controller.pairingWait = Duration.zero;
      await controller.pair(
        origin.toString(),
        invitation['code'] as String,
        caPath: ca.path,
      );
      await controller.stop();
      await python('deploy.access_operator', [
        'approve',
        invitation['id'] as String,
        '--fingerprint',
        controller.fingerprint!,
      ]);
      await controller.pair(
        origin.toString(),
        invitation['code'] as String,
        caPath: ca.path,
      );
      // A first pairing on the desktop shows the first-sync screen
      // (decision #163); confirm it, keeping everything (the desktop default).
      expect(controller.firstSyncPending, isTrue);
      final choice = await controller.firstSyncListing();
      await controller.confirmFirstSync(choice.paths, choice.paths.toSet());
      await controller.stop();
      controller.dispose();
      await python('deploy.vm.anj_cloud_admin', [
        '--backend-socket',
        '$runtime/deploy/.local/$project/console/backend.sock',
        '--yes',
        'admin-grant',
        'anj-fixture-alice',
      ]);
    });
    record('paired and granted admin');

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    controller = ClientController(profile, secrets: secrets);
    await tester.runAsync(() async {
      await controller.initialize();
      await controller.start();
    });
    await tester.pumpWidget(CloudApp(controller: controller));
    await until(find.byKey(const ValueKey('open-admin')));
    record('Admin entry visible for an admin account');

    await tester.tap(find.byKey(const ValueKey('open-admin')));
    await until(find.text('Alice (anj-fixture-alice)'));
    expect(find.textContaining('Admin'), findsWidgets);
    await screenshot('users');
    record('users listed');

    await tester.tap(find.text('Invitations'));
    await until(find.byKey(const ValueKey('admin-create-invitation')));
    await tester.tap(find.byKey(const ValueKey('admin-create-invitation')));
    await until(find.byKey(const ValueKey('admin-invite-user')));
    await tester.tap(find.byKey(const ValueKey('admin-invite-user')));
    await until(find.text('Bob (anj-fixture-bob)'));
    await tester.tap(find.text('Bob (anj-fixture-bob)').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.byKey(const ValueKey('admin-invite-label')),
      'Bob test phone',
    );
    await tester.tap(find.byKey(const ValueKey('admin-invite-create')));
    await until(find.byKey(const ValueKey('admin-invite-code')));
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('admin-invite-code')))
        .data!;
    expect(code, matches(RegExp(r'^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')));
    record('invitation code shown once');
    await tester.tap(find.text('Done'));
    await until(find.text('Bob test phone for anj-fixture-bob'));
    expect(find.textContaining(code), findsNothing);
    await screenshot('invitations');

    // Cancel in the server's confirmation sends nothing; the code stays.
    final cancel = find.descendant(
      of: find.ancestor(
        of: find.text('Bob test phone for anj-fixture-bob'),
        matching: find.byType(ListTile),
      ),
      matching: find.text('Cancel code'),
    );
    await tester.tap(cancel);
    await until(find.text('Cancel Bob test phone for anj-fixture-bob?'));
    await tester.tap(find.byKey(const ValueKey('admin-confirm-cancel')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Bob test phone for anj-fixture-bob'), findsOneWidget);
    await tester.tap(cancel);
    await until(find.text('Cancel Bob test phone for anj-fixture-bob?'));
    await tester.tap(find.byKey(const ValueKey('admin-confirm-ok')));
    await until(find.text('Code cancelled.'));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Bob test phone for anj-fixture-bob'), findsNothing);
    record('code cancelled after the server confirmation; Cancel sent none');

    // Devices are listed under their user (spec #34 P8).
    await tester.tap(find.text('Users'));
    await until(
      find.byKey(const ValueKey('admin-user-expand:anj-fixture-alice')),
    );
    await tester.tap(
      find.byKey(const ValueKey('admin-user-expand:anj-fixture-alice')),
    );
    await until(find.textContaining('This device'));
    await screenshot('devices');
    await tester.tap(find.text('Settings'));
    await until(find.byKey(const ValueKey('admin-upload-limit')));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('admin-upload-limit')))
          .controller!
          .text,
      '64',
    );
    await tester.tap(find.text('Health'));
    await until(find.text('Ready'));
    await screenshot('health');
    await tester.tap(find.text('Activity'));
    await until(find.textContaining('invitation-deny · ok'));
    await screenshot('activity');
    record('devices, settings, health and activity loaded');

    final audit = await tester.runAsync(
      () => python('deploy.vm.anj_cloud_admin', ['audit']),
    ) as Map;
    final text = jsonEncode(audit);
    expect(text.contains(code.replaceAll('-', '')), isFalse);
    expect(text.contains(controller.fingerprint!), isFalse);
    record('audit has no code or fingerprint');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => controller.stop());
    controller.dispose();
    fixture.deleteSync(recursive: true);
    tester.view.reset();
  });
}
