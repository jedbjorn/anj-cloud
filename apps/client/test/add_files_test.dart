// Spec #43 A3/A4: the worker's Add files copy (FileAdder) against the real
// libanj_rootfs.so on the VM host and a fake cloud: copy never moves,
// exclusive create with numbered names, decision #120 refusals, excluded
// names, the upload limit (known and unknown sizes), no partial file in the
// root on failure, cancel or restart, the free-space rule, and uploads by
// the next pass.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/documents_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/documents_ops.dart';
import 'package:anj_cloud/core/sync/file_adder.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory fixture;
  late Directory sources;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  late FileAdder adder;
  var paused = false;

  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('anj-add-files-');
    sources = Directory('${fixture.path}/phone')..createSync();
    final parent = Directory('${fixture.path}/a')..createSync();
    tree = RootTree.setup(parent.path, 'a', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
    paused = false;
    adder = FileAdder(engine, paused: () => paused);
    tree.ensureDirectory('Documents/Receipts');
    await engine.tick();
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  String source(String name, String text) {
    final file = File('${sources.path}/$name')..writeAsStringSync(text);
    return file.path;
  }

  Matcher skipped(String code) =>
      throwsA(isA<DocumentsFailure>().having((e) => e.code, 'code', code));

  /// Nothing of an add is left in staging: no file, no record.
  void stagingClean() {
    expect(
      engine.artifacts.records.where(
        (o) => o.data['role'] == FileAdder.stagingRole,
      ),
      isEmpty,
    );
    expect(
      tree.staging
          .listSync()
          .map((e) => e.path)
          .where(
            (path) =>
                path.split('/').last.startsWith('${FileAdder.stagingRole}-'),
          ),
      isEmpty,
    );
  }

  test('AC1: several files are copied into a nested folder and upload; '
      'the sources are unchanged', () async {
    final picked = {
      'one.txt': 'first',
      'two.pdf': 'second',
      'three.jpg': 'third',
    };
    for (final MapEntry(:key, :value) in picked.entries) {
      final path = await adder.addFile(
        'Documents/Receipts',
        key,
        source(key, value),
        number: true,
      );
      expect(path, 'Documents/Receipts/$key');
    }
    for (final MapEntry(:key, :value) in picked.entries) {
      expect(local('Documents/Receipts/$key').readAsStringSync(), value);
      // Copy, never move.
      expect(File('${sources.path}/$key').readAsStringSync(), value);
    }
    stagingClean();
    await engine.tick();
    for (final MapEntry(:key, :value) in picked.entries) {
      expect(utf8.decode(cloud.files['Documents/Receipts/$key']!), value);
    }
  });

  test('AC2: Add folder recreates a tree with an empty subfolder', () async {
    final top = adder.addFolder('Documents', 'Trip', number: true);
    expect(top, 'Documents/Trip');
    final day = adder.addFolder(top, 'Day 1', number: false);
    adder.addFolder(top, 'Empty', number: false);
    await adder.addFile(day, 'a.txt', source('a.txt', 'A'), number: false);
    await adder.addFile(top, 'b.txt', source('b.txt', 'B'), number: false);
    await engine.tick();
    expect(
      cloud.directories,
      containsAll([
        'Documents/Trip',
        'Documents/Trip/Day 1',
        'Documents/Trip/Empty',
      ]),
    );
    expect(utf8.decode(cloud.files['Documents/Trip/Day 1/a.txt']!), 'A');
    expect(utf8.decode(cloud.files['Documents/Trip/b.txt']!), 'B');
    // Only the top folder is numbered when its name is taken.
    expect(
      adder.addFolder('Documents', 'Trip', number: true),
      'Documents/Trip (2)',
    );
  });

  group('AC3: the upload limit', () {
    test('a known size over the limit is listed before copying', () {
      final plan = FileAdder.plan(
        [
          {'path': 'big.mp4', 'size': 2 << 20},
          {'path': 'small.txt', 'size': 100 << 10},
        ],
        siblings: const {},
        limit: 1 << 20,
      );
      final items = (plan['items'] as List).cast<Map>();
      expect(items[0]['skip'], 'overLimit');
      expect(items[1]['skip'], isNull);
      expect(plan['files'], 1);
      expect(plan['bytes'], 100 << 10);
      expect(
        AddSkip.overLimit.text(1 << 20),
        'Larger than the 1 MB upload limit',
      );
    });

    test(
      'the worker refuses a file over the advertised limit before any byte',
      () async {
        cloud.uploadLimit = 1 << 20;
        final big = source('big.bin', 'x' * (2 << 20));
        await expectLater(
          adder.addFile('Documents', 'big.bin', big, number: true),
          skipped('overLimit'),
        );
        expect(local('Documents/big.bin').existsSync(), isFalse);
        stagingClean();
      },
    );

    test(
      'a source with no size stops as soon as it passes the limit',
      () async {
        cloud.uploadLimit = 1 << 20;
        var sent = 0;
        final unsized = FileAdder(
          engine,
          openSource: (_) async* {
            // An endless stream: the copy must stop on its own.
            while (true) {
              sent += 64 << 10;
              yield List.filled(64 << 10, 7);
            }
          },
        );
        await expectLater(
          unsized.addFile('Documents', 'stream.bin', 'unsized', number: true),
          skipped('overLimit'),
        );
        expect(sent, lessThan(2 << 20));
        expect(local('Documents/stream.bin').existsSync(), isFalse);
        stagingClean();
      },
    );

    test('a size the provider does not report is planned for copying', () {
      final plan = FileAdder.plan(
        [
          {'path': 'unknown.bin'},
        ],
        siblings: const {},
        limit: 1 << 20,
      );
      expect((plan['items'] as List).single['skip'], isNull);
      expect(plan['files'], 1);
    });
  });

  group('AC4: no partial file is ever synchronized or left behind', () {
    test('a source failing mid-stream leaves nothing', () async {
      final failing = FileAdder(
        engine,
        openSource: (_) async* {
          yield List.filled(1000, 1);
          throw const FileSystemException('revoked grant');
        },
      );
      await expectLater(
        failing.addFile('Documents', 'gone.txt', 'x', number: true),
        skipped('unreadable'),
      );
      expect(local('Documents/gone.txt').existsSync(), isFalse);
      stagingClean();
      await engine.tick();
      expect(cloud.files.keys.where((k) => k.contains('gone')), isEmpty);
    });

    test('cancel mid-file aborts that file; completed files stay', () async {
      final chunks = StreamController<List<int>>();
      final slow = FileAdder(engine, openSource: (_) => chunks.stream);
      // The first file of the run completes normally.
      final done = await adder.addFile(
        'Documents',
        'kept.txt',
        source('kept.txt', 'kept'),
        number: true,
        run: 'r1',
      );
      final copying = slow.addFile(
        'Documents',
        'big.txt',
        'unused',
        number: true,
        run: 'r1',
      );
      chunks.add(List.filled(1000, 1));
      await pumpEventQueue();
      slow.cancel('r1');
      chunks.add(List.filled(1000, 2));
      await expectLater(copying, skipped('cancelled'));
      await chunks.close();
      expect(local('Documents/big.txt').existsSync(), isFalse);
      expect(local(done).readAsStringSync(), 'kept');
      stagingClean();
      await engine.tick();
      expect(utf8.decode(cloud.files['Documents/kept.txt']!), 'kept');
      expect(cloud.files.containsKey('Documents/big.txt'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a restart removes a copy the process did not finish', () async {
      // As if the process died mid-copy: the staged copy and its record.
      final staged = engine.artifacts.reserve(
        'Documents/partial.txt',
        FileAdder.stagingRole,
      );
      staged.writeAsStringSync('half');
      expect(stagingRemains(engine), isNotEmpty);
      engine.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      final again = RootTree(tree.root, tree.staging, NativeRootFs());
      engine = SyncEngine(store, again, cloud);
      tree = again;
      expect(stagingRemains(engine), isEmpty);
      expect(local('Documents/partial.txt').existsSync(), isFalse);
      expect(
        tree.staging.listSync().where(
          (e) => e.path.split('/').last.startsWith('add-'),
        ),
        isEmpty,
      );
      await engine.tick();
      expect(cloud.files.containsKey('Documents/partial.txt'), isFalse);
    });
  });

  group('AC5: names', () {
    test('exact, case and normalization collisions are numbered', () async {
      local('Documents/a.txt').writeAsStringSync('first');
      local('Documents/Photo.JPG').writeAsStringSync('photo');
      // "é" precomposed (NFC) on the phone, decomposed (NFD) in the pick.
      local('Documents/café.txt').writeAsStringSync('nfc');
      await engine.tick();
      expect(
        await adder.addFile(
          'Documents',
          'a.txt',
          source('a', '2'),
          number: true,
        ),
        'Documents/a (2).txt',
      );
      expect(
        await adder.addFile(
          'Documents',
          'a.txt',
          source('a', '3'),
          number: true,
        ),
        'Documents/a (3).txt',
      );
      expect(
        await adder.addFile(
          'Documents',
          'photo.jpg',
          source('p', 'x'),
          number: true,
        ),
        'Documents/photo (2).jpg',
      );
      expect(
        await adder.addFile(
          'Documents',
          'café.txt',
          source('c', 'nfd'),
          number: true,
        ),
        'Documents/café (2).txt',
      );
      // Nothing was replaced.
      expect(local('Documents/a.txt').readAsStringSync(), 'first');
      expect(local('Documents/a (2).txt').readAsStringSync(), '2');
    });

    test(
      'a blocked name is refused, not renamed; an excluded one skipped',
      () async {
        for (final name in ['CON.txt', 'a:b.txt', 'trailing.']) {
          await expectLater(
            adder.addFile('Documents', name, source('n', 'x'), number: true),
            skipped('blockedName'),
            reason: name,
          );
        }
        await expectLater(
          adder.addFile(
            'Documents',
            '.DS_Store',
            source('d', 'x'),
            number: true,
          ),
          skipped('excluded'),
        );
        expect(
          () => adder.addFolder('Documents', 'AUX', number: true),
          throwsA(
            isA<DocumentsFailure>().having(
              (e) => e.code,
              'code',
              'blockedName',
            ),
          ),
        );
        expect(
          Directory('${tree.root.path}/Documents')
              .listSync()
              .map((e) => e.path.split('/').last),
          unorderedEquals(['Receipts']),
        );
        stagingClean();
      },
    );

    test(
      'the plan numbers top items, refuses blocked folders with their subtree',
      () {
        final plan = FileAdder.plan(
          [
            {'path': 'a.txt', 'size': 1},
            {'path': 'A.TXT', 'size': 1},
            {'path': 'Bad:Folder', 'directory': true},
            {'path': 'Bad:Folder/inside.txt', 'size': 1},
            {'path': 'Tree', 'directory': true},
            {'path': 'Tree/Thumbs.db', 'size': 1},
            {'path': 'Tree/ok.txt', 'size': 1},
            {'path': 'Tree/virtual.gdoc', 'virtual': true},
          ],
          siblings: {'a.txt'},
          limit: 1 << 20,
        );
        final items = (plan['items'] as List).cast<Map>();
        expect(items[0]['target'], 'a (2).txt');
        expect(items[0]['renamed'], isTrue);
        expect(items[1]['target'], 'A (3).TXT');
        expect(items[2]['skip'], 'blockedName');
        expect(items[3]['skip'], 'blockedName');
        expect(items[3]['listed'], isFalse);
        expect(items[4]['target'], 'Tree');
        expect(items[5]['skip'], 'excluded');
        expect(items[6]['skip'], isNull);
        expect(items[7]['skip'], 'noStream');
        expect(plan['files'], 3);
        expect(plan['folders'], 1);
      },
    );
  });

  test('AC8: the add is refused when it needs more than the free space '
      'minus 256 MiB', () {
    Map<String, Object?> plan(int free) => FileAdder.plan(
      [
        {'path': 'a.bin', 'size': 40 << 20},
        {'path': 'b.bin', 'size': 20 << 20},
      ],
      siblings: const {},
      limit: 64 << 20,
      free: free,
    );
    expect(plan(addFreeSpaceReserve + (60 << 20))['noSpace'], isFalse);
    final short = plan(addFreeSpaceReserve + (59 << 20));
    expect(short['noSpace'], isTrue);
    expect(short['bytes'], 60 << 20);
    expect(short['free'], addFreeSpaceReserve + (59 << 20));
    expect(plan(100 << 20)['noSpace'], isTrue);
  });

  group('destinations', () {
    test(
      'paused, View only and missing folders refuse; the check names them',
      () async {
        paused = true;
        await expectLater(
          adder.addFile('Documents', 'x.txt', source('x', 'x'), number: true),
          skipped('paused'),
        );
        paused = false;
        expect(
          () => adder.check('Nowhere', const []),
          throwsA(
            isA<DocumentsFailure>().having((e) => e.code, 'code', 'notFound'),
          ),
        );
        expect(
          () => adder.check('../outside', const []),
          throwsA(isA<FileSystemException>()),
        );
        final checked = adder.check('Documents', [
          {'path': 'Receipts', 'directory': true},
        ]);
        expect((checked['items'] as List).single['target'], 'Receipts (2)');
      },
    );

    test('the documents channel carries the add commands', () async {
      final ops = DocumentsOps(engine);
      final checked = await ops.handle('addCheck', {
        'destination': 'Documents',
        'items': [
          {'path': 'n.txt', 'size': 3},
        ],
        'free': 1 << 40,
      });
      expect(checked['files'], 1);
      expect(checked['noSpace'], isFalse);
      final added = await ops.handle('addFile', {
        'parent': 'Documents',
        'name': 'n.txt',
        'source': source('n.txt', 'new'),
        'number': true,
      });
      expect(added['path'], 'Documents/n.txt');
    });
  });

  group('decision #190: a synced Cloud-only folder is a destination', () {
    /// Documents/Cloudy exists in the cloud only: no local directory.
    Future<void> cloudOnlyFolder() async {
      engine.setRetention('Documents', Retention.cloud);
      await cloud.mkdir('Documents/Cloudy');
      cloud.put('Documents/Cloudy/there.txt', 'there');
      await engine.tick();
      await engine.tick();
      expect(
        Directory('${tree.root.path}/Documents/Cloudy').existsSync(),
        isFalse,
      );
      expect(store.entries['Documents/Cloudy']?.etag, isNotNull);
    }

    test('added files upload, are released, and the folder stays', () async {
      await cloudOnlyFolder();
      expect(FileAdder.canReceive(engine, 'Documents/Cloudy'), isTrue);
      // The check creates nothing before the user confirms.
      adder.check('Documents/Cloudy', [
        {'path': 'new.txt', 'size': 3},
      ]);
      expect(
        Directory('${tree.root.path}/Documents/Cloudy').existsSync(),
        isFalse,
      );
      final path = await adder.addFile(
        'Documents/Cloudy',
        'new.txt',
        source('new.txt', 'new'),
        number: true,
      );
      expect(path, 'Documents/Cloudy/new.txt');
      for (var i = 0; i < 4; i++) {
        await engine.tick();
      }
      expect(utf8.decode(cloud.files[path]!), 'new');
      expect(local(path).existsSync(), isFalse, reason: 'released locally');
      expect(store.entries[path]!.status, 'cloud-only');
      expect(
        Directory('${tree.root.path}/Documents/Cloudy').existsSync(),
        isTrue,
      );
      expect(engine.retention('Documents/Cloudy'), Retention.cloud);
      expect(cloud.files.containsKey('Documents/Cloudy/there.txt'), isTrue);
    });

    test('not offered: no recorded cloud version, a conflict, a pending '
        'deletion above it', () async {
      await cloudOnlyFolder();
      final row = store.entries['Documents/Cloudy']!;
      final etag = row.etag;
      row.etag = null;
      expect(FileAdder.canReceive(engine, 'Documents/Cloudy'), isFalse);
      row
        ..etag = etag
        ..conflict = 'both changed';
      expect(FileAdder.canReceive(engine, 'Documents/Cloudy'), isFalse);
      await expectLater(
        adder.addFile(
          'Documents/Cloudy',
          'x.txt',
          source('x', 'x'),
          number: true,
        ),
        skipped('notFound'),
      );
      row.conflict = null;
      expect(FileAdder.canReceive(engine, 'Documents/Cloudy'), isTrue);
      final pending = Operation(uniqueId(), 'delete', 'Documents');
      store.operations[pending.id] = pending;
      expect(FileAdder.canReceive(engine, 'Documents/Cloudy'), isFalse);
      store.operations.remove(pending.id);
      expect(
        Directory('${tree.root.path}/Documents/Cloudy').existsSync(),
        isFalse,
      );
    });

    test('deleted in the cloud during the add: the bytes are kept', () async {
      await cloudOnlyFolder();
      final path = await adder.addFile(
        'Documents/Cloudy',
        'mine.txt',
        source('mine.txt', 'mine'),
        number: true,
      );
      // Another device deletes the folder before this pass uploads.
      cloud.remove('Documents/Cloudy/there.txt');
      cloud.directories.remove('Documents/Cloudy');
      cloud.versions.remove('Documents/Cloudy');
      for (var i = 0; i < 4; i++) {
        await engine.tick();
      }
      // The added file stays on this device and the folder needs review.
      expect(local(path).readAsStringSync(), 'mine');
      expect(store.entries['Documents/Cloudy']!.conflict, isNotNull);
      expect(cloud.files.containsKey(path), isFalse);
    });
  });

  test('a name deleted everywhere is free again', () async {
    local('Documents/Receipt.pdf').writeAsStringSync('old');
    await engine.tick();
    engine.requestDelete('Documents/Receipt.pdf');
    for (var i = 0; i < 3; i++) {
      await engine.tick();
    }
    expect(cloud.files.containsKey('Documents/Receipt.pdf'), isFalse);
    expect(store.entries['Documents/Receipt.pdf']?.status, 'deleted');
    expect(
      await adder.addFile(
        'Documents',
        'Receipt.pdf',
        source('Receipt.pdf', 'new'),
        number: true,
      ),
      'Documents/Receipt.pdf',
    );
  });

  test(
    'retention: an added file follows its folder like any new file',
    () async {
      // Documents' new and loose files are Cloud only (decision #163).
      engine.setRetention('Documents', Retention.cloud);
      await engine.tick();
      final path = await adder.addFile(
        'Documents',
        'loose.txt',
        source('loose.txt', 'loose'),
        number: true,
      );
      for (var i = 0; i < 4 && cloud.files[path] == null; i++) {
        await engine.tick();
      }
      expect(utf8.decode(cloud.files[path]!), 'loose');
      expect(engine.retention(path), Retention.cloud);
    },
  );
}

/// Add copies still recorded in staging.
List<Object> stagingRemains(SyncEngine engine) => [
  for (final op in engine.artifacts.records)
    if (op.data['role'] == FileAdder.stagingRole) op,
];
