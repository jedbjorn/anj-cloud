// Opt-in, against a disposable review stack only (deploy/dev.py project
// anj-cloud-review-<tag>): Linux `move-root` end to end. Skipped unless
// ANJ_MOVE_ROOT_E2E names a private JSON file:
//   {"repo": checkout whose deploy/.local holds the stack and access venv,
//    "project": "anj-cloud-review-<tag>", "port": 18975,
//    "uid": "anj-fixture-alice",
//    "home": a scratch HOME (never the real one), "profile": the profile the
//      scratch installation selected (install --profile-dir), still empty,
//    "command": that installation's stable anj-cloud command,
//    "environment": the scratch installation's HOME and XDG_* variables,
//    "evidence": an existing directory for the results}
//
// A profile paired the way the VM host's production profile was (the folder picker
// chose `<home>/AnJ Cloud`, staging the `.anj-cloud-<profileId>` sibling, no
// desktop shortcut recorded) syncs a few files and quits. The installed
// manager's `move-root` moves the folder with the packaged client; the next
// start (the same controller and worker the app runs) accepts the root as
// matched, keeps every file and etag, and the gateway logs no upload,
// download, deletion, move or folder creation from the device afterwards.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_move.dart';
import 'package:anj_cloud/core/ports/root_placement.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/linux/xdg_root_placement.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  final configPath = Platform.environment['ANJ_MOVE_ROOT_E2E'];
  test(
    'move-root on a paired, synced profile: matched root, nothing transferred',
    () async {
      final config = jsonDecode(
        File(configPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final project = config['project'] as String;
      if (!RegExp(r'^anj-cloud-review-[a-z0-9-]+$').hasMatch(project)) {
        throw StateError('Use a disposable anj-cloud-review-<tag> stack.');
      }
      final uid = config['uid'] as String;
      if (!RegExp(r'^anj-fixture-[a-z0-9-]+$').hasMatch(uid)) {
        throw StateError('Use a synthetic fixture account.');
      }
      final home = Directory(config['home'] as String);
      final realHome = Platform.environment['HOME'];
      if (realHome != null &&
          (p.equals(home.path, realHome) ||
              !p.isWithin(
                p.join(realHome, '.local/share/anj-cloud'),
                home.path,
              ))) {
        throw StateError('Use a scratch HOME under the qualification area.');
      }
      final repo = config['repo'] as String;
      final origin = 'https://127.0.0.1:${config['port']}';
      final profile = Directory(config['profile'] as String);
      final evidence = Directory(config['evidence'] as String);
      final environment = (config['environment'] as Map).cast<String, String>();
      final record = <String, Object?>{'project': project, 'origin': origin};
      void save() => File(
        p.join(evidence.path, 'e2e.json'),
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record));
      final secrets = MemorySecrets();
      // Operator output (an invitation code) is parsed, never logged.
      Future<String> operator(List<String> arguments) async {
        final result = await Process.run(
          '$repo/deploy/.local/access-venv/bin/python',
          [
            '-m',
            'deploy.access_operator',
            '--project',
            project,
            '--port',
            '${config['port']}',
            ...arguments,
          ],
          workingDirectory: repo,
        );
        if (result.exitCode != 0) {
          throw StateError('operator ${arguments.first} failed');
        }
        return result.stdout as String;
      }

      T withStore<T>(T Function(Manifest store) action) {
        final store = Manifest(profile);
        try {
          return action(store);
        } finally {
          store.close();
        }
      }

      Future<void> until(
        ClientController controller,
        bool Function() done,
        String what,
      ) async {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!done()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError(
              'Timed out waiting for $what: ${controller.message}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }

      // 1. Paired with the picker, before spec #34 (no shortcut recorded).
      final before = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: testNativeLibrary,
        placement: const PickerOnlyPlacement(),
      );
      final files = <String, String>{};
      late final String from;
      try {
        await before.initialize();
        expect(before.root, isNull);
        // The folder the user made and chose in the picker.
        Directory(p.join(home.path, 'AnJ Cloud')).createSync();
        await before.configureRoot(p.join(home.path, 'AnJ Cloud'));
        from = before.root!;
        expect(
          from,
          p.join(home.resolveSymbolicLinksSync(), 'AnJ Cloud', 'anj-cloud'),
        );
        withStore((s) => s.deleteSetting('desktopShortcut'));
        final code =
            (jsonDecode(await operator(['invite', uid, '--rights', 'write']))
                    as Map<String, dynamic>)['code']
                as String;
        // This review stack runs no console backend for the automatic
        // approval of a pinned code, so the operator approves the reserved
        // pairing whose fingerprint the device shows (as access_fixture.pair).
        final pairing = before.pair(origin, code);
        final approveBy = DateTime.now().add(const Duration(minutes: 2));
        var approved = false;
        while (!approved && DateTime.now().isBefore(approveBy)) {
          await Future<void>.delayed(const Duration(seconds: 1));
          final shown = before.fingerprint;
          if (shown == null) continue;
          final pending = await operator(['pending']);
          for (final row in (jsonDecode(pending) as List).cast<Map>()) {
            if (row['uid'] == uid &&
                (row['state'] == 'pending' || row['state'] == 'reserved') &&
                row['fingerprint'] == shown) {
              await operator([
                'approve',
                row['id'] as String,
                '--fingerprint',
                shown,
              ]);
              approved = true;
            }
          }
        }
        await pairing;
        expect(before.pairingState, 'paired');
        if (before.firstSyncPending) {
          final listing = await before.firstSyncListing();
          // Everything stays on this device, as on a desktop that synced
          // before the first-sync screen existed (no cloud-only eviction).
          final paths = listing.choices.map((c) => c.path).toList();
          await before.confirmFirstSync(paths, paths.toSet());
        }
        final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
        final random = Random(7);
        files['Documents/move-root-$nonce/a.txt'] = 'alpha $nonce\n';
        files['Documents/move-root-$nonce/deep/b.bin'] = String.fromCharCodes(
          List.generate(65536, (_) => 32 + random.nextInt(90)),
        );
        files['Music/move-root-$nonce.txt'] = 'music $nonce\n';
        for (final entry in files.entries) {
          File(p.join(from, entry.key))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(entry.value, flush: true);
        }
        await until(
          before,
          () => withStore(
            (s) => files.keys.every((path) => s.entries[path]?.etag != null),
          ),
          'the files to upload',
        );
        await until(
          before,
          () => before.status == SyncStatus.upToDate,
          'up to date',
        );
        // One more listing pass (about every 30 s when idle) before quitting.
        await Future<void>.delayed(const Duration(seconds: 35));
      } finally {
        await before.stop();
        before.dispose();
      }
      final deviceId = withStore((s) => s.setting('deviceId'));
      final snapshot = withStore(
        (s) => {
          'root': s.setting('root'),
          'staging': s.setting('staging'),
          'rootIdentity': s.setting('rootIdentity'),
          'desktopShortcut': s.setting('desktopShortcut'),
          'etags': {
            for (final e in s.entries.values)
              if (e.etag != null) e.path: e.etag,
          },
        },
      );
      record['before'] = snapshot;
      record['rootInode'] = _inode(from);
      save();
      expect(
        snapshot['staging'],
        p.join(
          p.dirname(from),
          '.anj-cloud-${withStore((s) => s.setting('profileId'))}',
        ),
      );

      // 2. Quit; the installed manager moves the folder.
      final movedAt = DateTime.now().toUtc();
      final moved = await Process.run(config['command'] as String, [
        'move-root',
      ], environment: environment);
      record['moveRoot'] = {
        'exit': moved.exitCode,
        'stdout': moved.stdout,
        'stderr': moved.stderr,
      };
      save();
      expect(moved.exitCode, 0, reason: '${moved.stderr}');
      final outcome =
          jsonDecode(moved.stdout as String) as Map<String, dynamic>;
      final target = p.join(home.resolveSymbolicLinksSync(), 'anj-cloud');
      expect(outcome['moved'], isTrue);
      expect(outcome['from'], from);
      expect(outcome['to'], target);
      expect(
        outcome['staging'],
        p.join(profile.resolveSymbolicLinksSync(), 'staging'),
      );
      expect(_inode(target), record['rootInode']);
      expect(Directory(p.dirname(from)).existsSync(), isFalse);
      final link = Link(p.join(home.path, 'Desktop', 'AnJ Cloud'));
      expect(link.targetSync(), target);
      expect(withStore((s) => s.setting(rootMoveSetting)), isNull);
      expect(
        withStore((s) => s.setting('rootIdentity')),
        snapshot['rootIdentity'],
      );

      // 3. The next start: matched, nothing to transfer. Two listing passes.
      final after = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: testNativeLibrary,
        placement: XdgRootPlacement(environment: {'HOME': home.path}),
      );
      try {
        await after.initialize();
        expect(after.root, target);
        await until(
          after,
          () => after.status == SyncStatus.upToDate,
          'up to date after the move',
        );
        await Future<void>.delayed(const Duration(seconds: 40));
        expect(after.status, SyncStatus.upToDate, reason: after.message);
        record['afterMessage'] = after.message;
      } finally {
        await after.stop();
        after.dispose();
      }
      final etags = withStore(
        (s) => {
          for (final e in s.entries.values)
            if (e.etag != null) e.path: e.etag,
        },
      );
      record['etagsAfter'] = etags;
      // File etags are unchanged (nothing uploaded); a folder's etag may be
      // filled in or refreshed by a listing, which transfers no content.
      final recorded = (snapshot['etags'] as Map).cast<String, String>();
      for (final path in files.keys) {
        expect(etags[path], recorded[path], reason: path);
      }
      expect(etags.keys, containsAll(recorded.keys));
      expect(
        withStore((s) => s.setting('rootIdentity')),
        snapshot['rootIdentity'],
      );
      for (final entry in files.entries) {
        expect(File(p.join(target, entry.key)).readAsStringSync(), entry.value);
      }

      // The gateway's own request log for this device since the move.
      final logs = await Process.run('docker', [
        'logs',
        '--since',
        movedAt.toIso8601String(),
        '$project-access-1',
      ]);
      final requests = <String, int>{};
      for (final line in '${logs.stdout}\n${logs.stderr}'.split('\n')) {
        if (!line.startsWith('{')) continue;
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (event['event'] != 'request' || event['device'] != deviceId) {
          continue;
        }
        final key = '${event['method']} ${event['route']} ${event['status']}';
        requests[key] = (requests[key] ?? 0) + 1;
      }
      record['gatewayRequestsSinceMove'] = requests;
      record['deviceId'] = deviceId;
      save();
      expect(requests, isNotEmpty, reason: 'the device listed after the move');
      final changing = requests.keys.where(
        (k) =>
            RegExp(r'^(PUT|DELETE|MOVE|MKCOL|COPY|PROPPATCH|LOCK) ')
                .hasMatch(k) ||
            k.startsWith('GET dav'),
      );
      expect(changing, isEmpty, reason: '$requests');
      record['pass'] = true;
      save();
    },
    skip: configPath == null ? 'opt-in: set ANJ_MOVE_ROOT_E2E' : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

int _inode(String path) => int.parse(
  (Process.runSync('stat', ['-c', '%i', path]).stdout as String).trim(),
);
