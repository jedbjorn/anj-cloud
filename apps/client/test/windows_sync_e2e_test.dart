@TestOn('windows')
library;

// Opt-in, against a disposable review stack only (spec #32 W4, Acceptance
// rows 8 and 12): run by deploy/windows_sync_fixture.py, which owns the stack
// (anj-cloud-review-<tag>), the reverse forward that makes the stack's
// https://127.0.0.1:<port> reachable from this guest, the invitations and
// the operator approvals. Skipped unless ANJ_W4_CONFIG names its JSON:
//   {"origin", "ca", "other_server_code", "code_a", "qr_b", "denied_code",
//    "names_folder", "work" (absent), "signal" (handshake directory)}
// Two Windows devices of one account pair through the real controller
// (DPAPI secrets, anj_rootfs.dll, in-process device crypto) and reconcile
// through the gateway; evidence carries digests, never codes or keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/windows/dpapi_secrets.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/eviction_fixture.dart' show ownedAllocated;
import 'qr_image.dart';

class _Device {
  _Device(this.label, this.profile, this.engine, this.cloud);
  final String label;
  final Directory profile;
  final SyncEngine engine;
  final DavCloud cloud;
  String get root => engine.tree.root.path;
  File file(String relative) => File(p.joinAll([root, ...relative.split('/')]));
  void close() {
    engine.close();
    cloud.close();
  }
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  final configPath = Platform.environment['ANJ_W4_CONFIG'];
  test(
    'two Windows devices pair and reconcile through the review gateway',
    () async {
      final config = jsonDecode(
        File(configPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final origin = config['origin'] as String;
      if (!RegExp(r'^https://127\.0\.0\.1:\d+$').hasMatch(origin)) {
        throw StateError('Use the review stack through the reverse forward.');
      }
      final ca = config['ca'] as String;
      final work = Directory(config['work'] as String);
      if (work.existsSync()) {
        throw StateError('The work directory must be absent.');
      }
      work.createSync(recursive: true);
      final signal = Directory(config['signal'] as String)
        ..createSync(recursive: true);
      final evidence = <Map<String, Object?>>[];
      void record(String claim, [Map<String, Object?> facts = const {}]) {
        evidence.add({'claim': claim, ...facts});
        File(p.join(signal.path, 'progress.json')).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
        stdout.writeln('W4 claim: $claim');
      }

      final secrets = DpapiSecrets(
        directory: p.join(work.path, 'secrets'),
        makePrivate: (path) => windowsRootFilesystem().privateDir(path),
      );
      final nonce = 'w4-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      final prefix = 'Documents/$nonce';

      // ---- pairing ------------------------------------------------------
      Future<ClientController> controllerFor(String label) async {
        final controller = ClientController(
          Directory(p.join(work.path, 'profile-$label')),
          secrets: secrets,
        );
        await controller.initialize();
        // The driver approves by fingerprint: pair() returns the pending
        // answer at once and is called again after the approval.
        controller.pairingWait = Duration.zero;
        final parent = Directory(p.join(work.path, 'files-$label'))
          ..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        return controller;
      }

      // Refused: the attempt throws (TLS, unknown code) or the server
      // answers with a state that is neither pending nor approved (denied).
      // Either way no device is enrolled and no root file is touched.
      Future<void> refusedPairing(
        String what,
        ClientController controller,
        Future<void> Function() attempt,
      ) async {
        Object? failure;
        try {
          await attempt();
        } catch (error) {
          failure = error;
        }
        final state = controller.pairingState;
        expect(
          failure != null || (state != 'paired' && state != 'pending'),
          isTrue,
          reason: '$what: $state',
        );
        expect(controller.pairingState, isNot('paired'), reason: what);
        record('pairing refused: $what', {
          'error': failure?.runtimeType.toString(),
          'state': state,
        });
      }

      Future<_Device> open(String label) async {
        final store = Manifest(Directory(p.join(work.path, 'profile-$label')));
        final identity = DeviceIdentity(store, secrets);
        final tree = RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          windowsRootFilesystem(),
        );
        final cloud = DavCloud(
          Uri.parse(origin),
          await identity.context(File(ca)),
        );
        return _Device(
          label,
          Directory(p.join(work.path, 'profile-$label')),
          SyncEngine(store, tree, cloud),
          cloud,
        );
      }

      Future<_Device> pair(String label, String code) async {
        final controller = await controllerFor(label);
        // The code carries the CA pin (spec #35); this stack has no console
        // backend, so the operator approves by fingerprint.
        await controller.pair(origin, code);
        await controller.stop();
        expect(controller.pairingState, 'pending');
        // The driver compares and approves this fingerprint (and first tries
        // a wrong one, which the operator must refuse).
        File(p.join(signal.path, 'fingerprint-$label.json')).writeAsStringSync(
          jsonEncode({'fingerprint': controller.fingerprint}),
        );
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        // The gateway admits 10 enrolment requests a minute per source: poll
        // every 7 s, and a 429 just means wait.
        while (controller.pairingState != 'paired') {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('No approval for $label.');
          }
          await Future<void>.delayed(const Duration(seconds: 7));
          try {
            await controller.pair(origin, code);
          } catch (error) {
            if (!'$error'.contains('(429)')) rethrow;
          }
          await controller.stop();
        }
        controller.dispose();
        record('paired', {
          'device': label,
          'fingerprint': controller.fingerprint,
        });
        return open(label);
      }

      final devices = <_Device>[];
      try {
        // A code pinned to another server's CA, and a code the server never
        // issued (or denied): refused before any file access.
        final probe = await controllerFor('refused');
        await refusedPairing(
          'a code for another server',
          probe,
          () => probe.pair(origin, config['other_server_code'] as String),
        );
        expect(probe.ca ?? '', isEmpty, reason: 'no trust anchor stored');
        await refusedPairing(
          'unknown invitation',
          probe,
          () => probe.pair(
            origin,
            'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
            caPath: ca,
          ),
        );
        await refusedPairing(
          'denied invitation',
          probe,
          () => probe.pair(origin, config['denied_code'] as String, caPath: ca),
        );
        await probe.stop();
        probe.dispose();

        // Device A: the typed invitation. Device B: the invitation read
        // from a QR image file (the spec #35 dialog has no image entry; the
        // decoder is kept for this run and its 1-bit PNG case).
        final a = await pair('a', config['code_a'] as String);
        devices.add(a);
        // A 1-bit palette PNG (qrencode's default).
        final qr = decodeQrImage(
          File(config['qr_b'] as String).readAsBytesSync(),
        );
        record('invitation read from a QR image');
        final b = await pair('b', qr);
        devices.add(b);
        expect(
          a.engine.manifest.setting('profileId'),
          isNot(b.engine.manifest.setting('profileId')),
        );

        Future<void> cycles() async {
          await a.engine.tick();
          await b.engine.tick();
          await a.engine.tick();
        }

        // A local change reaches the engine through the watcher, and a
        // deletion under Documents waits for losses there to settle (about
        // 12 s), so a fixed number of passes proves nothing: passes repeat
        // until the expected state is there, within a deadline.
        Future<int> until(String what, Future<bool> Function() done) async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          for (var rounds = 1; ; rounds++) {
            await cycles();
            if (await done()) return rounds;
            if (DateTime.now().isAfter(deadline)) {
              throw StateError('Not reached within 90 s: $what');
            }
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }

        Future<String?> remoteHash(String path) async {
          final items = await a.cloud.snapshot();
          final item = items.where((e) => e.path == path).firstOrNull;
          if (item == null) return null;
          final target = File(
            p.join(work.path, 'verify-${Random().nextInt(1 << 30)}'),
          );
          await a.cloud.download(path, target, etag: item.etag);
          final hash = _digest(target.readAsBytesSync());
          target.deleteSync();
          return hash;
        }

        // ---- create, both ways; nested Unicode path ---------------------
        final blobPath = '$prefix/Nested/space 雪/blob.bin';
        a.engine.tree.ensureDirectory(p.posix.dirname(blobPath));
        final random = Random(32);
        final blob = List.generate(2 * 1024 * 1024, (_) => random.nextInt(256));
        a.file(blobPath).writeAsBytesSync(blob, flush: true);
        await until('the blob on B', () async => b.file(blobPath).existsSync());
        expect(await remoteHash(blobPath), _digest(blob));
        expect(_digest(b.file(blobPath).readAsBytesSync()), _digest(blob));
        record('create A to server to B', {'sha256': _digest(blob)});
        b.file('$prefix/from-b.txt').writeAsStringSync('written on B');
        await until(
          'the file from B on A',
          () async => a.file('$prefix/from-b.txt').existsSync(),
        );
        expect(a.file('$prefix/from-b.txt').readAsStringSync(), 'written on B');
        record('create B to server to A');

        // ---- edit, rename, delete -------------------------------------
        a.file('$prefix/from-b.txt').writeAsStringSync('edited on A');
        await until(
          'the edit on B',
          () async =>
              b.file('$prefix/from-b.txt').readAsStringSync() == 'edited on A',
        );
        a
            .file('$prefix/from-b.txt')
            .renameSync(a.file('$prefix/renamed.txt').path);
        await until(
          'the rename on B',
          () async => b.file('$prefix/renamed.txt').existsSync(),
        );
        expect(b.file('$prefix/renamed.txt').readAsStringSync(), 'edited on A');
        expect(b.file('$prefix/from-b.txt').existsSync(), isFalse);
        record('edit and rename propagate');
        b.file('$prefix/renamed.txt').deleteSync();
        final passesToDelete = await until(
          'the deletion on A',
          () async => !a.file('$prefix/renamed.txt').existsSync(),
        );
        expect(a.file('$prefix/renamed.txt').existsSync(), isFalse);
        expect(await remoteHash('$prefix/renamed.txt'), isNull);
        record('deletion propagates', {'rounds': passesToDelete});

        // ---- conflict ---------------------------------------------------
        final shared = '$prefix/conflict.txt';
        a.file(shared).writeAsStringSync('base');
        await until('the base on B', () async => b.file(shared).existsSync());
        a.file(shared).writeAsStringSync('alpha edit');
        b.file(shared).writeAsStringSync('beta edit');
        // A uploads its edit first; B then meets it with its own.
        final sharedEtag = (await a.cloud.snapshot())
            .firstWhere((e) => e.path == shared)
            .etag;
        for (var i = 0; i < 60; i++) {
          await a.engine.tick();
          final now = (await a.cloud.snapshot())
              .firstWhere((e) => e.path == shared)
              .etag;
          if (now != sharedEtag) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        for (var i = 0; i < 60; i++) {
          await b.engine.tick();
          if (b.engine.manifest.entries[shared]?.conflict != null) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        final conflict = b.engine.manifest.entries[shared]!;
        expect(conflict.conflict, isNotNull);
        expect(b.file(shared).readAsStringSync(), 'beta edit');
        expect(File(conflict.remoteCopy!).readAsStringSync(), 'alpha edit');
        record('conflict preserves both versions');

        // ---- exclusions (#21) ------------------------------------------
        a.file('$prefix/Thumbs.db').writeAsStringSync('cache');
        a.file('$prefix/desktop.ini').writeAsStringSync('[.ShellClassInfo]');
        // A file written with them does arrive, so the passes saw the folder.
        a.file('$prefix/beside.txt').writeAsStringSync('synced');
        await until(
          'the file beside the excluded ones on B',
          () async => b.file('$prefix/beside.txt').existsSync(),
        );
        expect(await remoteHash('$prefix/Thumbs.db'), isNull);
        expect(await remoteHash('$prefix/desktop.ini'), isNull);
        record('Thumbs.db and desktop.ini are not uploaded');

        // ---- Cloud / Local and release ---------------------------------
        b.engine.setRetention('$prefix/Nested', Retention.cloud);
        await b.engine.tick();
        expect(b.file(blobPath).existsSync(), isFalse);
        expect(await remoteHash(blobPath), _digest(blob));
        final released = ownedAllocated(b.engine.tree);
        b.engine.setRetention('$prefix/Nested', Retention.local);
        await b.engine.tick();
        expect(_digest(b.file(blobPath).readAsBytesSync()), _digest(blob));
        expect(ownedAllocated(b.engine.tree), greaterThan(released));
        record('Cloud release frees the bytes; Local brings them back', {
          'allocated_released': released,
        });

        // ---- a file another app holds open (SC-048 F5) ------------------
        final held = '$prefix/held.txt';
        a.file(held).writeAsStringSync('v1');
        await until('v1 on B', () async => b.file(held).existsSync());
        a.file(held).writeAsStringSync('v2');
        final holder = await Process.start(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            r"$f = [IO.File]::Open($env:ANJ_HELD, 'Open', 'ReadWrite', 'None'); "
                r"[Console]::Out.WriteLine('held'); Start-Sleep 20; $f.Close()",
          ],
          environment: {'ANJ_HELD': a.file(held).path},
        );
        await holder.stdout
            .transform(utf8.decoder)
            .firstWhere((line) => line.contains('held'));
        for (var i = 0; i < 15; i++) {
          await a.engine.tick();
          if (a.engine.tree.busy.contains(held)) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        expect(a.engine.tree.busy, contains(held));
        expect(isBusyStatus(a.engine.manifest.entries[held]!.status), isTrue);
        expect(await remoteHash(held), _digest(utf8.encode('v1')));
        holder.kill();
        await holder.exitCode;
        await until(
          'v2 on B once the file is released',
          () async => b.file(held).readAsStringSync() == 'v2',
        );
        expect(await remoteHash(held), _digest(utf8.encode('v2')));
        record(
          'a file held without read sharing is skipped, shown busy, then synced',
        );

        // ---- a Paint save: delete and recreate is an edit (#73 review 6) --
        final picture = '$prefix/paint/pic.png';
        a.engine.tree.ensureDirectory(p.posix.dirname(picture));
        a
            .file(picture)
            .writeAsBytesSync(
              img.encodePng(img.Image(width: 64, height: 64, numChannels: 4)),
              flush: true,
            );
        RemoteItem? pictureItem(List<RemoteItem> items) =>
            items.where((e) => e.path == picture).firstOrNull;
        await until(
          'the picture on B',
          () async => b.file(picture).existsSync(),
        );
        final uploaded = pictureItem(await a.cloud.snapshot())!;
        final before = a.file(picture).readAsBytesSync();
        final paint = await Process.start('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          p.join(Directory.current.path, 'tool', 'windows', 'paint_save.ps1'),
          '-Path',
          a.file(picture).path,
        ]);
        final paintOut = paint.stdout.transform(utf8.decoder).join();
        // Passes keep running while Paint saves, as the watcher would run
        // them, so one may see the file gone before it is back.
        var passes = 0;
        var sawVanish = false;
        var exited = false;
        unawaited(paint.exitCode.then((_) => exited = true));
        while (!exited) {
          await a.engine.tick();
          passes++;
          sawVanish |= a.engine.manifest.operations.values.any(
            (o) => o.kind == 'delete' && o.path == picture,
          );
        }
        expect(await paint.exitCode, 0);
        final after = a.file(picture).readAsBytesSync();
        expect(_digest(after), isNot(_digest(before)), reason: 'Paint saved');
        await until(
          'the Paint save on B',
          () async =>
              _digest(b.file(picture).readAsBytesSync()) == _digest(after),
        );
        final edited = pictureItem(await a.cloud.snapshot())!;
        expect(edited.fileId, uploaded.fileId, reason: 'same server file');
        expect(edited.etag, isNot(uploaded.etag));
        expect(await remoteHash(picture), _digest(after));
        expect(_digest(b.file(picture).readAsBytesSync()), _digest(after));
        record(
          'a Paint save (delete and recreate) is an edit of the same file',
          {
            'paint': (await paintOut).trim(),
            'passes_during_save': passes,
            'a_pass_saw_it_gone': sawVanish,
            'file_id': edited.fileId,
          },
        );

        // ---- the upload limit ------------------------------------------
        final big = '$prefix/too-big.bin';
        final raf = a.file(big).openSync(mode: FileMode.write)
          ..setPositionSync(65 * 1024 * 1024)
          ..writeByteSync(1);
        raf.closeSync();
        for (var i = 0; i < 30; i++) {
          await a.engine.tick();
          if (isSizeRefusal(a.engine.manifest.entries[big]?.status ?? '')) {
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        expect(await remoteHash(big), isNull);
        final bigEntry = a.engine.manifest.entries[big]!;
        expect(isSizeRefusal(bigEntry.status), isTrue, reason: bigEntry.status);
        record('a file over the upload limit stays local with its reason', {
          'status': bigEntry.status,
        });
        a.file(big).deleteSync();

        // ---- names Windows cannot hold (#120), created on the server ----
        final names = config['names_folder'] as String;
        // It existed on the server before this device paired, so it starts
        // Cloud-only (#29); choose Local to materialize what can be.
        await a.engine.tick();
        final listed = (await a.cloud.snapshot())
            .map((e) => e.path)
            .where((path) => path.contains('w4-names'))
            .toList();
        record('the names folder as the gateway lists it', {
          'listed': listed,
          'known': a.engine.manifest.entries.keys
              .where((k) => k.contains('w4-names'))
              .toList(),
        });
        a.engine.setRetention(names, Retention.local);
        await a.engine.tick();
        final remoteNames = (await a.cloud.snapshot())
            .map((e) => e.path)
            .where((path) => path.startsWith('$names/'))
            .toList();
        final onDisk = Directory(p.joinAll([a.root, ...names.split('/')]))
            .listSync()
            .map((e) => p.basename(e.path))
            .toSet();
        final blocked = <String, String>{};
        for (final path in remoteNames) {
          final entry = a.engine.manifest.entries[path];
          blocked[p.posix.relative(path, from: names)] =
              entry?.status ?? 'none';
        }
        final inKept = Directory(
          p.joinAll([a.root, ...names.split('/'), 'Docs']),
        ).listSync().map((e) => p.basename(e.path)).toSet();
        record('remote names Windows cannot hold stay Cloud-only', {
          'remote': remoteNames
              .map((n) => p.posix.relative(n, from: names))
              .toList(),
          'on_disk': onDisk.toList(),
          'in_kept_folder': inKept.toList(),
          'status': blocked,
        });
        // Only the portable names and the byte-wise first of each clash are
        // created; NTFS never merges docs/ into Docs/. A long path is
        // created like any other (row 8), with its note.
        final deep = remoteNames
            .where((path) => path.endsWith('/deep.txt'))
            .firstOrNull;
        expect(onDisk, {
          'A.txt',
          'ok.txt',
          'Docs',
          if (deep != null)
            p.posix.split(p.posix.relative(deep, from: names))[0],
        });
        if (deep != null) {
          final absolute = a.file(deep).path;
          expect(
            a.file(deep).readAsStringSync(),
            'server ${p.posix.relative(deep, from: names)}',
          );
          final row = await projectEntry(
            a.engine,
            a.engine.manifest.entries[deep]!,
          );
          expect(row['presentationNotes'], [longPathNote]);
          record('a path over 259 characters syncs with the note', {
            'length': absolute.length,
            'notes': row['presentationNotes'],
          });
        }
        final optional = {
          'a:b': serverNameNotAllowedStatus,
          '${'n' * 252}.txt': serverNameNotAllowedStatus,
        };
        for (final MapEntry(key: name, value: status) in optional.entries) {
          if (blocked.containsKey(name)) {
            expect(blocked[name], status, reason: name);
          }
        }
        record('row 8 names the server accepted', {
          'present': [
            for (final name in optional.keys)
              if (blocked.containsKey(name))
                name.length > 20 ? '${name.length} units' : name,
          ],
        });
        expect(inKept, {'x.txt'});
        for (final (held, status) in [
          ('CON', serverNameNotAllowedStatus),
          ('nul.txt', serverNameNotAllowedStatus),
          ('x.', serverNameNotAllowedStatus),
          ('trailing ', serverNameNotAllowedStatus),
          ('a.txt', serverNameClashStatus),
          ('docs', serverNameClashStatus),
          ('docs/y.txt', serverFolderNameStatus),
          ('bad.', serverNameNotAllowedStatus),
          ('bad./inside.txt', serverFolderNameStatus),
        ]) {
          expect(blocked[held], status, reason: held);
        }
        // Three passes: the clash winner does not flip.
        final winners = <Set<String>>[];
        for (var i = 0; i < 3; i++) {
          await a.engine.tick();
          winners.add(
            Directory(p.joinAll([a.root, ...names.split('/')]))
                .listSync()
                .map((e) => p.basename(e.path))
                .toSet(),
          );
        }
        expect(winners[1], winners[0]);
        expect(winners[2], winners[0]);
        record('clash winners are stable over three passes', {
          'on_disk': winners[0].toList(),
        });

        File(p.join(signal.path, 'expect.json')).writeAsStringSync(
          jsonEncode({
            'prefix': prefix,
            'files': {
              blobPath: _digest(blob),
              held: _digest(utf8.encode('v2')),
              picture: _digest(a.file(picture).readAsBytesSync()),
            },
          }),
        );
        record('done');
      } finally {
        for (final device in devices) {
          device.close();
        }
      }
    },
    skip: configPath == null
        ? 'Opt-in: set ANJ_W4_CONFIG for a review stack'
        : false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
