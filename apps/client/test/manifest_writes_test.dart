import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Spec #13 diff-only manifest persistence: idle passes write nothing, one
/// change writes the same rows regardless of library size, and intent stays
/// durable before dispatch across SIGKILL.
// macOS only (spec #31 M1, decision #129): every manifest commit there is an
// F_FULLFSYNC (about 5 ms on mac-test), so these 1,000- and 2,000-file runs
// take 1.5 to 3.5 minutes (PR #59) against seconds on Linux's tmpfs. Only the
// limit differs; every assertion is the same.
final Timeout? flushBound =
    Platform.isMacOS ? const Timeout(Duration(minutes: 6)) : null;

void main() {
  // Deletions under Documents here are not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-manifest-writes-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'writes', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${tree.root.path}/$path');
  void populate(int count) {
    for (var i = 0; i < count; i++) {
      final directory = 'Documents/d${i ~/ 100}';
      if (i % 100 == 0) tree.ensureDirectory(directory);
      local('$directory/f$i.txt').writeAsStringSync('content of file $i');
    }
  }

  // A file written within the racy-timestamp margin is rehashed each pass and
  // its new hash time recorded (one row) until it is 2 s old; idle means older.
  const racyMargin = Duration(milliseconds: 2100);

  /// Rows and transactions written by one pass.
  Future<(int, int)> pass() async {
    final rows = store.rowsPersisted, transactions = store.transactions;
    await engine.tick();
    return (store.rowsPersisted - rows, store.transactions - transactions);
  }

  test(
    'idle passes after initial sync write no rows and no transactions',
    () async {
      // Each tick saves once per path; full re-encoding per save is test-only.
      store.verifyTracking = false;
      populate(1000);
      await Future<void>.delayed(racyMargin);
      expect((await pass()).$1, greaterThan(1000));
      expect(cloud.files.length, 1000);
      await pass();
      for (var i = 0; i < 3; i++) {
        expect(await pass(), (0, 0));
      }
    },
    timeout: flushBound,
  );

  test('one changed file writes the same rows at 200 and 2000 files', () async {
    store.verifyTracking = false;
    Future<(int, int)> changeOne(String path) async {
      await Future<void>.delayed(racyMargin);
      await pass();
      await pass();
      expect(await pass(), (0, 0));
      local(path).writeAsStringSync('changed content!');
      final changed = await pass();
      final settle = await pass();
      return (changed.$1 + settle.$1, changed.$2 + settle.$2);
    }

    populate(200);
    final small = await changeOne('Documents/d0/f0.txt');
    populate(2000);
    final large = await changeOne('Documents/d0/f1.txt');
    expect(store.entries.length, greaterThan(2000));
    expect(large, small);
    expect(large.$1, lessThan(40));
  }, timeout: flushBound);

  group('manifest persistence', () {
    test('nested operation data changed after a save is still persisted', () {
      final op = Operation('nested', 'finish-editing', 'Documents/n.txt')
        ..data['previews'] = {
          'a': {'stamp': 'one'},
        };
      store.operations[op.id] = op;
      store.save();
      final previews = op.data['previews'] as Map;
      store.save();
      (previews['a'] as Map)['stamp'] = 'two';
      store.save();
      final body =
          store.db.select('SELECT body FROM operations WHERE id=?', [
                'nested',
              ]).single['body']
              as String;
      expect(((jsonDecode(body) as Map)['data'] as Map)['previews'], {
        'a': {'stamp': 'two'},
      });
    });
    test(
      'nested data loaded from disk and changed before any save persists',
      () {
        final dir = Directory('${fixture.path}/nested-profile');
        final first = Manifest(dir);
        first.operations['loaded'] =
            Operation('loaded', 'finish-editing', 'Documents/n.txt')
              ..data['previews'] = {
                'a': {'stamp': 'one'},
              };
        first.save();
        first.close();
        // No engine: nothing calls markAllRows before this in-place write.
        final reopened = Manifest(dir)
          // Release builds have no assert-mode verifier; test that path.
          ..verifyTracking = false;
        ((reopened.operations['loaded']!.data['previews'] as Map)['a']
                as Map)['stamp'] =
            'two';
        reopened.save();
        reopened.close();
        final check = Manifest(dir);
        expect(
          ((check.operations['loaded']!.data['previews'] as Map)['a']
              as Map)['stamp'],
          'two',
        );
        expect(check.journalMode, 'wal');
        check.close();
      },
    );
    test('a failed save writes nothing and the next save retries', () {
      store.entries['x'] = Entry('x', ItemKind.file)..status = 'one';
      store.save();
      store.db.execute(
        "CREATE TRIGGER fail_x BEFORE INSERT ON entries WHEN NEW.path='x' BEGIN SELECT RAISE(ABORT, 'fixture'); END",
      );
      store.entries['x']!.status = 'two';
      store.entries['y'] = Entry('y', ItemKind.file);
      expect(store.save, throwsA(anything));
      expect(
        store.db.select('SELECT path FROM entries WHERE path=?', ['y']),
        isEmpty,
      );
      store.db.execute('DROP TRIGGER fail_x');
      final rows = store.rowsPersisted;
      store.save();
      expect(store.rowsPersisted - rows, 2);
      engine.close();
      final check = Manifest(Directory('${fixture.path}/profile'));
      expect(check.entries['x']!.status, 'two');
      expect(check.entries.containsKey('y'), isTrue);
      check.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      tree = RootTree(tree.root, tree.staging, NativeRootFs());
      engine = SyncEngine(store, tree, cloud);
    });
    test('an unchanged save or setting opens no transaction', () {
      store.entries['x'] = Entry('x', ItemKind.file);
      store.save();
      final transactions = store.transactions;
      store.entries['x']!.status = 'queued';
      store.setSetting('retention', 'local');
      store.save();
      expect(store.transactions, transactions);
    });
    test('removed rows are deleted and the manifest reloads exactly', () {
      store.entries['a'] = Entry('a', ItemKind.file)..preservedCopies.add('p');
      store.entries['b'] = Entry('b', ItemKind.file);
      store.operations['o'] = Operation('o', 'upload', 'a');
      store.save();
      store.entries.remove('b');
      store.entries['a']!.preservedCopies.add('q');
      store.operations['o']!.data['dispatchState'] = 'started';
      store.save();
      engine.close();
      final check = Manifest(Directory('${fixture.path}/profile'));
      expect(check.entries.keys, ['a']);
      expect(check.entries['a']!.preservedCopies, ['p', 'q']);
      expect(check.operations['o']!.data['dispatchState'], 'started');
      check.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      tree = RootTree(tree.root, tree.staging, NativeRootFs());
      engine = SyncEngine(store, tree, cloud);
    });
  });

  group('crash between durable intent and dispatch', () {
    for (final phase in ['upload-before-dispatch', 'delete-before-dispatch']) {
      test('SIGKILL at $phase converges once after restart', () async {
        final path = '${fixture.path}/crash-$phase';
        final dart = testDartExecutable;
        final crashed = await Process.run(dart, [
          'run',
          'tool/dispatch_fixture.dart',
          path,
          phase,
        ]);
        expect(
          crashed.exitCode,
          -9,
          reason: '${crashed.stdout}\n${crashed.stderr}',
        );
        final intent =
            jsonDecode(File('$path/crash.json').readAsStringSync()) as Map;
        expect((intent['op'] as Map)['data']['dispatchState'], 'started');
        expect(File('$path/dispatch.log').readAsLinesSync(), [
          'upload Documents/report.txt',
        ]);
        final resumed = await Process.run(dart, [
          'run',
          'tool/dispatch_fixture.dart',
          path,
          'resume',
        ]);
        expect(
          resumed.exitCode,
          0,
          reason: '${resumed.stdout}\n${resumed.stderr}',
        );
        final result =
            jsonDecode(File('$path/result.json').readAsStringSync()) as Map;
        expect(result['conflict'], isNull);
        expect(result['pending'], isEmpty);
        final log = File('$path/dispatch.log').readAsLinesSync();
        if (phase == 'upload-before-dispatch') {
          expect(result['remote'], 'edited before crash');
          expect(result['local'], 'edited before crash');
          expect(log, [
            'upload Documents/report.txt',
            'upload Documents/report.txt',
          ]);
        } else {
          expect(result['remote'], isNull);
          expect(result['local'], isNull);
          expect(result['status'], 'deleted');
          expect(log, [
            'upload Documents/report.txt',
            'delete Documents/report.txt',
          ]);
        }
      });
    }
  });
}
