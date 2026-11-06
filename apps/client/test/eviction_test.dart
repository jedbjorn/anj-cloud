import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import '../tool/eviction_fixture.dart' show ownedAllocated;
import 'fakes.dart';
import 'test_platform.dart';

class _Cloud extends FakeCloud {
  bool deny = false;
  bool corrupt = false;
  void Function()? afterDownload;
  void Function()? afterSnapshot;
  @override
  Future<List<RemoteItem>> snapshot() async {
    final result = await super.snapshot();
    afterSnapshot?.call();
    return result;
  }

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async {
    if (deny) {
      throw const CloudFailure('device revoked', status: 403);
    }
    await super.download(path, target, etag: etag);
    afterDownload?.call();
    if (corrupt) {
      await target.writeAsString('wrong bytes', flush: true);
    }
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-eviction-test-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'guard-test', NativeRootFs());
    // An ordinary folder: Documents, Music and Videos are never Cloud-only
    // (spec #34 P7).
    tree.ensureDirectory('Library');
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = _Cloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local() => File('${tree.root.path}/Library/blob.bin');
  Future<void> baseline({bool large = false}) async {
    final random = Random(315);
    local().writeAsBytesSync(
      large
          ? List.generate(4 * 1024 * 1024, (_) => random.nextInt(256))
          : 'original bytes'.codeUnits,
      flush: true,
    );
    await engine.tick();
    engine.setRetention('Library', Retention.cloud);
  }

