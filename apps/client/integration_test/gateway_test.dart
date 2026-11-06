// Opt-in real gateway fixture. Run only after explicit stack ownership handoff.
// Operator tooling is invoked by this test actor, never by production lib/ code.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/linux/keyring_secrets.dart';
import 'package:anj_cloud/ui/app.dart';

import '../tool/eviction_fixture.dart' show ownedAllocated;

class _SwitchableCloud implements CloudApi {
  _SwitchableCloud(this.delegate);
  final DavCloud delegate;
  bool online = true;
  void check() {
    if (!online) {
      throw const CloudFailure('Client fixture offline; no request sent.');
    }
  }

  @override
  Future<List<RemoteItem>> snapshot() {
    check();
    return delegate.snapshot();
  }

  @override
  Future<void> download(String path, File file, {required String etag}) {
    check();
    return delegate.download(path, file, etag: etag);
  }

  @override
  Future<String> upload(String path, File file, {required String? etag}) {
    check();
    return delegate.upload(path, file, etag: etag);
  }

  @override
  bool get lastUploadReadBack => delegate.lastUploadReadBack;

  @override
  int? get uploadLimit => delegate.uploadLimit;

  @override
  Future<void> mkdir(String path) {
    check();
    return delegate.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    check();
    return delegate.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) {
    check();
    return delegate.move(from, to, etag: etag);
  }

  @override
  bool get safeFolderDeletion => delegate.safeFolderDeletion;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) {
    check();
    return delegate.deleteFolder(path, versions: versions);
  }

  @override
  Future<AddedPage?> addedSince(int after) => delegate.addedSince(after);

  @override
  void close() => delegate.close();
}

