import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/evictions.dart' show openedCopyKept;
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import '../tool/eviction_fixture.dart' show ownedAllocated;
import 'fakes.dart';
import 'test_platform.dart';

void main() {
  const path = 'Library/edit.txt';
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('anj-edit-completion-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'editing', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'cloud');
    cloud = FakeCloud()..put(path, 'initial bytes');
    engine = SyncEngine(store, tree, cloud);
    await engine.tick();
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File root() => File('${tree.root.path}/$path');
  List<Map<String, dynamic>> preview() => engine
      .workingCopies(path)
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  Future<void> finish() async {
    engine.editing.request(path, preview());
    await engine.tick();
  }

  test(
    'saved versions upload repeatedly before Finish; policy stays Cloud',
    () async {
      final work = File(await engine.openFile(path));
      final editor = work.openSync(mode: FileMode.append);
      try {
        editor.writeStringSync(' saved one');
        editor.flushSync();
        await engine.tick();
        expect(
          String.fromCharCodes(cloud.files[path]!),
          'initial bytes saved one',
        );
        editor.writeStringSync(' saved two');
        editor.flushSync();
        await engine.tick();
        expect(
          String.fromCharCodes(cloud.files[path]!),
          'initial bytes saved one saved two',
        );
        expect(engine.retention(path), Retention.cloud);
        expect(root().existsSync(), false);
        expect(engine.workingCopies(path), hasLength(1));
      } finally {
        editor.closeSync();
      }
      final before = ownedAllocated(tree);
      await finish();
      expect(engine.workingCopies(path), isEmpty);
      expect(root().existsSync(), false);
      expect(engine.retention(path), Retention.cloud);
      expect(ownedAllocated(tree), lessThan(before));
      expect(engine.localArtifacts(path)['count'], 0);
      expect(ownedAllocated(tree), 0);
      expect(cloud.deletes, 0);
    },
  );

  test(
    'unchanged Cloud copy fully releases; repeated Finish is harmless',
    () async {
      await engine.openFile(path);
      expect(ownedAllocated(tree), greaterThan(0));
      await finish();
      expect(engine.workingCopies(path), isEmpty);
      expect(ownedAllocated(tree), 0);
      await finish();
      await engine.tick();
      expect(engine.editing.requests, isEmpty);
      expect(String.fromCharCodes(cloud.files[path]!), 'initial bytes');
    },
  );

  test(
    'normal atomic save has explicit durable ownership transition',
    () async {
      final work = File(await engine.openFile(path));
      final old = engine.artifacts.record(work)!.data['identity'];
      final replacement = File('${work.path}.new')
        ..writeAsStringSync('atomic saved edit', flush: true);
      replacement.renameSync(work.path);
      await engine.tick();
      expect(String.fromCharCodes(cloud.files[path]!), 'atomic saved edit');
      expect(engine.artifacts.record(work)!.data['identity'], old);
      await finish();
      expect(engine.workingCopies(path), isEmpty);
      expect(root().existsSync(), false);
      final transition = store.operations.values.singleWhere(
        (o) => o.kind == 'edit-ownership',
      );
      expect(transition.phase, 'adopted');
      expect(transition.data['previousIdentity'], old);
      expect(transition.data['confirmedIdentity'], isNot(old));
    },
  );

  for (final replace in [false, true]) {
    test('changed since preview ($replace) needs fresh confirmation', () async {
      final work = File(await engine.openFile(path));
      final shown = preview();
      if (replace) {
        final replacement = File('${work.path}.new')
          ..writeAsStringSync('later saved edit', flush: true);
        replacement.renameSync(work.path);
      } else {
        work.writeAsStringSync('later saved edit', flush: true);
      }
      expect(
        () => engine.editing.request(path, shown),
        throwsA(isA<FileSystemException>()),
      );
      expect(work.readAsStringSync(), 'later saved edit');
      await engine.tick();
      expect(engine.workingCopies(path), hasLength(1));
      expect(String.fromCharCodes(cloud.files[path]!), 'later saved edit');
      await finish();
      expect(engine.workingCopies(path), isEmpty);
    });
  }

  /// A saved working copy synchronizes without a pending error (PR #60 D1:
  /// with rename installs the staged upload is gone after it is installed).
  void expectNoPresentationError() {
    expect([
      for (final op in store.operations.values)
        if (op.data['presentationError'] != null) op.data['presentationError'],
    ], isEmpty);
    expect(
      store.entries[path]!.status,
      isNot(startsWith('Working edit pending')),
    );
  }

  test(
    'Local completion preserves required current root and closes session',
    () async {
      engine.setRetention('Library', Retention.local);
      await engine.tick();
      final work = File(await engine.openFile(path))
        ..writeAsStringSync('local edit', flush: true);
      await engine.tick();
      expect(root().readAsStringSync(), 'local edit');
      expectNoPresentationError();
      await finish();
      expectNoPresentationError();
      expect(engine.workingCopies(path), isEmpty);
      expect(root().readAsStringSync(), 'local edit');
      expect(engine.retention(path), Retention.local);
      expect(String.fromCharCodes(cloud.files[path]!), 'local edit');
      expect(work.existsSync(), false);
    },
  );

  test('later Open is outside earlier exact confirmation', () async {
    await engine.openFile(path);
    engine.editing.request(path, preview());
    final later = File(await engine.openFile(path));
    await engine.tick();
    expect(engine.workingCopies(path), hasLength(1));
    expect(engine.workingCopies(path).single['path'], later.path);
    expect(later.readAsStringSync(), 'initial bytes');
    // Decisions #183/#184: the later copy is a new one (a copy confirmed for
    // Finish editing is never handed out again). Unchanged, it is not an edit
    // and pins nothing; opened outside the documents provider, it is kept
    // until the user removes it, never released automatically.
    expect(engine.workingCopies(path).single['edited'], isFalse);
    expect(store.entries[path]!.status, openedCopyKept);
  });

  test('offline request remains durable and uploads before cleanup', () async {
    final work = File(await engine.openFile(path))
      ..writeAsStringSync('offline edit', flush: true);
    engine.editing.request(path, preview());
    cloud.online = false;
    await engine.tick();
    expect(work.readAsStringSync(), 'offline edit');
    expect(engine.editing.requests, hasLength(1));
    cloud.online = true;
    await engine.tick();
    expect(engine.workingCopies(path), isEmpty);
    expect(String.fromCharCodes(cloud.files[path]!), 'offline edit');
    expectNoPresentationError();
  });

  test('busy copy retries without allocating more proofs', () async {
    final work = File(await engine.openFile(path));
    engine.editing.request(path, preview());
    final held = work.openSync();
    try {
      await engine.tick();
      expect(work.existsSync(), true);
      final count = engine.localArtifacts(path)['count'];
      await engine.tick();
      expect(engine.localArtifacts(path)['count'], count);
      expect(store.entries[path]!.status, contains('Finish pending'));
    } finally {
      held.closeSync();
    }
    await engine.tick();
    expect(engine.workingCopies(path), isEmpty);
  });

  test('multiple divergent editor versions remain recoverable', () async {
    // One unchanged copy per version is handed out (decision #184): the
    // second editor session starts once the first copy is already changed.
    final first = File(await engine.openFile(path))
      ..writeAsStringSync('first edit');
    final second = File(await engine.openFile(path));
    expect(second.path, isNot(first.path));
    second.writeAsStringSync('second edit');
    engine.editing.request(path, preview());
    await engine.tick();
    expect(store.entries[path]!.conflict, isNotNull);
    expect(first.readAsStringSync(), 'first edit');
    expect(second.readAsStringSync(), 'second edit');
    expect(engine.workingCopies(path), hasLength(2));
    expect(cloud.deletes, 0);
  });

  test('symlink and unknown hardlink previews refuse adoption', () async {
    final work = File(await engine.openFile(path));
    final alias = File('${fixture.path}/alias');
    expect((await Process.run('ln', [work.path, alias.path])).exitCode, 0);
    expect(preview().single['preview'], isNull);
    expect(
      () => engine.editing.request(path, preview()),
      throwsA(isA<FileSystemException>()),
    );
    alias.deleteSync();
    work.deleteSync();
    final outside = File('${fixture.path}/outside')
      ..writeAsStringSync('private outside');
    Link(work.path).createSync(outside.path);
    expect(preview().single['preview'], isNull);
    expect(outside.readAsStringSync(), 'private outside');
  });
  test(
    'new confirmation supersedes stale atomic ownership authorization',
    () async {
      final work = File(await engine.openFile(path));
      (File(
        '${work.path}.new',
      )..writeAsStringSync('first replacement')).renameSync(work.path);
      engine.editing.request(path, preview());
      cloud.online = false;
      await engine.tick();
      (File(
        '${work.path}.new',
      )..writeAsStringSync('second replacement')).renameSync(work.path);
      engine.editing.request(path, preview());
      cloud.online = true;
      await engine.tick();
      expect(engine.workingCopies(path), isEmpty);
      final transitions = store.operations.values
          .where((o) => o.kind == 'edit-ownership')
          .toList();
      expect(transitions.where((o) => o.phase == 'superseded'), hasLength(1));
      expect(transitions.where((o) => o.phase == 'adopted'), hasLength(1));
      expect(String.fromCharCodes(cloud.files[path]!), 'second replacement');
    },
  );

  test('later change after accepted confirmation does not authorize retry adoption', () async {
    final work = File(await engine.openFile(path));
    engine.editing.request(path, preview());
    work.writeAsStringSync('later edit after confirmation', flush: true);
    await engine.tick();
    expect(engine.workingCopies(path), hasLength(1));
    expect(store.entries[path]!.status, contains('preview'));
    await engine.tick();
    expect(engine.workingCopies(path), hasLength(1));
    await finish();
    expect(engine.workingCopies(path), isEmpty);
  });

  test(
    'request prevalidates all previews before any ownership authorization',
    () async {
      final first = File(await engine.openFile(path));
      (File(
        '${first.path}.new',
      )..writeAsStringSync('same bytes')).renameSync(first.path);
      // Changed, so the second Open is a second copy (decision #184).
      final second = File(await engine.openFile(path));
      expect(second.path, isNot(first.path));
      final shown = preview();
      second.writeAsStringSync('changed after preview');
      expect(
        () => engine.editing.request(path, shown),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        store.operations.values.where((o) => o.kind == 'edit-ownership'),
        isEmpty,
      );
      expect(engine.editing.requests, isEmpty);
    },
  );

  for (final phase in [
    'after-rename-before-receipt',
    'after-rename-before-db',
    'after-unlink-before-db',
  ]) {
    test('real process crash recovery at $phase', () async {
      final target = '${fixture.path}/crash-$phase';
      final dart = testDartExecutable;
      final crashed = await Process.run(dart, [
        'run',
        'tool/edit_completion_fixture.dart',
        target,
        phase,
      ]);
      expect(
        crashed.exitCode,
        86,
        reason: '${crashed.stdout} ${crashed.stderr}',
      );
      final resumed = await Process.run(dart, [
        'run',
        'tool/edit_completion_fixture.dart',
        target,
        'resume',
      ]);
      expect(
        resumed.exitCode,
        0,
        reason: '${resumed.stdout} ${resumed.stderr}',
      );
      final result =
          jsonDecode(File('$target/result.json').readAsStringSync()) as Map;
      expect(result['working'], isEmpty);
      expect(result['pending'], 0);
      expect(result['allocated'], 0);
      expect(result['remote'], 'saved version two');
    });
  }

  test('replacement at original slot after unlink crash stays visible and pending', () async {
    final target = '${fixture.path}/replacement-crash';
    final dart = testDartExecutable;
    final crashed = await Process.run(dart, [
      'run',
      'tool/edit_completion_fixture.dart',
      target,
      'after-unlink-before-db',
    ]);
    expect(crashed.exitCode, 86);
    final crash =
        jsonDecode(File('$target/crash.json').readAsStringSync()) as Map;
    final plan = ((crash['request'] as Map)['data'] as Map)['plan'] as List;
    final source = File(
      '$target/files/.anj-cloud-completion-crash/${(plan.first as Map)['from']}',
    );
    source.writeAsStringSync('unexpected later editor result', flush: true);
    final resumed = await Process.run(dart, [
      'run',
      'tool/edit_completion_fixture.dart',
      target,
      'resume',
    ]);
    expect(resumed.exitCode, 0);
    final result =
        jsonDecode(File('$target/result.json').readAsStringSync()) as Map;
    expect(result['pending'], 1);
    expect(source.readAsStringSync(), 'unexpected later editor result');
    expect(result['status'], contains('pending'));
  });
  test(
    'one ordinary Cloud save releases all proven-current app bytes',
    () async {
      final work = File(await engine.openFile(path))
        ..writeAsStringSync('one final save', flush: true);
      await engine.tick();
      expect(String.fromCharCodes(cloud.files[path]!), 'one final save');
      await finish();
      expect(engine.workingCopies(path), isEmpty);
      expect(ownedAllocated(tree), 0);
      expect(work.existsSync(), false);
    },
  );

  test('old pinned profile retains differing legacy preserved version with location and size', () async {
    engine.setRetention('Library', Retention.local);
    await engine.tick();
    engine.preserve(store.entries[path]!);
    final preserved = store.entries[path]!.preservedCopies.single;
    expect(engine.artifacts.record(File(preserved))!.hash, isNull);
    engine.setRetention('Library', Retention.cloud);
    final work = File(await engine.openFile(path))
      ..writeAsStringSync('new user edit', flush: true);
    await engine.tick();
    await finish();
    expect(work.existsSync(), false);
    expect(File(preserved).readAsStringSync(), 'initial bytes');
    final summary = engine.localArtifacts(path);
    expect(summary['count'], greaterThanOrEqualTo(1));
    expect(summary['bytes'], greaterThanOrEqualTo('initial bytes'.length));
    expect(
      (summary['files'] as List).map((v) => v['path']),
      contains(preserved),
    );
    expect(String.fromCharCodes(cloud.files[path]!), 'new user edit');
  });

  test('owned hash-null preserved alias is releasable only after exact current remote proof', () async {
    engine.setRetention('Library', Retention.local);
    await engine.tick();
    await engine.openFile(path);
    engine.preserve(store.entries[path]!);
    engine.setRetention('Library', Retention.cloud);
    await finish();
    expect(engine.workingCopies(path), isEmpty);
    expect(store.entries[path]!.preservedCopies, isEmpty);
    expect(ownedAllocated(tree), 0);
  });
  test(
    'live replacement after unlink cannot report successful Finish',
    () async {
      await engine.openFile(path);
      engine.editing.request(path, preview());
      File? replacement;
      engine.editing.barrier = (phase, request, fd) {
        if (phase != 'after-unlink-before-db' || replacement != null) return;
        final plan = (request.data['plan'] as List).first as Map;
        replacement = File('${tree.staging.path}/${plan['from']}')
          ..writeAsStringSync('later replacement', flush: true);
      };
      await engine.tick();
      expect(replacement!.readAsStringSync(), 'later replacement');
      expect(engine.editing.requests, hasLength(1));
      expect(store.entries[path]!.status, contains('Finish pending'));
      expect(store.entries[path]!.preservedCopies, contains(replacement!.path));
    },
  );

  test('writer during staging reclamation breaks lease and preserves complete bytes', () async {
    await engine.openFile(path);
    engine.editing.request(path, preview());
    final trigger = File('${fixture.path}/trigger');
    final attempted = File('${fixture.path}/attempted');
    final child = await Process.start('python3', [
      '-c',
      'import os,sys,time; t=sys.argv[1]; a=sys.argv[2]\nwhile not os.path.exists(t): time.sleep(.002)\np=open(t).read();open(a,"w").write("attempt");f=os.open(p,os.O_WRONLY|os.O_TRUNC);os.write(f,b"racing edit bytes");os.close(f)',
      trigger.path,
      attempted.path,
    ]);
    var broken = false;
    engine.editing.barrier = (phase, request, fd) {
      if (phase != 'before-final-unlink' || trigger.existsSync()) return;
      final plan = (request.data['plan'] as List).first as Map;
      trigger.writeAsStringSync('${tree.staging.path}/${plan['to']}');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (attempted.existsSync()) {
          try {
            engine.artifacts.native.valid(fd);
          } on FileSystemException {
            broken = true;
            break;
          }
        }
        sleep(const Duration(milliseconds: 1));
      }
      if (!broken) throw StateError('Writer failed to break active lease');
    };
    await engine.tick();
    expect(broken, true);
    expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
    expect(engine.workingCopies(path), hasLength(1));
    final retained = File(engine.workingCopies(path).single['path'] as String);
    expect(retained.readAsStringSync(), 'racing edit bytes');
    expect(String.fromCharCodes(cloud.files[path]!), 'initial bytes');
    expect(engine.editing.requests, hasLength(1));
    expect(cloud.deletes, 0);
  });
  test(
    'broken version lineage retains old buffers and reports residual bytes',
    () async {
      final work = File(await engine.openFile(path))
        ..writeAsStringSync('saved one');
      await engine.tick();
      work.writeAsStringSync('saved two');
      await engine.tick();
      final old = engine.artifacts.records.singleWhere(
        (o) =>
            o.data['role'] == 'working-upload' &&
            o.data['supersededBy'] != null,
      );
      store.operations[old.data['supersededBy']]!.data['baseEtag'] =
          'broken-chain';
      await finish();
      expect(engine.workingCopies(path), isEmpty);
      expect(File(old.staged!).readAsStringSync(), 'saved one');
      expect(engine.localArtifacts(path)['count'], greaterThan(0));
      expect(String.fromCharCodes(cloud.files[path]!), 'saved two');
    },
  );
  for (final corrupt in ['dangling', 'cycle', 'session']) {
    test(
      'supersession refuses $corrupt lineage without deleting old bytes',
      () async {
        final work = File(await engine.openFile(path))
          ..writeAsStringSync('version one');
        await engine.tick();
        work.writeAsStringSync('version two');
        await engine.tick();
        final old = engine.artifacts.records.singleWhere(
          (o) => o.data['supersededBy'] != null,
        );
        final tip = store.operations[old.data['supersededBy']]!;
        if (corrupt == 'dangling') tip.data['supersededBy'] = 'missing-buffer';
        if (corrupt == 'cycle') tip.data['supersededBy'] = old.id;
        if (corrupt == 'session') tip.data['workingId'] = 'different-session';
        await finish();
        expect(File(old.staged!).readAsStringSync(), 'version one');
        expect(engine.localArtifacts(path)['count'], greaterThan(0));
        expect(String.fromCharCodes(cloud.files[path]!), 'version two');
      },
    );
  }

  test(
    'lost upload acknowledgement never fabricates accepted supersession',
    () async {
      final work = File(await engine.openFile(path))
        ..writeAsStringSync('accepted edit');
      await engine.tick();
      work.writeAsStringSync('uncertain edit');
      cloud.loseNextUploadAcknowledgement = true;
      await engine.tick();
      final uncertain = engine.artifacts.records.singleWhere(
        (o) => o.data['role'] == 'working-upload' && o.data['accepted'] != true,
      );
      expect(uncertain.data['baseEtag'], isNotNull);
      engine.editing.request(path, preview());
      await engine.tick();
      expect(store.entries[path]!.conflict, isNotNull);
      expect(engine.workingCopies(path), hasLength(1));
      expect(work.readAsStringSync(), 'uncertain edit');
      expect(File(uncertain.staged!).readAsStringSync(), 'uncertain edit');
      expect(uncertain.data['accepted'], isNot(true));
      expect(String.fromCharCodes(cloud.files[path]!), 'uncertain edit');
    },
  );
}
