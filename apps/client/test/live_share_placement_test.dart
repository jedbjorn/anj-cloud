// Opt-in two-account placement flow (spec #34 P6, decision #149) against a
// throwaway review stack; skipped unless ANJ_LIVE_SHARING_CONFIG is set.
// Config (mode 0600): {"runtime": checkout with deploy/.local/access-venv,
// "project": "anj-cloud-review-…", "port": 18846, "fixture": absent dir}.
// Runs in the test VM (no app window); operator tooling is invoked by this
// test actor, never by production lib/ code.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

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
  _Client(this.engine, this.dav, this.gate);
  final SyncEngine engine;
  final DavCloud dav;
  final PausableCloud gate;
  String get root => engine.tree.root.path;
  File file(String path) => File('$root/$path');
}

void main() {
  final configPath = Platform.environment['ANJ_LIVE_SHARING_CONFIG'];
  test(
    'a share from Documents arrives in the recipient\'s Documents; recipient delete leaves, owner delete removes, rename is for everyone',
    () async {
      final configFile = File(configPath!);
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
        stdout.writeln('Placement flow: $claim ${jsonEncode(facts)}');
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
        record('paired', {'profile': label, 'uid': uid});
        final gate = PausableCloud(dav);
        return _Client(SyncEngine(store, tree, gate), dav, gate);
      }

      final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final taxes = 'Documents/Taxes-$nonce';
      final notes = 'Documents/Notes-$nonce';
      final photos = 'Photos-$nonce';
      _Client? alice;
      _Client? bob;
      final shares = <String>[];
      try {
        alice = await pair('alice', 'anj-fixture-alice');
        bob = await pair('bob', 'anj-fixture-bob');
        await alice.engine.tick();
        await bob.engine.tick();
        for (final folder in [taxes, notes, photos]) {
          alice.engine.tree.ensureDirectory(folder);
          alice.file('$folder/a.txt').writeAsStringSync('alice $folder\n');
        }
        // Bob already has a Documents folder of the same name as one of them.
        bob.engine.tree.ensureDirectory(notes);
        bob.file('$notes/bob.txt').writeAsStringSync('bob own\n');
        await alice.engine.tick();
        await bob.engine.tick();

        for (final (folder, permission) in [
          (taxes, SharePermission.edit),
          (notes, SharePermission.edit),
          (photos, SharePermission.edit),
        ]) {
          final share = await alice.dav.createShare(
            folder,
            'anj-fixture-bob',
            permission,
          );
          expect(share.path, folder);
          shares.add(share.shareId);
        }
        record('alice shared two Documents folders and one other folder');

        await bob.engine.tick();
        final incoming = {
          for (final share in bob.engine.incoming.values)
            share.path: share.ownerName,
        };
        final notesMount = '$notes (Alice)';
        final photosMount = 'Shared/$photos';
        expect(incoming, {
          taxes: 'Alice',
          notesMount: 'Alice',
          photosMount: 'Alice',
        });
        expect(bob.file('$taxes/a.txt').readAsStringSync(), 'alice $taxes\n');
        expect(
          bob.file('$notesMount/a.txt').readAsStringSync(),
          'alice $notes\n',
        );
        expect(bob.file('$notes/bob.txt').readAsStringSync(), 'bob own\n');
        expect(
          bob.file('$photosMount/a.txt').readAsStringSync(),
          'alice $photos\n',
        );
        expect(bob.engine.isIncomingMountPath(taxes), isTrue);
        expect(bob.engine.isIncomingMountPath(notes), isFalse);
        record('bob received them in place', {
          'mounts': incoming.keys.map((v) => v.replaceAll(nonce, 'N')).toList(),
        });

        bob.file('$taxes/a.txt').writeAsStringSync('bob edit\n');
        await bob.engine.tick();
        await alice.engine.tick();
        expect(alice.file('$taxes/a.txt').readAsStringSync(), 'bob edit\n');
        record('can edit at the new place: bob edit reached alice');

        // Decision #155: a rename here, case-only included, renames the
        // folder for everyone, the owner's included.
        final taxesLower = 'Documents/taxes-$nonce';
        Directory('${bob.root}/$taxes').renameSync('${bob.root}/$taxesLower');
        await bob.engine.tick();
        await bob.engine.tick();
        await alice.engine.tick();
        expect(bob.engine.incoming[taxesLower]?.ownerName, 'Alice');
        expect(bob.engine.incoming.containsKey(taxes), isFalse);
        expect(bob.engine.isIncomingMountPath(taxesLower), isTrue);
        expect(
          (await alice.dav.outgoingShares()).map((v) => v.path),
          contains(taxesLower),
        );
        expect(
          alice.file('$taxesLower/a.txt').readAsStringSync(),
          'bob edit\n',
        );
        record('case-only rename renamed the folder for everyone');

        final pictures = 'Pictures-$nonce';
        Directory('${bob.root}/$photosMount')
            .renameSync('${bob.root}/Shared/$pictures');
        await bob.engine.tick();
        await bob.engine.tick();
        await alice.engine.tick();
        expect(bob.engine.incoming['Shared/$pictures']?.ownerName, 'Alice');
        expect(
          alice.file('$pictures/a.txt').readAsStringSync(),
          'alice $photos\n',
        );
        expect(Directory('${alice.root}/$photos').existsSync(), isFalse);
        record('rename in Shared/ renamed the owner\'s folder for everyone');

        // Review H1: a never-synchronized local folder of the same name is
        // set aside, never merged into the share.
        final recipes = 'Documents/Recipes-$nonce';
        alice.engine.tree.ensureDirectory(recipes);
        alice.file('$recipes/a.txt').writeAsStringSync('alice recipes\n');
        await alice.engine.tick();
        bob.gate.paused = true;
        bob.engine.tree.ensureDirectory(recipes);
        bob.file('$recipes/bob-private.txt').writeAsStringSync('bob private\n');
        await bob.engine.tick();
        shares.add(
          (await alice.dav.createShare(
            recipes,
            'anj-fixture-bob',
            SharePermission.edit,
          )).shareId,
        );
        bob.gate.paused = false;
        await bob.engine.tick();
        await bob.engine.tick();
        await alice.engine.tick();
        expect(
          bob.file('$recipes/a.txt').readAsStringSync(),
          'alice recipes\n',
        );
        expect(
          bob.file('$recipes (this device)/bob-private.txt').readAsStringSync(),
          'bob private\n',
        );
        expect(alice.file('$recipes/bob-private.txt').existsSync(), isFalse);
        record(
          'unsynced same-name folder set aside; nothing uploaded into the share',
        );

        // Decision #157: the recipient deleting the shared folder leaves the
        // share once the removal has settled (the real settle, about 12 s);
        // the owner's folder and files stay.
        Directory('${bob.root}/$taxesLower').deleteSync(recursive: true);
        await bob.engine.tick();
        await Future<void>.delayed(
          bob.engine.topDeleteSettle + const Duration(seconds: 1),
        );
        await bob.engine.tick();
        await bob.engine.tick();
        expect(bob.engine.incoming.containsKey(taxesLower), isFalse);
        expect(Directory('${bob.root}/$taxesLower').existsSync(), isFalse);
        await alice.engine.tick();
        expect(
          alice.file('$taxesLower/a.txt').readAsStringSync(),
          'bob edit\n',
        );
        final outgoing = await alice.dav.outgoingShares();
        expect(outgoing.map((share) => share.path).toSet(), {
          notes,
          pictures,
          recipes,
        });
        record('bob deleted the shared folder: he left; alice keeps it', {
          'alice_outgoing': outgoing.length,
        });

        // The owner deleting the shared folder deletes it for everyone (an
        // ordinary owner delete, into her trash).
        Directory('${alice.root}/$notes').deleteSync(recursive: true);
        await alice.engine.tick();
        await Future<void>.delayed(
          alice.engine.topDeleteSettle + const Duration(seconds: 1),
        );
        await alice.engine.tick();
        await alice.engine.tick();
        await bob.engine.tick();
        await bob.engine.tick();
        expect(Directory('${bob.root}/$notesMount').existsSync(), isFalse);
        expect(bob.engine.incoming.containsKey(notesMount), isFalse);
        expect(bob.file('$notes/bob.txt').readAsStringSync(), 'bob own\n');
        record('alice deleted her shared folder: gone for both');

        // An operator restores it from the owner's trash: the files and the
        // share come back, at bob's placed name.
        final restored = await Process.run('docker', [
          'exec',
          '-u',
          'www-data',
          '$project-nextcloud-1',
          'php',
          'occ',
          'trashbin:restore',
          'anj-fixture-alice',
        ]);
        expect(
          restored.exitCode,
          0,
          reason: '${restored.stdout}${restored.stderr}',
        );
        await alice.engine.tick();
        expect(alice.file('$notes/a.txt').readAsStringSync(), 'alice $notes\n');
        await bob.engine.tick();
        await bob.engine.tick();
        expect(bob.engine.incoming[notesMount]?.ownerName, 'Alice');
        expect(
          bob.file('$notesMount/a.txt').readAsStringSync(),
          'alice $notes\n',
        );
        record(
          'operator restored it from alice\'s trash: files and share are back, re-placed',
        );

        // A recipient with no active device: placed at its first incoming read.
        final later = 'Music/Later-$nonce';
        alice.engine.tree.ensureDirectory(later);
        alice.file('$later/a.txt').writeAsStringSync('alice later\n');
        await alice.engine.tick();
        bob.engine.close();
        bob.dav.close();
        await operator(['revoke', devices.removeLast()]);
        bob = null;
        shares.add(
          (await alice.dav.createShare(
            later,
            'anj-fixture-bob',
            SharePermission.edit,
          )).shareId,
        );
        bob = await pair('bob2', 'anj-fixture-bob');
        await bob.engine.tick();
        expect(bob.engine.incoming[later]?.ownerName, 'Alice');
        expect(bob.file('$later/a.txt').readAsStringSync(), 'alice later\n');
        expect(bob.engine.incoming.keys.where((v) => v.contains('Later-')), [
          later,
        ]);
        record('no recipient device at share time: placed at first read');
      } finally {
        for (final id in shares) {
          try {
            await alice?.dav.removeShare(id);
          } on Object {
            /* Already removed or left. */
          }
        }
        for (final client in [alice, bob]) {
          client?.engine.close();
          client?.dav.close();
        }
        for (final device in devices) {
          await operator(['revoke', device]);
        }
        record('cleanup: shares removed, devices revoked', {
          'devices': devices.length,
        });
      }
    },
    skip: configPath == null ? 'Set ANJ_LIVE_SHARING_CONFIG to run' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
