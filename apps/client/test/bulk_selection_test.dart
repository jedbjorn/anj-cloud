import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _Controller extends ClientController {
  _Controller(super.profile);
  final batches = <(String, List<Map<String, dynamic>>)>[];
  final commands = <String>[];
  @override
  bool get canCreateFolder => true;
  @override
  Future<Map<String, dynamic>> bulkCommand(
    String action,
    List<Map<String, dynamic>> targets,
  ) async {
    batches.add((action, targets));
    return {
      'accepted': targets.length,
      'failed': 0,
      'errors': <String>[],
      if (action == 'delete') ...{
        'paths': [for (final target in targets) target['path']],
        'at': 1000,
      },
    };
  }

  final trashCalls = <(String, Map<String, Object?>)>[];
  @override
  Future<Map<String, dynamic>> trash(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    trashCalls.add((op, args));
    return {
      'results': [
        for (final path in args['paths'] as List? ?? const [])
          {'path': path, 'result': 'restored', 'to': path},
      ],
    };
  }

  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {
    commands.add('$action:$path');
  }
}

Map<String, dynamic> _entry(String path, String kind, {String version = '1'}) =>
    {
      'path': path,
      'kind': kind,
      'selectionVersion': version,
      'status': 'current local',
      'effectiveRetention': 'local',
    };