class _Client {
  _Client(this.profile, this.engine, this.cloud, this.identity);
  final Directory profile;
  final SyncEngine engine;
  final _SwitchableCloud cloud;
  final DeviceIdentity identity;
  bool closed = false;
  void close() {
    if (!closed) {
      engine.close();
      closed = true;
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['ANJ_LIVE_GATEWAY_CONFIG'];
  testWidgets(
    'two isolated real Linux clients pair and reconcile through the confined gateway',
    (tester) async {
      final configFile = File(configPath!);
      final permissions = configFile.statSync().mode;
      if ((permissions & 0077) != 0) {
        throw StateError('Live fixture configuration must be private.');
      }
      final config =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final runtime = Directory(config['runtime'] as String)
          .resolveSymbolicLinksSync();
      final origin = Uri.parse(config['origin'] as String);
      if (origin.toString() != 'https://127.0.0.1:8834') {
        throw StateError('Use the canonical handed-off Dev origin.');
      }
      final ca = File(
        '$runtime/deploy/.local/anj-cloud-dev/operator/issuer.crt',
      );
      final fixture = Directory(config['fixture'] as String);
      if (fixture.existsSync()) {
        throw StateError('Live fixture path must be absent.');
      }
      fixture.createSync(recursive: true);
      NativeRootFs().privateDir(fixture.path);
      final uid = config['uid'] as String? ?? 'anj-fixture-alice';
      if (!RegExp(r'^anj-fixture-[a-z0-9-]+$').hasMatch(uid)) {
        throw StateError('Use a synthetic fixture account.');
      }
      final secrets = KeyringSecrets();
      final devices = <String>{};
      final revoked = <String>{};
      final invitations = <String>{};
      final approvedInvitations = <String>{};
      final profiles = <Directory>[];
      final clients = <_Client>[];
      final events = <Map<String, Object?>>[];
      final nonce = 'client-${uniqueId().substring(0, 12)}';
      final prefix = 'Documents/$nonce';
      void record(Map<String, Object?> event) {
        events.add(event);
        File('${fixture.path}/progress.json').writeAsStringSync(
          jsonEncode({
            'origin': origin.origin,
            'uid': uid,
            'prefix': prefix,
            'events': events,
          }),
          flush: true,
        );
        stdout.writeln('Live client phase: ${event['claim']}');
      }

      Future<Map<String, dynamic>> operator(List<String> arguments) async {
        final result = await Process.run(
          '$runtime/deploy/.local/access-venv/bin/python',
          [
            '-m',
            'deploy.access_operator',
            '--project',
            'anj-cloud-dev',
            '--port',
            '8834',
            ...arguments,
          ],
          workingDirectory: runtime,
        );
        if (result.exitCode != 0) {
          throw StateError(
            'Scoped operator ${arguments.first} failed (exit ${result.exitCode}); secret output withheld.',
          );
        }
        try {
          return jsonDecode(result.stdout as String) as Map<String, dynamic>;
        } catch (_) {
          throw StateError(
            'Scoped operator output was not structured JSON; secret output withheld.',
          );
        }
      }

      Future<_Client> reopen(Directory profile, {bool folders = false}) async {
        final store = Manifest(profile);
        final identity = DeviceIdentity(store, secrets);
        final tree = RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          NativeRootFs(),
        );
        final cloud = _SwitchableCloud(
          DavCloud(
            origin,
            await identity.context(ca),
            folderDeletionQualified: folders,
          ),
        );
        final client = _Client(
          profile,
          SyncEngine(store, tree, cloud),
          cloud,
          identity,
        );
        clients.add(client);
        return client;
      }

      Future<_Client> pair(String label, Retention retention) async {
        final profile = Directory('${fixture.path}/profile-$label');
        profiles.add(profile);
        final controller = ClientController(profile, secrets: secrets);
        await controller.initialize();
        final parent = Directory('${fixture.path}/files-$label')..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        final invitation = await operator(['invite', uid, '--rights', 'write']);
        invitations.add(invitation['id'] as String);
        final code = invitation['code'] as String;
        // Spec #35: a pinned code; without a console backend the gateway
        // leaves it pending and the operator approves it below.
        controller.pairingWait = Duration.zero;
        await controller.pair(origin.toString(), code, caPath: ca.path);
        await controller.stop();
        expect(controller.pairingState, isIn(['pending', 'paired']));
        final fingerprint = controller.fingerprint!;
        final approval = await operator([
          'approve',
          invitation['id'] as String,
          '--fingerprint',
          fingerprint,
        ]);
        devices.add(approval['device_id'] as String);
        approvedInvitations.add(invitation['id'] as String);
        final grouped = List.generate(
          (code.length + 3) ~/ 4,
          (i) => code
              .substring(i * 4, (i * 4 + 4).clamp(0, code.length))
              .toLowerCase(),
        ).join('-');
        await controller.pair(origin.toString(), grouped, caPath: ca.path);
        expect(controller.pairingState, 'paired');
        // A first pairing on the desktop shows the first-sync screen
        // (decision #163); confirm it, keeping everything (the desktop
        // default), so the fixture's own Retention choice below applies.
        expect(controller.firstSyncPending, isTrue);
        final choice = await controller.firstSyncListing();
        await controller.confirmFirstSync(choice.paths, choice.paths.toSet());
        await controller.stop();
        controller.dispose();
        final client = await reopen(profile);
        // Both roots are fixed Local; this fixture explicitly chooses Cloud
        // only for its own remote subtree on the second device.
        if (retention == Retention.cloud) {
          client.engine.manifest.entries[prefix] = Entry(
            prefix,
            ItemKind.directory,
          )..override = Retention.cloud;
          client.engine.manifest.save();
        }
        expect(client.engine.manifest.setting('accountUid'), uid);
        expect(client.engine.manifest.setting('accountOrigin'), origin.origin);
        expect(
          await secrets.read(client.identity.privateKeyRef) != null,
          isTrue,
        );
        record({
          'claim': 'pairing',
          'profile': label,
          'uid': uid,
          'fingerprint': fingerprint,
          'device_id': approval['device_id'],
        });
        return client;
      }

      Future<void> cycles(_Client a, _Client b) async {
        await a.engine.tick();
        await b.engine.tick();
        await a.engine.tick();
      }

      Future<String> remoteHash(_Client client, String path) async {
        final item = (await client.cloud.snapshot()).singleWhere(
          (e) => e.path == path,
        );
        final target = File('${fixture.path}/verify-${uniqueId()}');
        await client.cloud.download(path, target, etag: item.etag);
        final hash = (await sha256.bind(target.openRead()).first).toString();
        target.deleteSync();
        return hash;
      }

      bool cleaned = false;
      try {
        var a = await pair('a', Retention.local);
        var b = await pair('b', Retention.cloud);
        expect(
          a.engine.manifest.setting('profileId') !=
              b.engine.manifest.setting('profileId'),
          isTrue,
        );
        expect(a.identity.privateKeyRef != b.identity.privateKeyRef, isTrue);
        final filePath = '$prefix/Nested/space 雪/blob.bin';
        a.engine.tree.ensureDirectory(p.posix.dirname(filePath));
        final random = Random(1101);
        final original = List.generate(
          4 * 1024 * 1024,
          (_) => random.nextInt(256),
        );
        File('${a.engine.tree.root.path}/$filePath')
            .writeAsBytesSync(original, flush: true);
        final originalHash = sha256.convert(original).toString();
        await cycles(a, b);
        expect(await remoteHash(a, filePath), originalHash);
        expect(
          File('${b.engine.tree.root.path}/$filePath').existsSync(),
          isFalse,
        );
        expect(b.engine.manifest.entries[filePath]!.status, 'cloud-only');
        b.engine.setRetention(filePath, Retention.local);
        await b.engine.tick();
        expect(
          (await sha256
                  .bind(File('${b.engine.tree.root.path}/$filePath').openRead())
                  .first)
              .toString(),
          originalHash,
        );
        final before = ownedAllocated(b.engine.tree);
        b.engine.setRetention(filePath, Retention.cloud);
        await b.engine.tick();
        final after = ownedAllocated(b.engine.tree);
        expect(after, lessThan(before));
        expect(
          File('${b.engine.tree.root.path}/$filePath').existsSync(),
          isFalse,
        );
        expect(await remoteHash(a, filePath), originalHash);
        record({
          'claim': 'real Local/Cloud',
          'allocated_before': before,
          'allocated_after': after,
          'remote_hash': originalHash,
        });
        final names = [
          'question?.txt',
          'hash#.txt',
          '100%.txt',
          '%20.txt',
          '%2f.txt',
          '%FF.txt',
        ];
        a.engine.tree.ensureDirectory('$prefix/names');
        for (final name in names) {
          File('${a.engine.tree.root.path}/$prefix/names/$name')
              .writeAsStringSync('Exact filename: $name');
        }
        await cycles(a, b);
        final listedNames = (await b.cloud.snapshot())
            .map((e) => e.path)
            .toSet();
        for (final name in names) {
          final path = '$prefix/names/$name';
          expect(listedNames.contains(path), isTrue, reason: name);
          expect(
            await remoteHash(b, path),
            sha256.convert('Exact filename: $name'.codeUnits).toString(),
          );
        }
        record({
          'claim': 'exact punctuation and literal percent filenames',
          'names': names,
        });
        File('${a.engine.tree.root.path}/$filePath')
            .writeAsStringSync('updated nested content');
        await cycles(a, b);
        expect(
          await remoteHash(a, filePath),
          sha256.convert('updated nested content'.codeUnits).toString(),
        );
        a.cloud.online = false;
        File('${a.engine.tree.root.path}/$filePath')
            .writeAsStringSync('offline restart edit');
        await a.engine.tick();
        a.close();
        a = await reopen(a.profile);
        a.cloud.online = false;
        await a.engine.tick();
        expect(
          File('${a.engine.tree.root.path}/$filePath').readAsStringSync(),
          'offline restart edit',
        );
        a.cloud.online = true;
        await cycles(a, b);
        expect(
          await remoteHash(a, filePath),
          sha256.convert('offline restart edit'.codeUnits).toString(),
        );
        record({
          'claim': 'queued edit across injected client offline/restart',
          'result': 'passed',
        });
        b.engine.setRetention(filePath, Retention.local);
        await b.engine.tick();
        File('${a.engine.tree.root.path}/$filePath')
            .writeAsStringSync('alpha edit');
        File('${b.engine.tree.root.path}/$filePath')
            .writeAsStringSync('beta edit');
        await a.engine.tick();
        await b.engine.tick();
        final conflict = b.engine.manifest.entries[filePath]!;
        expect(conflict.conflict, isNotNull);
        expect(
          File('${b.engine.tree.root.path}/$filePath').readAsStringSync(),
          'beta edit',
        );
        expect(File(conflict.remoteCopy!).readAsStringSync(), 'alpha edit');
        await b.engine.keepBoth(filePath);
        await cycles(b, a);
        expect(
          await remoteHash(a, filePath),
          sha256.convert('alpha edit'.codeUnits).toString(),
        );
        expect(
          (await a.cloud.snapshot()).any(
            (e) => e.path.startsWith('$filePath.conflict-'),
          ),
          isTrue,
        );
        record({
          'claim': 'two-device conflict preserves complete variants',
          'result': 'passed',
        });
        final deleted = '$prefix/delete.txt';
        File('${a.engine.tree.root.path}/$deleted')
            .writeAsStringSync('delete fixture');
        await cycles(a, b);
        File('${a.engine.tree.root.path}/$deleted').deleteSync();
        await cycles(a, b);
        expect(
          (await a.cloud.snapshot()).any((e) => e.path == deleted),
          isFalse,
        );
        expect(b.engine.manifest.entries[deleted]!.etag, isNull);
        record({
          'claim': 'external file deletion propagates',
          'result': 'passed',
        });
        // First prove the real guarded collection contract through this transport.
        final guardPath = '$prefix/collection-proof';
        await a.cloud.mkdir(guardPath);
        final upload = File('${fixture.path}/guard-upload')
          ..writeAsStringSync('before');
        final child = '$guardPath/child.txt';
        await a.cloud.upload(child, upload, etag: null);
        final old = (await a.cloud.snapshot())
            .where(
              (e) => e.path == guardPath || p.posix.isWithin(guardPath, e.path),
            )
            .toList();
        final leaf = old.singleWhere((e) => e.path == child);
        upload.writeAsStringSync('changed descendant');
        await b.cloud.upload(child, upload, etag: leaf.etag);
        final qualified = DavCloud(
          origin,
          await a.identity.context(ca),
          folderDeletionQualified: true,
        );
        try {
          await expectLater(
            qualified.deleteFolder(
              guardPath,
              versions: {for (final e in old) e.path: e.etag},
            ),
            throwsA(
              isA<CloudFailure>().having(
                (e) => e.status,
                'stale directory',
                412,
              ),
            ),
          );
          final fresh = (await qualified.snapshot())
              .where(
                (e) =>
                    e.path == guardPath || p.posix.isWithin(guardPath, e.path),
              )
              .toList();
          await qualified.deleteFolder(
            guardPath,
            versions: {for (final e in fresh) e.path: e.etag},
          );
        } finally {
          qualified.close();
        }
        record({
          'claim': 'actual guarded collection precondition rejects changed descendant',
          'result': 'passed',
        });
        a.close();
        b.close();
        a = await reopen(a.profile, folders: true);
        b = await reopen(b.profile, folders: true);
        final folder = '$prefix/remove-folder';
        a.engine.tree.ensureDirectory('$folder/Nested');
        File('${a.engine.tree.root.path}/$folder/Nested/child.txt')
            .writeAsStringSync('folder deletion fixture');
        await cycles(a, b);
        Directory('${a.engine.tree.root.path}/$folder')
            .deleteSync(recursive: true);
        await cycles(a, b);
        expect(
          (await a.cloud.snapshot()).any(
            (e) => e.path == folder || p.posix.isWithin(folder, e.path),
          ),
          isFalse,
        );
        expect(b.engine.manifest.entries[folder]?.etag, isNull);
        record({
          'claim': 'external recursive folder deletion through qualified guard',
          'result': 'passed',
        });

        final dirtyFolder = '$prefix/deleted-with-local-edit';
        a.engine.tree.ensureDirectory(dirtyFolder);
        File('${a.engine.tree.root.path}/$dirtyFolder/base.txt')
            .writeAsStringSync('baseline');
        await cycles(a, b);
        b.engine.setRetention(dirtyFolder, Retention.local);
        await b.engine.tick();
        File('${b.engine.tree.root.path}/$dirtyFolder/new.txt')
            .writeAsStringSync('unsynchronized child');
        Directory('${a.engine.tree.root.path}/$dirtyFolder')
            .deleteSync(recursive: true);
        await a.engine.tick();
        await b.engine.tick();
        await b.engine.tick();
        expect(b.engine.manifest.entries[dirtyFolder]!.conflict, isNotNull);
        expect(
          File('${b.engine.tree.root.path}/$dirtyFolder/new.txt')
              .readAsStringSync(),
          'unsynchronized child',
        );
        expect(
          (await b.cloud.snapshot()).any(
            (e) =>
                e.path == dirtyFolder || p.posix.isWithin(dirtyFolder, e.path),
          ),
          isFalse,
        );
        record({
          'claim': 'deleted remote folder plus new unsynced child remains local conflict without resurrection',
          'result': 'passed',
        });

        final retainedKey = await secrets.read(a.identity.privateKeyRef);
        final retainedCsr = a.engine.manifest.setting('csr');
        final retainedFingerprint = a.engine.manifest.setting('fingerprint');
        final oldDevice = a.engine.manifest.setting('deviceId')!;
        final oldLeaf = DavCloud(origin, await a.identity.context(ca));
        await operator(['revoke', oldDevice]);
        revoked.add(oldDevice);
        final pendingPath = '$prefix/revoked-pending.txt';
        File('${a.engine.tree.root.path}/$pendingPath')
            .writeAsStringSync('pending through revocation');
        await a.engine.tick();
        expect(
          File('${a.engine.tree.root.path}/$pendingPath').readAsStringSync(),
          'pending through revocation',
        );
        await expectLater(
          oldLeaf.snapshot(),
          throwsA(
            isA<CloudFailure>().having(
              (e) => e.status,
              'revoked old leaf',
              403,
            ),
          ),
        );
        final profileA = a.profile;
        a.close();
        final repair = ClientController(profileA, secrets: secrets);
        await repair.initialize();
        await repair.stop();
        final newInvitation = await operator([
          'invite',
          uid,
          '--rights',
          'write',
        ]);
        invitations.add(newInvitation['id'] as String);
        repair.pairingWait = Duration.zero;
        await repair.pair(
          origin.toString(),
          newInvitation['code'] as String,
          caPath: ca.path,
        );
        await repair.stop();
        expect(repair.fingerprint, retainedFingerprint);
        final newApproval = await operator([
          'approve',
          newInvitation['id'] as String,
          '--fingerprint',
          repair.fingerprint!,
        ]);
        devices.add(newApproval['device_id'] as String);
        approvedInvitations.add(newInvitation['id'] as String);
        await repair.pair(
          origin.toString(),
          newInvitation['code'] as String,
          caPath: ca.path,
        );
        await repair.stop();
        repair.dispose();
        a = await reopen(profileA, folders: true);
        expect(
          await secrets.read(a.identity.privateKeyRef) == retainedKey,
          isTrue,
          reason: 'Retained private key changed.',
        );
        expect(a.engine.manifest.setting('csr') == retainedCsr, isTrue);
        expect(a.engine.manifest.setting('accountUid'), uid);
        await expectLater(
          oldLeaf.snapshot(),
          throwsA(
            isA<CloudFailure>().having(
              (e) => e.status,
              'old leaf stays revoked after same-key re-pair',
              403,
            ),
          ),
        );
        oldLeaf.close();
        await cycles(a, b);
        expect(
          await remoteHash(a, pendingPath),
          sha256.convert('pending through revocation'.codeUnits).toString(),
        );
        record({
          'claim': 'real revocation preserves pending bytes; retained-key new invitation resumes without reviving old leaf',
          'result': 'passed',
        });

        // The actual UI uses an isolated, paired profile after manual engines stop.
        final observer = DavCloud(origin, await b.identity.context(ca));
        a.close();
        b.close();
        final view = ClientController(b.profile, secrets: secrets);
        await tester.pumpWidget(CloudApp(controller: view));
        await view.initialize();
        for (
          var i = 0;
          i < 100 && !view.entries.any((e) => e['path'] == filePath);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(find.text('blob.bin'), findsOneWidget);
        Future<void> workerUntil(Future<bool> Function() predicate) async {
          for (var attempt = 0; attempt < 150; attempt++) {
            if (await predicate()) return;
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          throw StateError(
            'Actual worker condition did not complete: ${view.message}',
          );
        }

        final workerFolder = '$prefix/actual-worker-folder';
        final workerFile = File('${view.root}/$workerFolder/child.txt');
        workerFile.parent.createSync(recursive: true);
        workerFile.writeAsStringSync('actual app worker bytes');
        await workerUntil(
          () async => (await observer.snapshot()).any(
            (e) => e.path == '$workerFolder/child.txt',
          ),
        );
        await workerUntil(
          () async => view.entries.any(
            (e) => e['path'] == workerFolder && e['etag'] != null,
          ),
        );
        view.command('delete', workerFolder);
        await workerUntil(
          () async => !(await observer.snapshot()).any(
            (e) =>
                e.path == workerFolder ||
                p.posix.isWithin(workerFolder, e.path),
          ),
        );
        await workerUntil(
          () async => view.entries.any(
            (e) =>
                e['path'] == workerFolder &&
                e['etag'] == null &&
                (e['status'] as String).startsWith('deleted'),
          ),
        );
        expect(workerFile.parent.existsSync(), isFalse);
        observer.close();
        record({
          'claim': 'actual paired app worker discovers/uploads synthetic subtree and executes guarded Delete everywhere',
          'result': 'passed',
        });

        await tester.pumpAndSettle();
        File('${fixture.path}/ui-ready.json').writeAsStringSync(
          jsonEncode({
            'pid': pid,
            'root': view.root,
            'profile': b.profile.path,
          }),
        );
        await Future<void>.delayed(const Duration(seconds: 30));
        await view.stop();
        await tester.pumpWidget(const SizedBox());
        view.dispose();
        final cleanup = await reopen(a.profile, folders: true);
        final owned = (await cleanup.cloud.snapshot())
            .where((e) => e.path == prefix || p.posix.isWithin(prefix, e.path))
            .toList();
        if (owned.isNotEmpty) {
          await cleanup.cloud.deleteFolder(
            prefix,
            versions: {for (final e in owned) e.path: e.etag},
          );
        }
        cleanup.close();
        cleaned = true;
        File('${fixture.path}/receipt.json').writeAsStringSync(
          jsonEncode({
            'origin': origin.origin,
            'uid': uid,
            'prefix': prefix,
            'events': events,
            'cloud_fixture_cleaned': true,
            'client_head': config['client_head'],
            'gateway_head': config['gateway_head'],
            'evidence_layers': {
              'pairing': 'Actual ClientController and Linux libsecret plugin',
              'protocol_and_reconciliation': 'Real DAV/mTLS and two isolated SyncEngine profiles; injected offline explicitly labelled',
              'app_worker': 'Actual paired CloudApp, background isolate, automatic scan/upload and guarded delete',
              'window':
                  'Own PID only; see own-window.json and own-paired-app.png',
            },
            'scope': 'Real the VM host gateway and Linux app; injected offline supplements direct network checks. No laptop/production claim.',
          }),
          flush: true,
        );
      } finally {
        for (final client in clients.toList()) {
          client.close();
        }
        if (!cleaned && profiles.isNotEmpty) {
          _Client? cleanup;
          try {
            cleanup = await reopen(profiles.last, folders: true);
            final owned = (await cleanup.cloud.snapshot())
                .where(
                  (e) => e.path == prefix || p.posix.isWithin(prefix, e.path),
                )
                .toList();
            if (owned.isNotEmpty) {
              await cleanup.cloud.deleteFolder(
                prefix,
                versions: {for (final e in owned) e.path: e.etag},
              );
            }
            cleaned = true;
          } catch (_) {
            stdout.writeln(
              'Scoped fixture cleanup pending; own artifacts retained.',
            );
          } finally {
            cleanup?.close();
          }
        }
        for (final device in devices.difference(revoked)) {
          await operator(['revoke', device]);
        }
        for (final invitation in invitations.difference(approvedInvitations)) {
          await operator(['deny', invitation]);
        }
        if (cleaned) {
          for (final profile in profiles) {
            final store = Manifest(profile);
            final identity = DeviceIdentity(store, secrets);
            await secrets.delete(identity.privateKeyRef);
            await secrets.delete(identity.invitationRef);
            store.close();
          }
        }
        File('${fixture.path}/cleanup.json').writeAsStringSync(
          jsonEncode({
            'device_ids_revoked': devices.toList(),
            'cloud_fixture_cleaned': cleaned,
            'keyring_entries_removed': cleaned,
          }),
          flush: true,
        );
      }
    },
    skip: configPath == null,
  );
}