  test(
    'actual owned allocated bytes fall and remote hash remains intact',
    () async {
      await baseline(large: true);
      final hash = sha256
          .convert(cloud.files['Library/blob.bin']!)
          .toString();
      final before = ownedAllocated(tree);
      expect(before, greaterThan(0));
      await engine.tick();
      final after = ownedAllocated(tree);
      expect(after, lessThan(before));
      expect(after, 0);
      expect(local().existsSync(), isFalse);
      expect(
        sha256.convert(cloud.files['Library/blob.bin']!).toString(),
        hash,
      );
      expect(store.entries['Library/blob.bin']!.status, 'cloud-only');
      await engine.tick();
      expect(cloud.deletes, 0);
    },
  );
  for (final mode in [FileMode.read, FileMode.append]) {
    test(
      'an existing ${mode == FileMode.read ? 'reader' : 'writer'} refuses release until closed',
      () async {
        await baseline();
        final held = local().openSync(mode: mode);
        try {
          await engine.tick();
          expect(local().existsSync(), isTrue);
          expect(
            store.entries['Library/blob.bin']!.status,
            contains('pending'),
          );
        } finally {
          held.closeSync();
        }
        await engine.tick();
        expect(local().existsSync(), isFalse);
        expect(cloud.deletes, 0);
      },
    );
  }
  test('unknown hardlink and legacy staging remain untouched', () async {
    await baseline();
    final alias = File('${fixture.path}/unknown-hardlink');
    final linked = await Process.run('ln', [local().path, alias.path]);
    expect(linked.exitCode, 0);
    await engine.tick();
    expect(local().existsSync(), isTrue);
    expect(alias.readAsStringSync(), 'original bytes');
    alias.deleteSync();
    final legacy = File('${tree.staging.path}/legacy-unowned')
      ..writeAsStringSync('retained unknown data');
    await engine.tick();
    expect(local().existsSync(), isTrue);
    expect(legacy.readAsStringSync(), 'retained unknown data');
    expect(store.entries['Library/blob.bin']!.status, contains('untracked'));
  });
  test('remote proof refusal or mismatched bytes retains the complete local source', () async {
    await baseline();
    cloud.deny = true;
    await engine.tick();
    expect(local().readAsStringSync(), 'original bytes');
    cloud.deny = false;
    cloud.corrupt = true;
    await engine.tick();
    expect(local().readAsStringSync(), 'original bytes');
    expect(store.entries['Library/blob.bin']!.status, contains('differ'));
  });
  test('dirty failed upload cannot release its only local bytes', () async {
    await baseline();
    local().writeAsStringSync('pending local edit');
    cloud.failUpload = true;
    await engine.tick();
    expect(local().readAsStringSync(), 'pending local edit');
    expect(
      String.fromCharCodes(cloud.files['Library/blob.bin']!),
      'original bytes',
    );
  });
  for (final phase in [
    'before-quarantine',
    'quarantined',
    'before-final-unlink',
  ]) {
    test(
      'writer at $phase breaks the guard and retains recoverable bytes',
      () async {
        await baseline();
        final trigger = File('${fixture.path}/trigger');
        final attempted = File('${fixture.path}/attempted');
        final child = await Process.start('python3', [
          '-c',
          'import os,sys,time; p=sys.argv[1]; a=sys.argv[2]\nwhile not os.path.exists(p): time.sleep(.002)\npath=open(p).read();open(a,"w").write("attempting");f=os.open(path,os.O_WRONLY|os.O_TRUNC);os.write(f,b"raced writer bytes");os.close(f)',
          trigger.path,
          attempted.path,
        ]);
        var broken = false;
        engine.evictions.barrier = (point, op, fd) {
          if (point != phase) {
            return;
          }
          trigger.writeAsStringSync(
            point == 'before-quarantine' ? local().path : op.staged!,
          );
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (DateTime.now().isBefore(deadline)) {
            try {
              engine.artifacts.native.valid(fd);
            } on FileSystemException {
              broken = true;
              break;
            }
            sleep(const Duration(milliseconds: 1));
          }
          if (!broken) {
            throw StateError('Writer did not trigger a visible lease break.');
          }
        };
        await engine.tick();
        expect(broken, isTrue);
        expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
        engine.evictions.barrier = null;
        if (phase == 'before-quarantine') {
          expect(local().readAsStringSync(), 'raced writer bytes');
        } else {
          await engine.tick();
          final entry = store.entries['Library/blob.bin']!;
          expect(entry.conflict, isNotNull);
          expect(
            entry.preservedCopies
                .map((path) => File(path).readAsStringSync())
                .contains('raced writer bytes'),
            isTrue,
          );
          expect(await engine.canRecoverLocalVariants(entry.path), isTrue);
        }
        expect(cloud.deletes, 0);
        expect(
          String.fromCharCodes(cloud.files['Library/blob.bin']!),
          'original bytes',
        );
      },
    );
  }
  for (final phase in [
    'after-rename-before-db',
    'quarantined',
    'after-final-unlink',
  ]) {
    test(
      'real process restart recovers crash at $phase without remote deletion',
      () async {
        final path = '${fixture.path}/crash-$phase';
        final dart = testDartExecutable;
        final crashed = await Process.run(dart, [
          'run',
          'tool/eviction_fixture.dart',
          path,
          phase,
        ]);
        expect(
          crashed.exitCode,
          86,
          reason: '${crashed.stdout}\n${crashed.stderr}',
        );
        final resumed = await Process.run(dart, [
          'run',
          'tool/eviction_fixture.dart',
          path,
          'resume',
        ]);
        expect(
          resumed.exitCode,
          0,
          reason: '${resumed.stdout}\n${resumed.stderr}',
        );
        expect(
          File('$path/files/anj-cloud/Library/blob.bin').existsSync(),
          isFalse,
        );
        expect(File('$path/cloud/Library/blob.bin').existsSync(), isTrue);
        final check = Manifest(Directory('$path/profile'));
        try {
          expect(check.entries['Library/blob.bin']!.status, 'cloud-only');
          expect(
            check.operations.values.any((o) => o.kind == 'evict'),
            isFalse,
          );
        } finally {
          check.close();
        }
      },
    );
  }
  test(
    'root move and replacement during awaited remote proof preserve both trees',
    () async {
      await baseline();
      final moved = '${fixture.path}/moved-root';
      cloud.afterDownload = () {
        tree.root.renameSync(moved);
        tree.root.createSync();
        File('${tree.root.path}/replacement')
            .writeAsStringSync('replacement root bytes');
      };
      await engine.tick();
      expect(
        File('$moved/Library/blob.bin').readAsStringSync(),
        'original bytes',
      );
      expect(
        File('${tree.root.path}/replacement').readAsStringSync(),
        'replacement root bytes',
      );
      expect(engine.message, contains('Paused'));
      expect(cloud.deletes, 0);
      await engine.tick();
      expect(engine.message, contains('Paused'));
      expect(cloud.deletes, 0);
    },
  );
  test(
    'root move after quarantine retains the exact private recovery bytes',
    () async {
      await baseline();
      String? held;
      final moved = '${fixture.path}/moved-after-quarantine';
      engine.evictions.barrier = (phase, op, fd) {
        if (phase == 'quarantined') {
          held = op.staged;
          tree.root.renameSync(moved);
          tree.root.createSync();
          File('${tree.root.path}/replacement')
              .writeAsStringSync('untouched replacement');
        }
      };
      await engine.tick();
      expect(engine.message, contains('Paused'));
      expect(File(held!).readAsStringSync(), 'original bytes');
      expect(
        File('${tree.root.path}/replacement').readAsStringSync(),
        'untouched replacement',
      );
      expect(cloud.deletes, 0);
      expect(store.operations.values.any((op) => op.kind == 'evict'), isTrue);
    },
  );
  test(
    'root move during remote snapshot pauses before any file mutation',
    () async {
      await baseline();
      local().writeAsStringSync('pending local edit');
      cloud.afterSnapshot = () {
        tree.root.renameSync('${fixture.path}/moved-during-list');
        tree.root.createSync();
      };
      await engine.tick();
      expect(engine.message, contains('Paused'));
      expect(
        String.fromCharCodes(cloud.files['Library/blob.bin']!),
        'original bytes',
      );
      expect(
        File('${fixture.path}/moved-during-list/Library/blob.bin')
            .readAsStringSync(),
        'pending local edit',
      );
      expect(cloud.deletes, 0);
    },
  );
}