void main() {
  setUpAll(() async {
    final fonts = Platform.environment['ANJ_UI_FONT_DIR'];
    if (fonts == null) return;
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(font.key)
        ..addFont(
          File('$fonts/${font.value}')
              .readAsBytes()
              .then((bytes) => bytes.buffer.asByteData()),
        );
      await loader.load();
    }
  });
  group('selection cards and lifecycle', () {
    late Directory profile;
    late _Controller controller;
    setUp(() {
      profile = Directory.systemTemp.createTempSync('anj-bulk-ui-');
      controller = _Controller(profile)
        ..root = '/fixture/root'
        ..entries = [
          _entry('Folder', 'directory'),
          {
            ..._entry('note.txt', 'file'),
            'workingCopies': [
              {'id': 'edit', 'path': '/private/edit'},
            ],
          },
        ];
    });
    tearDown(() {
      controller.dispose();
      profile.deleteSync(recursive: true);
    });
    Future<void> select(WidgetTester tester) async {
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'whole card including badges and whitespace toggles; inner actions disappear',
      (tester) async {
        await select(tester);
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        expect(find.text('Finish editing'), findsNothing);
        expect(find.byKey(const ValueKey('toggle:Folder')), findsNothing);
        final card = find.byKey(const ValueKey('card:Folder'));
        final badge = find.descendant(of: card, matching: find.byType(Chip));
        await tester.tapAt(tester.getCenter(badge));
        await tester.pump();
        expect(find.text('1 selected'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('bulk-cloud')))
              .onPressed,
          isNotNull,
        );
        await tester.tapAt(
          tester.getRect(card).bottomRight - const Offset(12, 8),
        );
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        final icon = find.byKey(const ValueKey('entry-icon:note.txt'));
        await tester.tapAt(tester.getCenter(icon));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(tester.getCenter(icon));
        await tester.pumpAndSettle();
        expect(controller.commands, isEmpty);
        await tester.tapAt(tester.getCenter(icon), buttons: 2);
        await tester.pumpAndSettle();
        expect(find.text('Icon colour · this device'), findsNothing);
        final content = find.byKey(const ValueKey('select-card:Folder'));
        Focus.of(tester.element(content)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(find.text('1 selected'), findsOneWidget);
      },
    );
    testWidgets('a mix of files and folders takes both storage choices without '
        'confirmation; Delete is one step with the exact targets, then Undo', (
      tester,
    ) async {
      await select(tester);
      await tester.tap(find.byKey(const ValueKey('select-card:Folder')));
      await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('bulk-local')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('bulk-cloud')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.batches.single.$1, 'cloud');
      expect(controller.batches.single.$2.map((e) => e['path']), [
        'Folder',
        'note.txt',
      ]);
      controller.batches.clear();
      expect(find.text('0 selected'), findsOneWidget);
      // The result line covers the lower card until it goes.
      ScaffoldMessenger.of(
        tester.element(find.text('0 selected')),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-card:Folder')));
      await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bulk-delete')));
      await tester.pumpAndSettle();
      // No confirmation (spec #44 T1): sent at once, then the snackbar.
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.batches.single.$1, 'delete');
      expect(controller.batches.single.$2.map((e) => e['path']), [
        'Folder',
        'note.txt',
      ]);
      expect(find.text('0 selected'), findsOneWidget);
      expect(find.text('2 items moved to Trash'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(controller.trashCalls.single.$1, 'undo');
      expect(controller.trashCalls.single.$2['paths'], ['Folder', 'note.txt']);
      expect(find.text('2 items restored.'), findsOneWidget);
    });
    testWidgets('Escape overrides focused search and cancels modal plus mode', (
      tester,
    ) async {
      await select(tester);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'note',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('library-search')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bulk-delete')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        'note',
      );
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bulk-delete')), findsNothing);
      expect(controller.batches, isEmpty);
    });
    testWidgets('retained deletion rows cannot enter or remain in selection', (
      tester,
    ) async {
      await select(tester);
      await tester.tap(find.byKey(const ValueKey('select-card:Folder')));
      await tester.pump();
      controller.entries.first['status'] =
          'deleted remotely; excluded local files retained';
      controller.reportMessage('retained scaffold');
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-card:Folder')));
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
    });
    testWidgets(
      'a replaced item leaves the selection before Delete can send it',
      (tester) async {
        await select(tester);
        await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
        await tester.pump();
        controller.entries = [_entry('note.txt', 'file', version: '2')];
        controller.reportMessage('replaced');
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('bulk-delete')))
              .onPressed,
          isNull,
        );
        expect(controller.batches, isEmpty);
      },
    );
    for (final width in [1280.0, 360.0]) {
      testWidgets('selection toolbar stays readable at $width', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: CloudApp(controller: controller),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('select-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('select-card:Folder')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final action in ['bulk-local', 'bulk-cloud', 'bulk-delete']) {
          expect(
            tester.getRect(find.byKey(ValueKey(action))).right,
            lessThanOrEqualTo(width),
          );
        }
        expect(find.text('Select All'), findsNothing);
        expect(find.text('Details'), findsNothing);
        final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
        for (final confirmation in [false]) {
          if (evidence != null) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              Directory(evidence).createSync(recursive: true);
              File(
                '$evidence/bulk-${confirmation ? 'confirmation' : 'selection'}-${width.toInt()}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      });
    }
    testWidgets(
      'scope and refresh prune selections and never select newly revealed rows',
      (tester) async {
        await select(tester);
        await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          'note',
        );
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
        await tester.pump();
        controller.entries = [
          _entry('note.txt', 'file', version: '2'),
          _entry('new.txt', 'file'),
        ];
        controller.reportMessage('refresh');
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('policy:cloud')));
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('policy:all')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('select-card:note.txt')));
        await tester.pump();
        await tester.tap(find.text('Editing'));
        await tester.pumpAndSettle();
        expect(find.text('0 selected'), findsOneWidget);
      },
    );
  });
  group('serialized batch validation and durability', () {
    late Directory fixture;
    late Manifest store;
    late RootTree tree;
    late SyncEngine engine;
    setUp(() async {
      fixture = Directory.systemTemp.createTempSync('anj-bulk-engine-');
      tree = RootTree.setup(
        (Directory('${fixture.path}/files')..createSync()).path,
        'bulk',
        NativeRootFs(),
      );
      store = Manifest(Directory('${fixture.path}/profile'));
      engine = SyncEngine(store, tree, FakeCloud());
      // Ordinary folders: Documents, Music and Videos are never Cloud-only
      // or deleted (spec #34 P7).
      Directory('${tree.root.path}/Projects/Child').createSync(recursive: true);
      Directory('${tree.root.path}/Photos').createSync();
      File('${tree.root.path}/Projects/Child/note.txt')
          .writeAsStringSync('note');
      await engine.tick();
      await engine.tick();
    });
    tearDown(() {
      engine.close();
      fixture.deleteSync(recursive: true);
    });
    Map<String, dynamic> target(String path) => {
      'path': path,
      'kind': store.entries[path]!.kind.name,
      'selectionVersion': engine.selectionVersion(store.entries[path]!),
    };
    test(
      'explicit parent and child retention preserve unselected nested override',
      () {
        final nested = Entry('Projects/Child/Other', ItemKind.directory)
          ..override = Retention.local;
        store.entries[nested.path] = nested;
        final result = engine.applyBulk('cloud', [
          target('Projects'),
          target('Projects/Child'),
        ]);
        expect(result['accepted'], 2);
        expect(store.entries['Projects']!.override, Retention.cloud);
        expect(store.entries['Projects/Child']!.override, Retention.cloud);
        expect(nested.override, Retention.local);
        expect(store.entries['Projects/Child/note.txt']!.override, isNull);
      },
    );
    test('stale version and unknown paths reject all before mutation', () {
      for (final bad in [
        {...target('Projects/Child'), 'selectionVersion': 'stale'},
        {'path': 'missing', 'kind': 'directory', 'selectionVersion': 'x'},
      ]) {
        final result = engine.applyBulk('cloud', [
          target('Projects'),
          target('Projects/Child/note.txt'),
          bad,
        ]);
        expect(result['accepted'], 0);
        expect(result['failed'], 3);
        expect(store.entries['Projects']!.override, isNull);
        expect(store.entries['Projects/Child/note.txt']!.override, isNull);
      }
    });
    test('unchanged refresh retains version; same-content inode replacement changes it', () async {
      final before = target('Projects/Child/note.txt');
      await engine.tick();
      expect(target('Projects/Child/note.txt'), before);
      final file = File('${tree.root.path}/Projects/Child/note.txt');
      file.renameSync('${file.path}.old');
      File(file.path).writeAsStringSync('note');
      expect(engine.applyBulk('delete', [before])['accepted'], 0);
      await engine.tick();
      expect(
        target('Projects/Child/note.txt')['selectionVersion'],
        isNot(before['selectionVersion']),
      );
    });
    test('late same-inode edits retain complete recovery bytes after queued deletion', () async {
      final selected = target('Projects/Child/note.txt');
      final file = File('${tree.root.path}/Projects/Child/note.txt');
      file.writeAsStringSync('late unsynchronized save', flush: true);
      // Selection validates known revisions and identity, while the established
      // synchronization/recovery guards own content changed after the last scan.
      expect(engine.applyBulk('delete', [selected])['accepted'], 1);
      await engine.tick();
      final entry = store.entries['Projects/Child/note.txt']!;
      expect(entry.preservedCopies, isNotEmpty);
      expect(
        engine.artifacts.resolve(entry.preservedCopies.last).readAsStringSync(),
        'late unsynchronized save',
      );
    });
    test('retained deleted scaffolds and stale overlapped children reject every target', () {
      final child = target('Projects/Child');
      expect(
        engine.applyBulk('delete', [
          target('Projects'),
          {...child, 'selectionVersion': 'stale'},
        ])['accepted'],
        0,
      );
      expect(
        store.operations.values.where((op) => op.kind == 'delete'),
        isEmpty,
      );
      store.entries['Projects/Child']!
        ..expectedPresent = false
        ..status = 'deleted remotely; excluded local files retained';
      expect(
        engine.applyBulk('cloud', [
          target('Projects'),
          target('Projects/Child'),
        ])['accepted'],
        0,
      );
      expect(store.entries['Projects']!.override, isNull);
    });
    test('one save persists all policies and root or unsupported requests reject all', () {
      store.db.execute('CREATE TABLE bulk_audit (path TEXT)');
      store.db.execute(
        'CREATE TRIGGER bulk_audit_write AFTER INSERT ON entries BEGIN INSERT INTO bulk_audit VALUES(new.path); END',
      );
      final transactions = store.transactions;
      final rows = store.rowsPersisted;
      expect(
        engine.applyBulk('cloud', [
          target('Projects'),
          target('Projects/Child'),
        ])['accepted'],
        2,
      );
      // Diff-only persistence: one transaction writes exactly both policy
      // rows and leaves every unchanged entry row untouched.
      expect(store.transactions - transactions, 1);
      expect(store.rowsPersisted - rows, 2);
      expect(
        store.db
            .select('SELECT path FROM bulk_audit ORDER BY path')
            .map((row) => row['path'])
            .toList(),
        ['Projects', 'Projects/Child'],
      );
      expect(store.entries.length, greaterThan(2));
      final persisted =
          store.db.select('SELECT body FROM entries WHERE path=?', [
                'Projects/Child',
              ]).single['body']
              as String;
      expect((jsonDecode(persisted) as Map)['override'], 'cloud');
      store.entries['link'] = Entry('link', ItemKind.unsupported);
      for (final bad in [
        {'path': '', 'kind': 'directory', 'selectionVersion': 'root'},
        target('link'),
      ]) {
        expect(
          engine.applyBulk('local', [target('Projects'), bad])['accepted'],
          0,
        );
        expect(store.entries['Projects']!.override, Retention.cloud);
      }
    });
    test('ancestor and descendant delete canonicalize once with unchanged conditional etag', () {
      final result = engine.applyBulk('delete', [
        target('Projects/Child/note.txt'),
        target('Projects'),
        target('Projects/Child'),
      ]);
      expect(result['accepted'], 1);
      expect(result['covered'], 2);
      final ops = store.operations.values.where((o) => o.kind == 'delete');
      expect(ops.length, 1);
      expect(ops.single.path, 'Projects');
      expect(ops.single.expectedEtag, store.entries['Projects']!.etag);
    });
    test(
      'replaced local folder and missing synced version reject entire batch',
      () {
        final old = target('Projects/Child');
        Directory('${tree.root.path}/Projects/Child')
            .renameSync('${tree.root.path}/Projects/old-child');
        Directory('${tree.root.path}/Projects/Child').createSync();
        expect(
          engine.applyBulk('cloud', [target('Projects'), old])['accepted'],
          0,
        );
        expect(store.entries['Projects']!.override, isNull);
        store.entries['Photos']!.etag = null;
        expect(
          engine.applyBulk('delete', [
            target('Projects'),
            target('Photos'),
          ])['accepted'],
          0,
        );
        expect(
          store.operations.values.where((o) => o.kind == 'delete'),
          isEmpty,
        );
      },
    );
    test(
      'failed SQLite save restores in-memory selection targets and operations',
      () {
        store.db.execute(
          "CREATE TRIGGER fail_bulk BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'fixture'); END",
        );
        expect(
          () => engine.applyBulk('cloud', [
            target('Projects'),
            target('Projects/Child'),
          ]),
          throwsA(anything),
        );
        expect(store.entries['Projects']!.override, isNull);
        expect(store.entries['Projects/Child']!.override, isNull);
        expect(
          () => engine.applyBulk('delete', [target('Projects')]),
          throwsA(anything),
        );
        expect(store.entries['Projects']!.status, isNot('delete queued'));
        expect(
          store.operations.values.where((o) => o.kind == 'delete'),
          isEmpty,
        );
      },
    );
  });
  test('worker acknowledges one serialized batch; deadline and stopped worker settle without retry', () async {
    final fixture = Directory.systemTemp.createTempSync('anj-bulk-worker-');
    final controller = ClientController(
      Directory('${fixture.path}/profile'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    final timeoutController = ClientController(
      Directory('${fixture.path}/timeout-profile'),
      secrets: MemorySecrets(),
      folderCommandTimeout: Duration.zero,
      nativeLibrary: testNativeLibrary,
    );
    Future<void> ready(ClientController client, String folder) async {
      await client.initialize();
      await client.configureRoot(
        (Directory('${fixture.path}/$folder')..createSync()).path,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((!client.canCreateFolder || client.entries.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(client.canCreateFolder, true);
    }

    Map<String, dynamic> target(Map<String, dynamic> entry) => {
      'path': entry['path'],
      'kind': entry['kind'],
      'selectionVersion': entry['selectionVersion'],
    };
    try {
      await ready(controller, 'files');
      // Ordinary folders: Documents, Music and Videos are never Cloud-only
      // (spec #34 P7).
      const folders = ['Projects', 'Photos'];
      for (final name in folders) {
        Directory('${fixture.path}/files/anj-cloud/$name').createSync();
      }
      final listed = DateTime.now().add(const Duration(seconds: 20));
      while (!folders.every(
            (name) => controller.entries.any((e) => e['path'] == name),
          ) &&
          DateTime.now().isBefore(listed)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final selected = controller.entries
          .where((e) => folders.contains(e['path']))
          .map(target)
          .toList();
      final result = await controller.bulkCommand('cloud', selected);
      expect(result['accepted'], 2);
      expect(result['failed'], 0);
      await controller.stop();
      final saved = Manifest(controller.profile);
      expect(saved.entries['Projects']!.override, Retention.cloud);
      expect(saved.entries['Photos']!.override, Retention.cloud);
      saved.close();
      await expectLater(
        controller.bulkCommand('local', selected),
        throwsA(isA<FileSystemException>()),
      );
      await ready(timeoutController, 'timeout-files');
      await expectLater(
        timeoutController.bulkCommand('cloud', [
          target(timeoutController.entries.first),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      await timeoutController.stop();
    } finally {
      await controller.stop();
      await timeoutController.stop();
      controller.dispose();
      timeoutController.dispose();
      fixture.deleteSync(recursive: true);
    }
  });
}
