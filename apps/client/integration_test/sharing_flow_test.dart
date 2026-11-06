// Opt-in two-account sharing flow (spec #26) against a throwaway review stack.
// Operator tooling is invoked by this test actor, never by production lib/ code.
// Config (ANJ_LIVE_SHARING_CONFIG, mode 0600): {"runtime": repo root,
// "project": "anj-cloud-review-…", "port": 18926, "fixture": absent dir}.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Fixture keys stay in memory: nothing is written to the desktop keyring.
class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Client {
  _Client(this.uid, this.engine, this.dav, this.gate);
  final String uid;
  final SyncEngine engine;
  final DavCloud dav;

  /// The worker's pause gate, used here as the "offline" switch.
  final PausableCloud gate;
  String get root => engine.tree.root.path;
  File file(String path) => File('$root/$path');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'two household accounts share, downgrade, unshare and survive a disabled owner',
    (tester) async {
      final configFile = File(Platform.environment['ANJ_LIVE_SHARING_CONFIG']!);
      if ((configFile.statSync().mode & 0077) != 0) {
        throw StateError('Live fixture configuration must be private.');
      }
      final config =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final runtime = config['runtime'] as String;
      final project = config['project'] as String;
      final port = config['port'] as int;
      if (!RegExp(r'^anj-cloud-review-[a-z0-9-]+$').hasMatch(project)) {
        throw StateError(
          'Use a throwaway review project, never the dev stack.',
        );
      }
      final origin = Uri.parse('https://127.0.0.1:$port');
      final ca = File('$runtime/deploy/.local/$project/operator/issuer.crt');
      final fixture = Directory(config['fixture'] as String);
      if (fixture.existsSync()) {
        throw StateError('Live fixture path must be absent.');
      }
      fixture.createSync(recursive: true);
      NativeRootFs().privateDir(fixture.path);
      final secrets = _MemorySecrets();
      final devices = <String>[];
      final events = <Map<String, Object?>>[];
      void record(String claim, [Map<String, Object?> facts = const {}]) {
        events.add({'claim': claim, ...facts});
        File('${fixture.path}/progress.json')
            .writeAsStringSync(jsonEncode(events), flush: true);
        stdout.writeln(
          'Sharing flow: $claim ${facts.isEmpty ? '' : jsonEncode(facts)}',
        );
      }

      Future<Object?> operator(List<String> arguments) async {
        final result = await Process.run(
          '$runtime/deploy/.local/access-venv/bin/python',
          [
            '-m',
            'deploy.access_operator',
            '--project',
            project,
            '--port',
            '$port',
            ...arguments,
          ],
          workingDirectory: runtime,
        );
        if (result.exitCode != 0) {
          throw StateError(
            'Operator ${arguments.first} failed (exit ${result.exitCode}): ${result.stderr}',
          );
        }
        return jsonDecode(result.stdout as String);
      }

      Future<_Client> pair(String label, String uid) async {
        final profile = Directory('${fixture.path}/profile-$label');
        final controller = ClientController(profile, secrets: secrets);
        await controller.initialize();
        final parent = Directory('${fixture.path}/files-$label')..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        final invitation =
            await operator(['invite', uid, '--rights', 'write']) as Map;
        final code = invitation['code'] as String;
        controller.pairingWait = Duration.zero; // spec #35
        await controller.pair(origin.toString(), code, caPath: ca.path);
        await controller.stop();
        final approval = await operator([
          'approve',
          invitation['id'] as String,
          '--fingerprint',
          controller.fingerprint!,
        ]) as Map;
        devices.add(approval['device_id'] as String);
        await controller.pair(origin.toString(), code, caPath: ca.path);
        await controller.stop();
        expect(controller.pairingState, 'paired');
        controller.dispose();
        final store = Manifest(profile);
        final identity = DeviceIdentity(store, secrets);
        final tree = RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          NativeRootFs(),
        );
        final dav = DavCloud(
          origin,
          await identity.context(ca),
          folderDeletionQualified: true,
        );
        final gate = PausableCloud(dav);
        record('paired', {'profile': label, 'uid': uid});
        return _Client(uid, SyncEngine(store, tree, gate), dav, gate);
      }

