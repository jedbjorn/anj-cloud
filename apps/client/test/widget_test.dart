import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/evictions.dart' show openedCopyKept;
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/app.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  testWidgets(
    'root setup explains the fixed default without a storage selector',
    (tester) async {
      final controller = ClientController(
        Directory('/unused-root-profile'),
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.text('Choose root'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('root always uses Local and cloud'),
        findsOneWidget,
      );
      expect(find.byType(SegmentedButton), findsNothing);
      expect(find.byType(SegmentedButton), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('pairing help describes permanent credentials', (tester) async {
    // The dialog's form is taller than the default 800x600 test surface.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ClientController(
      Directory('/unused-synthetic-profile'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.tap(find.text('Pair device'));
    await tester.pumpAndSettle();
    expect(find.text('Pair this device'), findsOneWidget);
    expect(find.textContaining('seven days'), findsNothing);
    expect(find.textContaining('re-pairing'), findsNothing);
    expect(
      find.textContaining(
        'Pair once: certificates do not need renewing, and a replacement '
        'from your operator is picked up automatically.',
      ),
      findsOneWidget,
    );
    // Spec #35: the server, prefilled with the household origin, and the
    // code are the whole form: no CA file, no fingerprint, no approval check.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      findsNWidgets(2),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('pair-server')))
          .controller!
          .text,
      'https://gateway.example.com',
    );
    expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
    expect(find.textContaining('CA file'), findsNothing);
    expect(find.text('Check approval'), findsNothing);
    expect(find.textContaining('fingerprint'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('functional setup and recursive file actions are visible', (
    tester,
  ) async {
    final controller = ClientController(
      Directory('/unused-synthetic-profile'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    await tester.pumpWidget(CloudApp(controller: controller));
    expect(find.text('Choose root'), findsOneWidget);
    expect(find.text('Pair device'), findsOneWidget);
    controller.root = '/synthetic/anj-cloud';
    controller.entries = [
      {
        'path': 'Music/Albums/song.txt',
        'kind': 'file',
        'status': 'cloud-only',
        'effectiveRetention': 'cloud',
        'expectedPresent': false,
      },
    ];
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('song.txt'), findsNothing);
    await tester.tap(find.byTooltip('Expand Music'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand Music/Albums'));
    await tester.pumpAndSettle();
    expect(find.text('song.txt'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('entry-icon:Music/Albums/song.txt')),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byTooltip('File actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('File actions'));
    await tester.pumpAndSettle();
    expect(find.text('Local and cloud'), findsNothing);
    expect(find.text('Cloud-only / free up space'), findsNothing);
    expect(find.text('Delete everywhere'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'Cloud selection exposes retained editor location and actual byte size',
    (tester) async {
      late Directory fixture;
      late SyncEngine engine;
      late ClientController controller;
      late String working;
      await tester.runAsync(() async {
        fixture = Directory.systemTemp.createTempSync('anj-ui-working-');
        final parent = Directory('${fixture.path}/files')..createSync();
        final tree = RootTree.setup(parent.path, 'working-ui', NativeRootFs());
        final manifest = Manifest(Directory('${fixture.path}/profile'));
        manifest.setSetting('retention', 'cloud');
        final cloud = FakeCloud()..put('Library/open.txt', 'editor bytes');
        engine = SyncEngine(manifest, tree, cloud);
        await engine.tick();
        working = await engine.openFile('Library/open.txt');
        // Decision #183: only a changed copy is an editor copy to finish.
        File(working).writeAsStringSync('edited bytes', flush: true);
        await engine.tick();
        final entry = manifest.entries['Library/open.txt']!;
        controller =
            ClientController(
                Directory('${fixture.path}/ui-profile'),
                secrets: MemorySecrets(),
                nativeLibrary: testNativeLibrary,
              )
              ..root = tree.root.path
              ..entries = [
                entry.toJson()
                  ..['effectiveRetention'] = 'cloud'
                  ..['workingCopies'] = engine.workingCopies(entry.path),
              ];
      });
      try {
        await tester.pumpWidget(CloudApp(controller: controller));
        await tester.tap(find.byTooltip('Expand Library'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Editor copies remain until Finish editing.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('File actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Details and preserved copies'));
        await tester.pumpAndSettle();
        expect(find.textContaining('$working (12 bytes)'), findsOneWidget);
        expect(File(working).readAsStringSync(), 'edited bytes');
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        engine.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'deleted-file late edit can be recovered through its actual menu action',
    (tester) async {
      // The Keep both path of a conflicted deleted row; such copies now go
      // to the device trash (spec #44, device_trash_test.dart).
      SyncEngine.debugDeletionRecoveryRows = true;
      addTearDown(() => SyncEngine.debugDeletionRecoveryRows = false);
      late Directory fixture;
      late RootTree tree;
      late Manifest manifest;
      late SyncEngine engine;
      late RandomAccessFile held;
      late FakeCloud cloud;
      late _RecoveryController controller;
      await tester.runAsync(() async {
        fixture = Directory.systemTemp.createTempSync('anj-ui-recovery-');
        final parent = Directory('${fixture.path}/files')..createSync();
        tree = RootTree.setup(parent.path, 'ui-recovery', NativeRootFs());
        manifest = Manifest(Directory('${fixture.path}/profile'));
        cloud = FakeCloud();
        engine = SyncEngine(manifest, tree, cloud);
        final file = File('${tree.root.path}/Documents/note.txt')
          ..writeAsStringSync('original');
        await engine.tick();
        held = file.openSync(mode: FileMode.append);
        engine.requestDelete('Documents/note.txt');
        await engine.tick();
        held.writeStringSync(' late retained edit');
        held.flushSync();
        await engine.tick();
        final entry = manifest.entries['Documents/note.txt']!;
        expect(entry.expectedPresent, isFalse);
        expect(entry.conflict, isNotNull);
        controller = _RecoveryController(
          Directory('${fixture.path}/ui-profile'),
          engine,
        );
        controller.root = tree.root.path;
        controller.entries = [
          entry.toJson()
            ..['effectiveRetention'] = 'local'
            ..['canRecoverLocalVariants'] = await engine
                .canRecoverLocalVariants(entry.path),
        ];
      });
      try {
        await tester.pumpWidget(CloudApp(controller: controller));
        await tester.tap(find.byTooltip('Expand Documents'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('File actions'));
        await tester.pumpAndSettle();
        expect(find.text('Recover local edits as new files'), findsOneWidget);
        await tester.tap(find.text('Recover local edits as new files'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await controller.recovery?.call();
        });
        expect(controller.requestedAction, 'keepBoth');
        expect(
          File('${tree.root.path}/Documents/note.txt').existsSync(),
          isFalse,
        );
        final recovered = Directory('${tree.root.path}/Documents')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.conflict-'))
            .single;
        expect(recovered.readAsStringSync(), contains('late retained edit'));
        expect(cloud.files.containsKey('Documents/note.txt'), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        held.closeSync();
        engine.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'Finish confirms displayed files and exact sessions without changing Cloud policy',
    (tester) async {
      final controller =
          _FinishController(
              Directory('/unused-finish-profile'),
              secrets: MemorySecrets(),
            )
            ..root = '/synthetic/anj-cloud'
            ..entries = [
              {
                'path': 'Documents/open.txt',
                'kind': 'file',
                'status': 'Editor copies remain until Finish editing.',
                'effectiveRetention': 'cloud',
                'expectedPresent': false,
                'workingCopies': [
                  {
                    'id': 'shown-session',
                    'path': '/synthetic/working-open.txt',
                    'size': 40,
                    'modified': '2026-11-01 12:00:00',
                    'preview': {
                      'identity': 'opaque-old',
                      'stamp': 'opaque-current',
                    },
                  },
                ],
                'localArtifacts': {
                  'count': 1,
                  'bytes': 40,
                  'files': [
                    {'path': '/synthetic/working-open.txt', 'size': 40},
                  ],
                },
              },
            ];
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.widgetWithText(Tab, 'Editing'));
      await tester.pumpAndSettle();
      // The Cloud chip; the row's badge reads Editing (decision #60), and
      // its tooltip still states the unchanged Cloud policy.
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Editing'), findsOneWidget);
      expect(find.byTooltip('Cloud-only · on this device'), findsOneWidget);
      await tester.tap(find.text('Finish editing'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Saved changes sync automatically'),
        findsOneWidget,
      );
      expect(find.textContaining('completed edit results'), findsOneWidget);
      expect(find.textContaining('40 bytes'), findsWidgets);
      expect(find.textContaining('2026-11-01 12:00:00'), findsOneWidget);
      controller.entries = [
        {
          ...controller.entries.single,
          'workingCopies': [
            ...(controller.entries.single['workingCopies'] as List),
            {
              'id': 'later-session',
              'path': '/synthetic/later-open.txt',
              'size': 40,
            },
          ],
        },
      ];
      controller.notifyListeners();
      await tester.pump();
      await tester.tap(find.text('Editors closed — finish'));
      await tester.pumpAndSettle();
      expect(controller.action, 'finishEditing');
      expect(controller.sessions!.map((v) => v['id']), ['shown-session']);
      expect(controller.entries.single['effectiveRetention'], 'cloud');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'Remove opened copy asks for every app to be closed first (decision #184)',
    (tester) async {
      final controller =
          _FinishController(
              Directory('/unused-opened-profile'),
              secrets: MemorySecrets(),
            )
            ..root = '/synthetic/anj-cloud'
            ..entries = [
              {
                'path': 'song.mp3',
                'kind': 'file',
                'status': openedCopyKept,
                'effectiveRetention': 'cloud',
                'expectedPresent': false,
                'workingCopies': [
                  {
                    'id': 'opened-session',
                    'path': '/synthetic/working-song.mp3',
                    'size': 40,
                    'edited': false,
                  },
                ],
              },
            ];
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      // Unchanged: no Editing badge, no Finish editing.
      expect(find.widgetWithText(Chip, 'Editing'), findsNothing);
      expect(find.text('Finish editing'), findsNothing);
      Future<void> askToRemove() async {
        await tester.tap(find.byTooltip('File actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Details and preserved copies'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove opened copy'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Close every app using this copy first'),
          findsOneWidget,
        );
      }

      await askToRemove();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.action, isNull, reason: 'nothing without confirming');
      await askToRemove();
      await tester.tap(find.text('Apps closed — remove'));
      await tester.pumpAndSettle();
      expect(controller.action, 'removeOpenedCopy');
      expect(controller.sessions!.map((v) => v['id']), ['opened-session']);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'tabs preserve expansion; full-data attention and pending Finish remain visible',
    (tester) async {
      final controller =
          _FinishController(
              Directory('/unused-navigation-profile'),
              secrets: MemorySecrets(),
            )
            ..root = '/synthetic/anj-cloud'
            ..entries = [
              {
                'path': 'Documents/deep/edit.txt',
                'kind': 'file',
                'status': 'working copy synchronized',
                'effectiveRetention': 'cloud',
                'workingCopies': [
                  {'id': 'session'},
                ],
              },
              {
                'path': 'Documents/deep/conflict.txt',
                'kind': 'file',
                'status': 'conflict',
                'conflict': 'changed elsewhere',
                'effectiveRetention': 'local',
              },
              {
                'path': 'Documents/partial.txt',
                'kind': 'file',
                'status': 'Finish pending: busy',
                'finishPending': true,
                'effectiveRetention': 'cloud',
              },
            ];
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.text('edit.txt'), findsNothing);
      final border =
          (tester
                          .widget<Container>(
                            find.byKey(const ValueKey('attention:Documents')),
                          )
                          .decoration
                      as BoxDecoration)
                  .border
              as Border;
      expect(border.left.width, 3);
      expect(border.left.color, Colors.amber);
      expect(find.text('Needs attention in this folder'), findsOneWidget);
      await tester.tap(find.text('Editing'));
      await tester.pumpAndSettle();
      expect(find.text('edit.txt'), findsOneWidget);
      expect(find.text('Documents/deep/edit.txt'), findsOneWidget);
      expect(find.text('conflict.txt'), findsNothing);
      expect(find.text('Finish editing'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('finish:Documents/partial.txt')),
        160,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      final pending = tester.widget<TextButton>(
        find.byKey(const ValueKey('finish:Documents/partial.txt')),
      );
      expect(pending.onPressed, isNull);
      await tester.ensureVisible(find.byTooltip('Collapse Documents/deep'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Collapse Documents/deep'));
      await tester.pumpAndSettle();
      expect(find.text('edit.txt'), findsNothing);
      await tester.tap(find.text('Conflict'));
      await tester.pumpAndSettle();
      expect(find.text('conflict.txt'), findsOneWidget);
      expect(find.text('edit.txt'), findsNothing);
      await tester.tap(find.text('Editing'));
      await tester.pumpAndSettle();
      expect(find.text('edit.txt'), findsNothing);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Expand Documents'), findsOneWidget);
      controller.entries = [
        {'path': 'Documents/ok.txt', 'kind': 'file', 'status': 'current local'},
      ];
      controller.notifyListeners();
      await tester.pump();
      final clear =
          (tester
                          .widget<Container>(
                            find.byKey(const ValueKey('attention:Documents')),
                          )
                          .decoration
                      as BoxDecoration)
                  .border
              as Border;
      expect(clear.left.color, Colors.transparent);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'directory content double-click opens; chevron keyboard and actions stay separate',
    (tester) async {
      final controller =
          _FinishController(
              Directory('/unused-directory-profile'),
              secrets: MemorySecrets(),
            )
            ..root = '/synthetic/anj-cloud'
            ..entries = [
              {
                'path': 'Documents',
                'kind': 'directory',
                'status': 'current local',
                'effectiveRetention': 'local',
              },
              {
                'path': 'Documents/note.txt',
                'kind': 'file',
                'status': 'queued',
              },
            ];
      await tester.pumpWidget(CloudApp(controller: controller));
      final toggle = find.byKey(const ValueKey('toggle:Documents'));
      final icon = find.descendant(
        of: toggle,
        matching: find.byIcon(Icons.chevron_right),
      );
      Focus.of(tester.element(icon)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('note.txt'), findsOneWidget);
      expect(controller.action, isNull);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.action, isNull);
      final content = find.byKey(const ValueKey('content:Documents'));
      await tester.tap(content);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(content);
      await tester.pumpAndSettle();
      expect(controller.action, 'openDirectory');
      controller.action = null;
      Focus.of(tester.element(content)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.action, 'openDirectory');
      expect(find.text('Open folder'), findsNothing);
      expect(controller.entries.first['effectiveRetention'], 'local');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'directory becoming a conflicted file cannot hide its descendants behind old collapse state',
    (tester) async {
      final controller =
          _FinishController(
              Directory('/unused-type-change-profile'),
              secrets: MemorySecrets(),
            )
            ..root = '/synthetic/anj-cloud'
            ..entries = [
              {'path': 'a', 'kind': 'directory', 'status': 'current local'},
              {'path': 'a/b.txt', 'kind': 'file', 'status': 'current local'},
            ];
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.text('b.txt'), findsNothing);
      controller.entries = [
        {
          'path': 'a',
          'kind': 'file',
          'status': 'conflict',
          'conflict': 'File versus directory',
        },
        {'path': 'a/b.txt', 'kind': 'file', 'status': 'current local'},
      ];
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('b.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}

class _RecoveryController extends ClientController {
  _RecoveryController(super.profile, this.engine)
    : super(secrets: MemorySecrets());
  final SyncEngine engine;
  Future<void> Function()? recovery;
  String? requestedAction;
  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {
    requestedAction = action;
    if (action == 'keepBoth') {
      recovery = () => engine.keepBoth(path);
    }
  }
}

class _FinishController extends ClientController {
  _FinishController(super.profile, {super.secrets});
  String? action;
  List<Map<String, dynamic>>? sessions;
  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {
    this.action = action;
    this.sessions = sessions;
  }
}
