@TestOn('windows')
library;

// Opt-in, against a disposable review stack only: run by deploy/windows_sync_fixture.py, which owns the stack
// (anj-cloud-review-<tag>), the reverse forward that makes the stack's
// https://127.0.0.1:<port> reachable from this guest, the invitations and
// the operator approvals. Skipped unless ANJ_W4_CONFIG names its JSON:
//   {"origin", "ca", "other_origin", "code_a", "qr_b", "denied_code",
//    "names_folder", "cloud_moves", "work" (absent), "signal" (handshake
//    directory)}
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
import 'fakes.dart' show FakeCloud;
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
        // The code carries the CA pin; this stack has no console
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
        // A code tried at a server with another CA, and a code the server
        // never issued (or denied): refused before any file access.
        final probe = await controllerFor('refused');
        // Invitation A, which the stack would accept, tried at a server
        // whose CA the code does not pin: only the device's check of the pin
        // can refuse it, with that reason. The driver checks that server
        // saw nothing but the request for its CA; the code pairs below.
        final otherOrigin = config['other_origin'] as String;
        Object? pinRefusal;
        try {
          await probe.pair(otherOrigin, config['code_a'] as String);
        } catch (error) {
          pinRefusal = error;
        }
        expect(
          pinRefusal,
          isA<PairingRefused>().having(
            (e) => e.message,
            'message',
            notThisServer,
          ),
        );
        expect(probe.pairingState, isNot('paired'));
        expect(probe.pairingState, isNot('pending'));
        record('pairing refused: a real code at a server with another CA', {
          'message': (pinRefusal as PairingRefused).message,
        });
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
        // from a QR image file (the pairing dialog has no image entry; the
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
        // The server (Nextcloud on local storage) keeps a file's ETag when
        // the file is overwritten again within the same second: the second
        // version is then invisible to every device that saw the first.
        // That is the server's behaviour, not this client's, and a person
        // does not edit a file twice in one second from two devices; this
        // run does, so it lets the second pass before it overwrites a file
        // that has just synced.
        Future<void> nextSecond() =>
            Future<void>.delayed(const Duration(milliseconds: 1200));

        // For the evidence of a step that times out: what was noted
        // before it.
        var noted = '';
        Future<int> until(String what, Future<bool> Function() done) async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          for (var rounds = 1; ; rounds++) {
            await cycles();
            if (await done()) return rounds;
            if (DateTime.now().isAfter(deadline)) {
              // What each device and the server hold, for the evidence.
              String rows(_Device d) => [
                for (final e in d.engine.manifest.entries.values)
                  if (e.path.startsWith(prefix))
                    '${e.path}: ${e.status}'
                        '${e.conflict == null ? '' : ' [${e.conflict}]'}',
              ].join('; ');
              String queued(_Device d) => [
                for (final o in d.engine.manifest.operations.values)
                  if (o.path.startsWith(prefix)) '${o.kind} ${o.path}',
              ].join('; ');
              // Each file as the disk, a fresh stat and the row see it.
              String files(_Device d) => [
                for (final e in d.engine.manifest.entries.values)
                  if (e.path.startsWith(prefix) &&
                      e.kind == ItemKind.file &&
                      d.file(e.path).existsSync())
                    () {
                      final stat = d.engine.tree.statItem(e.path);
                      final bytes = d.file(e.path).readAsBytesSync();
                      return '${p.posix.basename(e.path)} disk '
                          '${bytes.length}b ${_digest(bytes).substring(0, 8)} '
                          'stat ${stat?.size}b links ${stat?.links} '
                          'stamp ${stat?.scanStamp} '
                          'row base ${e.baselineHash?.substring(0, 8)} '
                          'etag ${e.etag}';
                    }(),
              ].join('; ');
              String mode(_Device d) =>
                  'eventDriven ${d.engine.eventDriven} watcher '
                  '${d.engine.watcher?.active} fullScans '
                  '${d.engine.fullScans} note ${d.engine.localNote} lastPass '
                  'full ${d.engine.lastPass?.full}';
              final listed = [
                for (final item in await a.cloud.snapshot())
                  if (item.path.startsWith(prefix)) '${item.path}@${item.etag}',
              ].join('; ');
              final listedByB = [
                for (final item in await b.cloud.snapshot())
                  if (item.path.startsWith(prefix)) '${item.path}@${item.etag}',
              ].join('; ');
              // The bytes the server serves for each small file.
              final served = <String>[];
              for (final item in await a.cloud.snapshot()) {
                if (!item.path.startsWith(prefix) ||
                    item.kind != ItemKind.file ||
                    item.size > 1024) {
                  continue;
                }
                final target = File(
                  p.join(work.path, 'diag-${Random().nextInt(1 << 30)}'),
                );
                await a.cloud.download(item.path, target, etag: item.etag);
                served.add(
                  '${p.posix.basename(item.path)} '
                  '${_digest(target.readAsBytesSync()).substring(0, 8)}',
                );
                target.deleteSync();
              }
              throw StateError(
                'Not reached within 90 s: $what\n'
                'noted before: $noted\n'
                'A (${a.engine.message}; busy ${a.engine.tree.busy}): '
                '${rows(a)}\nA work: ${queued(a)}\n'
                'B (${b.engine.message}; busy ${b.engine.tree.busy}): '
                '${rows(b)}\nB work: ${queued(b)}\nserver: $listed\n'
                'server as B lists it: $listedByB\n'
                'server bytes: ${served.join('; ')}\n'
                'A files: ${files(a)}\nA mode: ${mode(a)}\n'
                'B files: ${files(b)}\nB mode: ${mode(b)}',
              );
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
        final listedBeforeEdit = (await b.cloud.snapshot())
            .where((e) => e.path == '$prefix/from-b.txt')
            .map((e) => '${e.etag} ${e.size}b modified ${e.modified}')
            .join();
        noted =
            'from-b.txt before the edit: listed $listedBeforeEdit; '
            'A row ${a.engine.manifest.entries['$prefix/from-b.txt']?.etag}; '
            'B row ${b.engine.manifest.entries['$prefix/from-b.txt']?.etag}; '
            'edit written at ${DateTime.now().toUtc().toIso8601String()}';
        await nextSecond();
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
        await nextSecond();
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

        // ---- exclusions ------------------------------------------------
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

        // ---- a file another app holds open -----------------------------
        final held = '$prefix/held.txt';
        a.file(held).writeAsStringSync('v1');
        await until('v1 on B', () async => b.file(held).existsSync());
        await nextSecond();
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
        // Released, and nothing writes to it again: only the engine's own
        // reading of the busy files again brings it up (no full scan).
        final fullScansAtRelease = a.engine.fullScans;
        final releasedAt = DateTime.now();
        final roundsToSync = await until(
          'v2 on B once the file is released',
          () async => b.file(held).readAsStringSync() == 'v2',
        );
        expect(await remoteHash(held), _digest(utf8.encode('v2')));
        expect(a.engine.tree.busy, isEmpty);
        record(
          'a file held without read sharing is skipped, shown busy, then synced',
          {
            'released_with_no_new_write': true,
            'seconds_to_sync': DateTime.now().difference(releasedAt).inSeconds,
            'rounds': roundsToSync,
            'full_scans_meanwhile': a.engine.fullScans - fullScansAtRelease,
            'event_driven': a.engine.eventDriven,
          },
        );

        // ---- a Paint save: delete and recreate is an edit ----------------
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

        // ---- names Windows cannot hold, created on the server -----------
        final names = config['names_folder'] as String;
        // It existed on the server before this device paired, so it starts
        // Cloud-only; choose Local to materialize what can be.
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
        final cloudMoves = [
          for (final pair in config['cloud_moves'] as List)
            ((pair as List)[0] as String, pair[1] as String),
        ];
        expect(onDisk, {
          'A.txt',
          'ok.txt',
          'Docs',
          // Synced now; moved in the cloud further down.
          for (final (source, _) in cloudMoves) source,
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

        // ---- moves made in the cloud to names this device cannot hold ----
        // The driver makes them in Nextcloud, as another device's renames
        // would arrive: to a name Windows refuses, onto a case sibling of a
        // file here, and into the folder held back as the clash loser. Each
        // item must stay where it is, with its reason; nothing may land in
        // the kept sibling folder, and nothing may be sent to the server.
        Set<String> namesOnDisk() =>
            Directory(p.joinAll([a.root, ...names.split('/')]))
                .listSync()
                .map((e) => p.basename(e.path))
                .toSet();
        Set<String> keptFolder() =>
            Directory(p.joinAll([a.root, ...names.split('/'), 'Docs']))
                .listSync()
                .map((e) => p.basename(e.path))
                .toSet();
        final beforeMoves = namesOnDisk();
        for (final (source, _) in cloudMoves) {
          expect(a.file('$names/$source').readAsStringSync(), 'server $source');
        }
        File(p.join(signal.path, 'moves-wanted.json'))
            .writeAsStringSync(jsonEncode({'wanted': cloudMoves.length}));
        final movesDone = File(p.join(signal.path, 'moves-done.json'));
        for (var i = 0; i < 120 && !movesDone.existsSync(); i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        expect(movesDone.existsSync(), isTrue, reason: 'the driver moved them');
        final listedAfterMoves = <Set<String>>[];
        for (var pass = 0; pass < 6; pass++) {
          await a.engine.tick();
          await Future<void>.delayed(const Duration(seconds: 1));
          listedAfterMoves.add(namesOnDisk());
          expect(namesOnDisk(), beforeMoves, reason: 'pass $pass');
          expect(keptFolder(), {'x.txt'}, reason: 'pass $pass');
        }
        final moveStatus = <String, String>{};
        for (final (source, target) in cloudMoves) {
          expect(
            a.file('$names/$source').readAsStringSync(),
            'server $source',
            reason: 'still here, untouched',
          );
          moveStatus[target] =
              a.engine.manifest.entries['$names/$source']?.status ?? 'none';
        }
        expect(moveStatus, {
          'moved.': movedNameNotAllowedStatus,
          'OK.txt': movedNameClashStatus,
          'docs/move-into.txt': movedFolderNameStatus,
        });
        expect([
          for (final o in a.engine.manifest.operations.values)
            if (o.path.startsWith('$names/') &&
                const {'delete', 'move', 'upload'}.contains(o.kind))
              '${o.kind} ${o.path}',
        ], isEmpty);
        final afterMoves = (await a.cloud.snapshot())
            .map((e) => e.path)
            .where((path) => path.startsWith('$names/'))
            .toSet();
        for (final (source, target) in cloudMoves) {
          expect(afterMoves, contains('$names/$target'));
          expect(afterMoves, isNot(contains('$names/$source')));
        }
        expect(
          afterMoves,
          containsAll(['$names/Docs/x.txt', '$names/docs/y.txt']),
        );
        record('cloud moves to names this device cannot hold keep the items', {
          'status': moveStatus,
          'on_disk': namesOnDisk().toList(),
          'in_kept_folder': keptFolder().toList(),
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
        // ---- a busy file released with no new write, watcher-driven -----
        // A third root with the real Windows watcher and an in-memory cloud:
        // passes read only what the watcher reported (the two devices above
        // run without a watcher and scan everything each pass). The file is
        // edited, held without read sharing, then released and never
        // written again. First with the engine's own retry far away, to see
        // whether Windows reports the close by itself; then with the retry.
        final watchedParent = Directory(p.join(work.path, 'files-watched'))
          ..createSync();
        final watchedTree = RootTree.setup(
          watchedParent.path,
          'watched',
          windowsRootFilesystem(),
        );
        final watchedStore = Manifest(
          Directory(p.join(work.path, 'profile-watched')),
        )..setSetting('retention', 'local');
        final watchedCloud = FakeCloud();
        final watched = SyncEngine(watchedStore, watchedTree, watchedCloud);
        try {
          await watched.startWatching();
          const busyPath = 'Documents/open.txt';
          final busyFile = File(
            p.joinAll([watchedTree.root.path, ...busyPath.split('/')]),
          )..parent.createSync(recursive: true);
          String? uploaded() => watchedCloud.files[busyPath] == null
              ? null
              : utf8.decode(watchedCloud.files[busyPath]!);
          Future<bool> passes(int seconds, bool Function() done) async {
            final end = DateTime.now().add(Duration(seconds: seconds));
            while (!done()) {
              if (DateTime.now().isAfter(end)) return false;
              await Future<void>.delayed(const Duration(milliseconds: 500));
              await watched.tick();
            }
            return true;
          }

          busyFile.writeAsStringSync('v1');
          expect(await passes(60, () => uploaded() == 'v1'), isTrue);
          // Settled: ordinary passes are partial from here on.
          for (var i = 0; i < 6; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await watched.tick();
          }
          expect(watched.eventDriven, isTrue);
          busyFile.writeAsStringSync('v2');
          final busyHolder = await Process.start(
            'powershell',
            [
              '-NoProfile',
              '-Command',
              r"$f = [IO.File]::Open($env:ANJ_HELD, 'Open', 'ReadWrite', 'None'); "
                  r"[Console]::Out.WriteLine('held'); Start-Sleep 60; $f.Close()",
            ],
            environment: {'ANJ_HELD': busyFile.path},
          );
          await busyHolder.stdout
              .transform(utf8.decoder)
              .firstWhere((line) => line.contains('held'));
          expect(
            await passes(60, () => watchedTree.busy.contains(busyPath)),
            isTrue,
            reason: 'the sharing violation reaches the scan as busy',
          );
          expect(isBusyStatus(watchedStore.entries[busyPath]!.status), isTrue);
          expect(uploaded(), 'v1');
          // Released; nothing writes to the file again.
          watched.busyRetryInterval = const Duration(hours: 1);
          final scansAtRelease = watched.fullScans;
          busyHolder.kill();
          await busyHolder.exitCode;
          final byEvent = await passes(8, () => uploaded() == 'v2');
          var byRetry = false;
          if (!byEvent) {
            watched.busyRetryInterval = const Duration(seconds: 2);
            byRetry = await passes(30, () => uploaded() == 'v2');
          }
          expect(uploaded(), 'v2');
          expect(watchedTree.busy, isEmpty);
          expect(isBusyStatus(watchedStore.entries[busyPath]!.status), isFalse);
          expect(
            watched.fullScans,
            scansAtRelease,
            reason: 'no full scan did it',
          );
          record(
            'watcher-driven: a busy file released with no new write syncs',
            {
              'windows_reported_the_close': byEvent,
              'synced_by_the_retry': byRetry,
              'full_scans_meanwhile': watched.fullScans - scansAtRelease,
              'event_driven': watched.eventDriven,
            },
          );
        } finally {
          watched.close();
        }

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