      String remoteText(_Client client, String path) =>
          client.file(path).readAsStringSync();

      final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final folder = 'Share26-$nonce';
      final folder2 = 'Share26-owner-$nonce';
      _Client? alice;
      _Client? bob;
      String? shareId;
      String? share2Id;
      try {
        alice = await pair('alice', 'anj-fixture-alice');
        bob = await pair('bob', 'anj-fixture-bob');
        for (final name in ['a.txt', 'b.txt', 'c.txt']) {
          alice.engine.tree.ensureDirectory(folder);
          alice.file('$folder/$name').writeAsStringSync('alice $name\n');
        }
        await alice.engine.tick();

        // Household list and Can edit share.
        final users = await alice.dav.householdUsers();
        expect(users.map((u) => (u.id, u.displayName)), [
          ('anj-fixture-bob', 'Bob'),
        ]);
        final share = await alice.dav.createShare(
          folder,
          'anj-fixture-bob',
          SharePermission.edit,
        );
        shareId = share.shareId;
        expect(
          (share.recipientName, share.permission),
          ('Bob', SharePermission.edit),
        );
        await alice.engine.tick();
        expect(alice.engine.manifest.entries[folder]!.sharedOut, isTrue);
        expect(alice.engine.outgoingNames[folder], ['Bob']);
        record('alice shared Can edit', {'share_id': shareId});

        await bob.engine.tick();
        final incoming = bob.engine.incoming.values.single;
        final mount = incoming.path;
        expect(
          (
            mount.startsWith('Shared/'),
            incoming.ownerName,
            incoming.permission,
          ),
          (true, 'Alice', SharePermission.edit),
        );
        expect(remoteText(bob, '$mount/a.txt'), 'alice a.txt\n');
        record('bob received under Shared', {
          'mount_is_under_shared': true,
          'owner': incoming.ownerName,
        });

        bob.file('$mount/a.txt').writeAsStringSync('bob edit 1\n');
        await bob.engine.tick();
        await alice.engine.tick();
        expect(remoteText(alice, '$folder/a.txt'), 'bob edit 1\n');
        record('bob edit reached alice');

        // View only.
        expect(
          (await alice.dav.updateShare(
            shareId,
            SharePermission.view,
          )).permission,
          SharePermission.view,
        );
        await bob.engine.tick();
        expect(bob.engine.viewOnly('$mount/a.txt'), isTrue);
        bob
            .file('$mount/a.txt')
            .writeAsStringSync('bob edit while view only\n');
        await bob.engine.tick();
        await alice.engine.tick();
        expect(
          bob.engine.manifest.entries['$mount/a.txt']!.conflict,
          viewOnlyConflict,
        );
        expect(remoteText(bob, '$mount/a.txt'), 'bob edit while view only\n');
        expect(remoteText(alice, '$folder/a.txt'), 'bob edit 1\n');
        record('view only: edit kept as in-place conflict, not uploaded');

        bob.file('$mount/b.txt').deleteSync();
        await bob.engine.tick();
        await alice.engine.tick();
        expect(remoteText(bob, '$mount/b.txt'), 'alice b.txt\n');
        expect(
          bob.engine.manifest.entries['$mount/b.txt']!.status,
          viewOnlyRestored,
        );
        expect(remoteText(alice, '$folder/b.txt'), 'alice b.txt\n');
        record('view only: deleted file restored from the cloud');

        // Back to Can edit: the held conflict stays a conflict (decision #80 (5)).
        await alice.dav.updateShare(shareId, SharePermission.edit);
        await bob.engine.tick();
        await alice.engine.tick();
        expect(
          bob.engine.manifest.entries['$mount/a.txt']!.conflict,
          viewOnlyConflict,
        );
        expect(remoteText(alice, '$folder/a.txt'), 'bob edit 1\n');
        record('can edit again: held conflict not uploaded');

        // Unshare with an unsynced local edit.
        bob.gate.paused = true;
        bob.file('$mount/c.txt').writeAsStringSync('bob unsynced edit\n');
        await bob.engine.tick();
        await alice.dav.removeShare(shareId);
        shareId = null;
        bob.gate.paused = false;
        await bob.engine.tick();
        await bob.engine.tick();
        await alice.engine.tick();
        expect(bob.engine.incoming, isEmpty);
        expect(remoteText(bob, '$mount/c.txt'), 'bob unsynced edit\n');
        final conflicts = [
          for (final entry in bob.engine.manifest.entries.values)
            if ((entry.path == mount || entry.path.startsWith('$mount/')) &&
                entry.conflict != null)
              entry.conflict,
        ];
        expect(conflicts, isNotEmpty);
        expect(remoteText(alice, '$folder/c.txt'), 'alice c.txt\n');
        record(
          'unshare: folder left sync, unsynced bytes kept in place as a conflict',
          {'conflicts': conflicts},
        );

        // Disabled owner (decision #79 (b), #80 (2)).
        alice.engine.tree.ensureDirectory(folder2);
        alice.file('$folder2/d.txt').writeAsStringSync('alice d.txt\n');
        await alice.engine.tick();
        share2Id = (await alice.dav.createShare(
          folder2,
          'anj-fixture-bob',
          SharePermission.edit,
        )).shareId;
        await bob.engine.tick();
        final mount2 = bob.engine.incoming.values.single.path;
        expect(remoteText(bob, '$mount2/d.txt'), 'alice d.txt\n');
        // The stuck-state case: the recipient is disabled first. Disabling
        // the owner must still succeed (mounts come from the owner's list).
        await operator(['account-set', 'anj-fixture-bob', '--disable']);
        final disabled = await operator([
          'account-set',
          'anj-fixture-alice',
          '--disable',
        ]) as Map;
        expect(disabled['mounts_recorded'], isTrue);
        record('owner disabled while the recipient was disabled', {
          'mounts_recorded': disabled['mounts_recorded'],
        });
        // Bob is refused while disabled: his pass infers nothing.
        await bob.engine.tick();
        expect(remoteText(bob, '$mount2/d.txt'), 'alice d.txt\n');
        await operator(['account-set', 'anj-fixture-bob', '--enable']);
        record('recipient re-enabled before the owner');
        await expectLater(
          alice.dav.outgoingShares(),
          throwsA(isA<CloudFailure>().having((e) => e.status, 'status', 403)),
        );
        final deletesBefore = bob.engine.manifest.operations.values
            .where((o) => o.kind == 'delete')
            .length;
        await bob.engine.tick();
        await bob.engine.tick();
        expect(bob.engine.incoming[mount2]!.ownerUnavailable, isTrue);
        expect(
          bob.engine.manifest.entries[mount2]!.status,
          ownerUnavailableStatus,
        );
        expect(remoteText(bob, '$mount2/d.txt'), 'alice d.txt\n');
        expect(
          bob.engine.manifest.operations.values
              .where((o) => o.kind == 'delete')
              .length,
          deletesBefore,
        );
        expect(
          bob.engine.manifest.entries['$mount2/d.txt']!.status,
          isNot(startsWith('deleted')),
        );
        record(
          'disabled owner: re-enabled recipient sees owner unavailable, not an unshare; no deletion, bytes intact; owner device 403',
        );
        await operator(['account-set', 'anj-fixture-alice', '--enable']);
        await bob.engine.tick();
        await alice.engine.tick();
        expect(bob.engine.incoming[mount2]!.ownerUnavailable, isFalse);
        expect(bob.engine.manifest.entries[mount2]!.status, 'current local');
        expect((await alice.dav.outgoingShares()).length, 1);
        record('re-enabled: both devices sync normally without re-pairing');
      } finally {
        // Cleanup: shares, fixture folders (Alice's cloud), devices, local files.
        for (final id in [?shareId, ?share2Id]) {
          try {
            await alice?.dav.removeShare(id);
          } on Object {
            /* Already removed. */
          }
        }
        try {
          await operator(['account-set', 'anj-fixture-bob', '--enable']);
          await operator(['account-set', 'anj-fixture-alice', '--enable']);
        } on Object {
          /* Reported by the assertions above. */
        }
        for (final client in [alice, bob]) {
          client?.engine.close();
          client?.dav.close();
        }
        for (final device in devices) {
          await operator(['revoke', device]);
        }
        record('cleanup: devices revoked', {'devices': devices.length});
      }
    },
  );
}
