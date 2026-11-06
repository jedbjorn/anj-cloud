// Opt-in, against a disposable review stack only (spec #31 M7, acceptance
// row 10; matches spec #28 row 9, with spec #35's code-only pairing). One
// device per process: this same file runs as the macOS device on mac-test
// and as the Linux device on the VM host, started by
// deploy/desktop_parity_fixture.py, which owns the stack
// (anj-cloud-review-<tag>), the reverse forward that makes the stack's
// https://127.0.0.1:<port> reachable from mac-test, the invitations and the
// relay of each side's signal files to the other.
// Skipped unless ANJ_PARITY_CONFIG names its JSON:
//   {"role": "mac" | "linux", "origin", "work" (absent), "signal",
//    "prefix", "code" (this device's pinned code, typed),
//    "foreign_code" (mac: pinned to another CA), "unknown_code",
//    "denied_code", "used_code" (the Linux device's, once redeemed),
//    "expired_code", "expired_after" (mac),
//    "cases" (false skips the scripted cases; rehearsal only)}
// Each device pairs by the code alone through the real controller
// (in-process device crypto): the app fetches the CA from /v1/ca, keeps it
// only if it matches the code's pin, and the gateway approves at once. The
// devices reconcile through the gateway with the platform's native binding:
// the Darwin dylib on APFS, libanj_rootfs.so on the VM host. Secrets are held in
// memory for the run; keychain custody is row 8 (M3, GUI session). Evidence
// carries digests and states, never codes or keys.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart' show CloudFailure;
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  final configPath = Platform.environment['ANJ_PARITY_CONFIG'];
  test(
    'macOS and Linux devices pair and reconcile both ways through the review '
    'gateway',
    () async {
      final config = jsonDecode(
        File(configPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final role = config['role'] as String;
      if (role != 'mac' && role != 'linux') {
        throw StateError('role must be mac or linux');
      }
      // A the VM host rehearsal of the harness (desktop_parity_fixture.py
      // --rehearse) runs both roles on Linux; it proves the harness, not
      // macOS.
      final rehearsal = Platform.environment['ANJ_PARITY_REHEARSAL'] == '1';
      // `--break expiry` skips the scripted cases to reach the expired
      // invitation at once; a real run always runs them.
      final cases = !rehearsal || config['cases'] != false;
      if (!rehearsal &&
          (role == 'mac' && !Platform.isMacOS ||
              role == 'linux' && !Platform.isLinux)) {
        throw StateError('role $role on ${Platform.operatingSystem}');
      }
      final peer = role == 'mac' ? 'linux' : 'mac';
      final origin = config['origin'] as String;
      if (!RegExp(r'^https://127\.0\.0\.1:\d+$').hasMatch(origin)) {
        throw StateError('Use the review stack on 127.0.0.1.');
      }
      final work = Directory(config['work'] as String);
      if (work.existsSync()) throw StateError('work must be absent');
      work.createSync(recursive: true);
      final signal = Directory(config['signal'] as String)
        ..createSync(recursive: true);
      final prefix = config['prefix'] as String;
      final library = Platform.environment['ANJ_ROOTFS_LIBRARY'];

      final evidence = <Map<String, Object?>>[];
      void record(String claim, [Map<String, Object?> facts = const {}]) {
        evidence.add({'claim': claim, ...facts});
        File(p.join(signal.path, '$role-progress.json')).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
        stdout.writeln('M7 $role claim: $claim');
      }

      // Each side writes <role>-<name>; the driver copies it to the peer's
      // signal directory. A barrier waits for the peer's file of that name.
      Future<void> barrier(
        String name, {
        Duration timeout = const Duration(minutes: 4),
      }) async {
        File(p.join(signal.path, '$role-$name')).writeAsStringSync('');
        final peerFile = File(p.join(signal.path, '$peer-$name'));
        final deadline = DateTime.now().add(timeout);
        while (!peerFile.existsSync()) {
          if (File(p.join(signal.path, '$peer-failed')).existsSync()) {
            throw StateError('$peer failed before $name');
          }
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('No $peer at $name.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      // Both devices reach the gateway from 127.0.0.1, which admits 10
      // enrolment requests a minute per source. A 429 is never an answer:
      // wait and repeat, so a rate limit can neither fail a pairing nor
      // pass as a refusal.
      Future<void> admitted(Future<void> Function() request) async {
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (true) {
          try {
            return await request();
          } catch (error) {
            if (!'$error'.contains('(429)') ||
                DateTime.now().isAfter(deadline)) {
              rethrow;
            }
          }
          await Future<void>.delayed(const Duration(seconds: 7));
        }
      }

      final secrets = MemorySecrets();
      Future<ClientController> controllerFor(String label) async {
        final controller = ClientController(
          Directory(p.join(work.path, 'profile-$label')),
          secrets: secrets,
          nativeLibrary: library,
        );
        await controller.initialize();
        final parent = Directory(p.join(work.path, 'files-$label'))
          ..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        return controller;
      }

      // Everything under a root, as relative paths: a refused pairing must
      // leave it exactly as it was ("no file access").
      Set<String> rootListing(String label) {
        final root = Directory(p.join(work.path, 'files-$label'));
        return {
          for (final e in root.listSync(recursive: true))
            p.relative(e.path, from: root.path),
        };
      }

      // Refused for the named reason only: `failure` is what the attempt
      // must throw. A refused code stores no trust anchor and pairs nothing
      // (spec #35 rules 2 and 3), and the root is left exactly as it was.
      Future<void> refusedPairing(
        String what,
        ClientController controller,
        Future<void> Function() attempt, {
        required Matcher failure,
      }) async {
        final before = rootListing('refused');
        Object? thrown;
        try {
          await admitted(attempt);
        } catch (error) {
          thrown = error;
        }
        await controller.stop();
        final answer = controller.pairingState;
        expect(
          answer,
          isNot(anyOf('approved', 'paired', 'pending')),
          reason: what,
        );
        expect(thrown, failure, reason: what);
        expect(controller.ca, isNull, reason: '$what: a trust anchor stored');
        final store = Manifest(Directory(p.join(work.path, 'profile-refused')));
        try {
          expect(store.setting('ca'), isNull, reason: '$what: CA stored');
          expect(store.setting('deviceId'), isNull, reason: '$what: paired');
        } finally {
          store.close();
        }
        expect(rootListing('refused'), before, reason: '$what: root touched');
        record('pairing refused: $what', {
          'error': thrown.runtimeType.toString(),
          if (thrown is CloudFailure) 'status': thrown.status,
          'message': '$thrown',
        });
      }

      // The gateway's one answer for an unknown, denied, used or expired
      // code: 400 "Code not valid", never a 429 and never more detail.
      final codeNotValid = isA<CloudFailure>().having(
        (f) => f.status,
        'status',
        400,
      );

      Future<_Device> open(String label) async {
        final profile = Directory(p.join(work.path, 'profile-$label'));
        final store = Manifest(profile);
        final identity = DeviceIdentity(store, secrets);
        // The CA the app fetched and checked against the code (spec #35).
        final ca = store.setting('ca')!;
        final tree = RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          platformAdapters().rootFilesystem(library),
        );
        final cloud = DavCloud(
          Uri.parse(origin),
          await identity.context(File(ca)),
        );
        return _Device(SyncEngine(store, tree, cloud), cloud);
      }

      // Code only: no CA file, no fingerprint step, no Check approval.
      Future<_Device> pair(String code) async {
        final controller = await controllerFor(role);
        await admitted(() => controller.pair(origin, code));
        await controller.stop();
        expect(controller.pairingState, 'paired');
        expect(controller.ca, isNotNull, reason: 'the fetched CA is kept');
        // Decision #163 (#97): a new desktop pairing first asks which
        // folders stay local. The fixture account has none of its own yet,
        // so the choice is confirmed empty (everything stays Local), as the
        // screen's default; the engine below then runs as after the screen.
        // The gate must have fired: a desktop pairing always asks first
        // (PR #100 review I2: prove it, rather than tolerate its absence).
        expect(
          controller.firstSyncPending,
          isTrue,
          reason: 'decision #163: a new pairing asks which folders stay local',
        );
        await controller.confirmFirstSync(const [], const {});
        await controller.stop();
        record('first-sync choice confirmed (decision #163)');
        expect(controller.firstSyncPending, isFalse);
        controller.dispose();
        record('paired by the code alone', {
          'fingerprint': controller.fingerprint,
        });
        return open(role);
      }

      _Device? device;
      try {
        // ---- pairing ----------------------------------------------------
        late ClientController probe;
        if (role == 'mac') {
          // Refused before any file access and before any trust is stored:
          // a code pinned to another CA (the app's own check, rule 2), a
          // code never issued and a denied one (the gateway's). A code the
          // Linux device redeemed and the expiring one are tried last.
          probe = await controllerFor('refused');
          await refusedPairing(
            'code for another server',
            probe,
            () => probe.pair(origin, config['foreign_code'] as String),
            failure: isA<PairingRefused>().having(
              (r) => r.message,
              'message',
              notThisServer,
            ),
          );
          await refusedPairing(
            'unknown code',
            probe,
            () => probe.pair(origin, config['unknown_code'] as String),
            failure: codeNotValid,
          );
          await refusedPairing(
            'denied code',
            probe,
            () => probe.pair(origin, config['denied_code'] as String),
            failure: codeNotValid,
          );
        }
        device = await pair(config['code'] as String);
        final d = device;
        await barrier('paired');
        if (role == 'mac') {
          // The Linux device's code, now redeemed by its key: another key
          // presenting it is refused (and the admin is alerted).
          await refusedPairing(
            'code already used by another device',
            probe,
            () => probe.pair(origin, config['used_code'] as String),
            failure: codeNotValid,
          );
        }

        Future<String?> remoteHash(String path) async {
          final item = (await d.cloud.snapshot())
              .where((e) => e.path == path)
              .firstOrNull;
          if (item == null) return null;
          final target = File(
            p.join(work.path, 'verify-${Random().nextInt(1 << 30)}'),
          );
          await d.cloud.download(path, target, etag: item.etag);
          final hash = _digest(target.readAsBytesSync());
          target.deleteSync();
          return hash;
        }

        Future<void> until(
          String what,
          Future<bool> Function() done, {
          Duration timeout = const Duration(seconds: 90),
        }) async {
          final deadline = DateTime.now().add(timeout);
          while (true) {
            await d.engine.tick();
            if (await done()) return;
            if (DateTime.now().isAfter(deadline)) {
              throw StateError('$role: $what not reached');
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }

        String? localHash(String path) {
          final file = d.file(path);
          return file.existsSync() ? _digest(file.readAsBytesSync()) : null;
        }

        final expected = <String, String>{};

        // Every case runs twice: macOS to Linux, then Linux to macOS.
        for (final actor in cases ? const ['mac', 'linux'] : const <String>[]) {
          final acting = actor == role;
          final dir = '$prefix/from-$actor';
          final tag = 'from-$actor';

          // ---- create: a 2 MiB file under a nested Unicode path --------
          final blobPath = '$dir/Nested/space 雪 café/blob.bin';
          final random = Random(actor == 'mac' ? 31 : 32);
          final blob = List.generate(
            2 * 1024 * 1024,
            (_) => random.nextInt(256),
          );
          final notePath = '$dir/note.txt';
          if (acting) {
            d.engine.tree.ensureDirectory(p.posix.dirname(blobPath));
            d.file(blobPath).writeAsBytesSync(blob, flush: true);
            d.file(notePath).writeAsStringSync('written by $actor');
            await until(
              'create uploaded',
              () async =>
                  await remoteHash(blobPath) == _digest(blob) &&
                  await remoteHash(notePath) ==
                      _digest(utf8.encode('written by $actor')),
            );
          }
          await barrier('$tag-create-up');
          if (!acting) {
            await until(
              'create downloaded',
              () async =>
                  localHash(blobPath) == _digest(blob) &&
                  localHash(notePath) ==
                      _digest(utf8.encode('written by $actor')),
            );
            record('create $actor to server to $role', {
              'sha256': _digest(blob),
            });
          }
          await barrier('$tag-create-down');
          expected[blobPath] = _digest(blob);

          // ---- edit ------------------------------------------------------
          final edited = utf8.encode('edited by $actor');
          if (acting) {
            d.file(notePath).writeAsBytesSync(edited, flush: true);
            await until(
              'edit uploaded',
              () async => await remoteHash(notePath) == _digest(edited),
            );
          }
          await barrier('$tag-edit-up');
          if (!acting) {
            await until(
              'edit downloaded',
              () async => localHash(notePath) == _digest(edited),
            );
            record('edit $actor to $role');
          }
          await barrier('$tag-edit-down');

          // ---- rename ----------------------------------------------------
          final renamedPath = '$dir/renamed.txt';
          if (acting) {
            d.file(notePath).renameSync(d.file(renamedPath).path);
            await until(
              'rename uploaded',
              () async =>
                  await remoteHash(renamedPath) == _digest(edited) &&
                  await remoteHash(notePath) == null,
            );
          }
          await barrier('$tag-rename-up');
          if (!acting) {
            await until(
              'rename applied',
              () async =>
                  localHash(renamedPath) == _digest(edited) &&
                  !d.file(notePath).existsSync(),
            );
            record('rename $actor to $role');
          }
          await barrier('$tag-rename-down');

          // ---- delete ----------------------------------------------------
          if (acting) {
            d.file(renamedPath).deleteSync();
            await until(
              'delete uploaded',
              () async => await remoteHash(renamedPath) == null,
            );
          }
          await barrier('$tag-delete-up');
          if (!acting) {
            await until(
              'delete applied',
              () async => !d.file(renamedPath).existsSync(),
            );
            record('deletion $actor to $role');
          }
          await barrier('$tag-delete-down');

          // ---- conflict: both edit; the actor's edit reaches the server
          // first, and the other device keeps its own with a recovery copy.
          final shared = '$dir/conflict.txt';
          if (acting) {
            d.file(shared).writeAsStringSync('base');
            await until(
              'base uploaded',
              () async =>
                  await remoteHash(shared) == _digest(utf8.encode('base')),
            );
          }
          await barrier('$tag-conflict-base-up');
          if (!acting) {
            await until(
              'base downloaded',
              () async => localHash(shared) == _digest(utf8.encode('base')),
            );
          }
          await barrier('$tag-conflict-base-down');
          final mine = utf8.encode('$role edit');
          d.file(shared).writeAsBytesSync(mine, flush: true);
          await barrier('$tag-conflict-edited');
          if (acting) {
            await until(
              'actor edit uploaded',
              () async => await remoteHash(shared) == _digest(mine),
            );
          }
          await barrier('$tag-conflict-up');
          if (!acting) {
            await until(
              'conflict seen',
              () async => d.engine.manifest.entries[shared]?.conflict != null,
            );
            final entry = d.engine.manifest.entries[shared]!;
            expect(d.file(shared).readAsStringSync(), '$role edit');
            expect(File(entry.remoteCopy!).readAsStringSync(), '$actor edit');
            expect(
              await remoteHash(shared),
              _digest(utf8.encode('$actor edit')),
            );
            record('conflict keeps both versions on $role', {
              'status': entry.status,
            });
          }
          await barrier('$tag-conflict-down');
          expected[shared] = _digest(utf8.encode('$actor edit'));

          // ---- exclusions (#21): never uploaded, never seen by the peer --
          const excluded = ['.DS_Store', 'Thumbs.db', 'desktop.ini'];
          if (acting) {
            for (final name in excluded) {
              d.file('$dir/$name').writeAsStringSync('$name from $actor');
            }
            for (var i = 0; i < 3; i++) {
              await d.engine.tick();
            }
            for (final name in excluded) {
              expect(await remoteHash('$dir/$name'), isNull, reason: name);
            }
            record('exclusions are not uploaded from $role', {
              'names': excluded,
            });
          }
          await barrier('$tag-excluded-up');
          if (!acting) {
            for (var i = 0; i < 2; i++) {
              await d.engine.tick();
            }
            for (final name in excluded) {
              expect(d.file('$dir/$name').existsSync(), isFalse, reason: name);
            }
          }
          await barrier('$tag-excluded-down');

          // ---- the upload limit: 64 MiB ----------------------------------
          final big = '$dir/too-big.bin';
          if (acting) {
            final raf = d.file(big).openSync(mode: FileMode.write)
              ..setPositionSync(65 * 1024 * 1024)
              ..writeByteSync(1);
            raf.closeSync();
            await until(
              'limit shown',
              () async =>
                  d.engine.manifest.entries[big]?.status.startsWith(
                    'Too large for the server',
                  ) ??
                  false,
            );
            expect(await remoteHash(big), isNull);
            record('a file over the limit stays on $role with its reason', {
              'status': d.engine.manifest.entries[big]!.status,
            });
          }
          await barrier('$tag-limit-up');
          if (!acting) {
            for (var i = 0; i < 2; i++) {
              await d.engine.tick();
            }
            expect(d.file(big).existsSync(), isFalse);
          }
          await barrier('$tag-limit-down');
          if (acting) d.file(big).deleteSync();
        }

        // ---- the expired invitation, used last ----------------------------
        if (role == 'mac') {
          final after = (config['expired_after'] as num).toInt() + 5;
          final wait = after - DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (wait > 0) {
            record('waiting for the invitation to expire', {'seconds': wait});
            await Future<void>.delayed(Duration(seconds: wait));
          }
          await refusedPairing(
            'expired code',
            probe,
            () => probe.pair(origin, config['expired_code'] as String),
            failure: codeNotValid,
          );
          probe.dispose();
          File(p.join(signal.path, 'mac-expect.json')).writeAsStringSync(
            jsonEncode({'prefix': prefix, 'files': expected}),
          );
        }
        await barrier('done', timeout: const Duration(minutes: 12));
        record('done');
      } catch (_) {
        File(p.join(signal.path, '$role-failed')).writeAsStringSync('');
        rethrow;
      } finally {
        device?.close();
      }
    },
    skip: configPath == null
        ? 'Opt-in: set ANJ_PARITY_CONFIG for a review stack'
        : false,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

class _Device {
  _Device(this.engine, this.cloud);
  final SyncEngine engine;
  final DavCloud cloud;
  String get root => engine.tree.root.path;
  File file(String relative) => File(p.joinAll([root, ...relative.split('/')]));
  void close() {
    engine.close();
    cloud.close();
  }
}
