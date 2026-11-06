import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/ui/recovery_actions.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ClientController {
  _Controller(super.profile);
  final batches = <(String, List<Map<String, dynamic>>)>[];
  Map<String, dynamic> Function(String, List<Map<String, dynamic>>) answer =
      (action, targets) => {
        'accepted': targets.length,
        'failed': 0,
        'errors': <String>[],
        'restored': [
          if (action == 'recover')
            for (final t in targets)
              {'path': t['path'], 'destination': t['path'], 'kept': false},
        ],
      };
  void refresh() => notifyListeners();
  @override
  bool get canCreateFolder => true;
  @override
  Future<Map<String, dynamic>> bulkCommand(
    String action,
    List<Map<String, dynamic>> targets,
  ) async {
    batches.add((action, targets));
    return answer(action, targets);
  }

  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {}
}

const _mb = 1024 * 1024;

Map<String, dynamic> _file(
  String path, {
  String status = 'current local',
  List<String> copies = const [],
  int bytes = 0,
  bool recoverable = true,
  String? conflict,
}) => {
  'path': path,
  'kind': 'file',
  'selectionVersion': '["file",null,null,false,null]',
  'status': status,
  'effectiveRetention': 'local',
  'modified': 1793600000,
  'fileId': path.hashCode & 0xffff,
  'conflict': ?conflict,
  if (copies.isNotEmpty) ...{
    'hasRecovery': true,
    'recoveryCopies': {
      'paths': copies,
      'count': copies.length,
      'bytes': bytes,
      'recoverable': recoverable,
    },
  },
};

/// One synthetic row per producer, plus ordinary rows (spec #25).
List<Map<String, dynamic>> _fixture() => [
  // Upload recovery: removed before it synced (Laptop's probe).
  _file(
    'report.odt',
    status: 'removed locally',
    copies: ['/s/upload-1'],
    bytes: 300 * _mb,
  ),
  // Deletion with a preserved copy changed late (two copies).
  _file(
    'old.txt',
    status: 'deleted',
    copies: ['/s/preserved-1', '/s/preserved-2'],
    bytes: 12 * _mb,
    conflict: 'A preserved local version changed after replacement or deletion. Its complete bytes are retained.',
  ),
  // Replacement: a live file holding its preserved local version.
  _file('replaced.txt', copies: ['/s/preserved-3'], bytes: 2048),
  // Eviction quarantine beside a replacement.
  _file(
    'evicted.txt',
    status: 'conflict',
    copies: ['/s/eviction-quarantine-1'],
    bytes: 4096,
    conflict: 'A replacement root file and recovery copy are both retained.',
  ),
  // Edited conflict copy (Keep both).
  _file('note.txt.conflict-1a2b3c4d', copies: ['/s/conflict-edited-copy-1']),
  // An owned copy whose ownership is uncertain: Dismiss only.
  _file(
    'uncertain.txt',
    status: 'deleted',
    copies: ['/s/legacy'],
    bytes: 10,
    recoverable: false,
  ),
  _file('plain.txt'),
  {
    'path': 'Folder',
    'kind': 'directory',
    'selectionVersion': '1',
    'status': 'current local',
    'effectiveRetention': 'local',
  },
];

const _recoveryRows = [
  'report.odt',
  'old.txt',
  'replaced.txt',
  'evicted.txt',
  'note.txt.conflict-1a2b3c4d',
  'uncertain.txt',
];

void main() {
  late Directory profile;
  late _Controller controller;
  setUpAll(() async {
    final fonts = Platform.environment['ANJ_UI_FONT_DIR'];
    if (fonts == null) return;
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File('$fonts/${font.value}')
                .readAsBytes()
                .then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-recover-ui-');
    controller = _Controller(profile)
      ..root = '/synthetic/files'
      ..entries = _fixture();
  });
  tearDown(() {
    controller.dispose();
    profile.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    Widget Function(Widget)? wrap,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = CloudApp(controller: controller);
    await tester.pumpWidget(wrap == null ? app : wrap(app));
    await tester.pumpAndSettle();
  }

  Finder menuOf(String path) => find.descendant(
    of: find.byKey(ValueKey('row:$path')),
    matching: find.byType(PopupMenuButton<String>),
  );
  Future<void> openMenu(WidgetTester tester, String path) async {
    await tester.ensureVisible(menuOf(path));
    await tester.tap(menuOf(path));
    await tester.pumpAndSettle();
  }

  Future<void> closeMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  }

  testWidgets('Recover and Dismiss appear exactly on recovery-copy rows', (
    tester,
  ) async {
    await pump(tester);
    for (final entry in controller.entries) {
      final path = entry['path'] as String;
      await openMenu(tester, path);
      final expected = _recoveryRows.contains(path);
      expect(
        find.byKey(ValueKey('recover:$path')),
        expected ? findsOneWidget : findsNothing,
        reason: path,
      );
      expect(
        find.byKey(ValueKey('dismiss:$path')),
        expected ? findsOneWidget : findsNothing,
        reason: path,
      );
      // A completed deletion has nothing to delete everywhere.
      expect(
        find.text('Delete everywhere'),
        const {'report.odt', 'old.txt', 'uncertain.txt'}.contains(path)
            ? findsNothing
            : findsOneWidget,
        reason: path,
      );
      if (expected) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.byKey(ValueKey('recover:$path')),
              )
              .enabled,
          path != 'uncertain.txt',
        );
      }
      await closeMenu(tester);
    }
  });

  testWidgets('Recover needs no confirmation and says where the file went', (
    tester,
  ) async {
    controller.answer = (action, targets) => {
      'accepted': 1,
      'failed': 0,
      'errors': <String>[],
      'restored': [
        {
          'path': 'replaced.txt',
          'destination': 'replaced (recovered).txt',
          'kept': false,
        },
      ],
    };
    await pump(tester);
    await openMenu(tester, 'replaced.txt');
    await tester.tap(find.byKey(const ValueKey('recover:replaced.txt')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.batches.single.$1, 'recover');
    expect(controller.batches.single.$2.single['path'], 'replaced.txt');
    expect(
      find.text(
        'Recovered replaced.txt as replaced (recovered).txt. It syncs normally.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Recover while paused says the upload waits for Resume', (
    tester,
  ) async {
    controller.paused = true;
    await pump(tester);
    await openMenu(tester, 'report.odt');
    await tester.tap(find.byKey(const ValueKey('recover:report.odt')));
    await tester.pumpAndSettle();
    expect(
      find.text('Recovered report.odt. It uploads after you resume sync.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed Recover (full disk) shows the error', (tester) async {
    controller.answer = (action, targets) => {
      'accepted': 0,
      'failed': 1,
      'errors': [
        'report.odt: Not enough disk space. Write failed The recovery copy is kept.',
      ],
      'restored': <Map>[],
    };
    await pump(tester);
    await openMenu(tester, 'report.odt');
    await tester.tap(find.byKey(const ValueKey('recover:report.odt')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not enough disk space'), findsOneWidget);
    expect(find.textContaining('The recovery copy is kept.'), findsOneWidget);
  });

  testWidgets('Dismiss: one confirmation; Cancel keeps everything; confirm '
      'sends exactly the shown copies', (tester) async {
    await pump(tester);
    await openMenu(tester, 'report.odt');
    await tester.tap(find.byKey(const ValueKey('dismiss:report.odt')));
    await tester.pumpAndSettle();
    expect(find.text('Delete recovery copy?'), findsOneWidget);
    expect(
      find.text(
        'Delete the recovery copy of report.odt (300 MB)? It is the only copy and cannot be undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('cancel-dismiss')));
    await tester.pumpAndSettle();
    expect(controller.batches, isEmpty);
    await openMenu(tester, 'report.odt');
    await tester.tap(find.byKey(const ValueKey('dismiss:report.odt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-dismiss')));
    await tester.pumpAndSettle();
    expect(controller.batches.single.$1, 'dismiss');
    expect(controller.batches.single.$2, [
      {
        'path': 'report.odt',
        'kind': 'file',
        'copies': ['/s/upload-1'],
      },
    ]);
    expect(find.text('Recovery copy deleted.'), findsOneWidget);
  });

  testWidgets('a row with two copies names both in one confirmation', (
    tester,
  ) async {
    await pump(tester);
    await openMenu(tester, 'old.txt');
    await tester.tap(find.byKey(const ValueKey('dismiss:old.txt')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Delete the 2 recovery copies of old.txt (12 MB)? They are the only copies and cannot be undone.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Select mode, mixed rows: recovery rows are dismissable in '
      'bulk only; count and total size are shown', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('select-button')));
    await tester.pumpAndSettle();
    Future<void> toggle(String path) async {
      await tester.ensureVisible(find.byKey(ValueKey('select-card:$path')));
      await tester.tap(find.byKey(ValueKey('select-card:$path')));
      await tester.pump();
    }

    bool enabled(String key) =>
        tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed !=
        null;
    // A completed deletion's recovery row: Dismiss only.
    await toggle('report.odt');
    expect(find.text('1 selected'), findsOneWidget);
    expect(enabled('bulk-dismiss'), isTrue);
    expect(enabled('bulk-delete'), isFalse);
    // Mixed with an ordinary file: nothing applies to both.
    await toggle('plain.txt');
    expect(find.text('2 selected'), findsOneWidget);
    expect(enabled('bulk-dismiss'), isFalse);
    expect(enabled('bulk-delete'), isFalse);
    expect(
      find.text(
        'Recovery copies can only be dismissed; select them on their own.',
      ),
      findsOneWidget,
    );
    await toggle('plain.txt');
    // A live file holding a copy is both a file and a recovery row.
    await toggle('replaced.txt');
    await toggle('replaced.txt');
    await toggle('old.txt');
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bulk-dismiss')));
    await tester.pumpAndSettle();
    expect(find.text('Delete recovery copies?'), findsOneWidget);
    expect(
      find.textContaining(
        'Delete the recovery copies of 2 files (312 MB)? They are the only copies and cannot be undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-dismiss')));
    await tester.pumpAndSettle();
    expect(controller.batches.single.$1, 'dismiss');
    expect(controller.batches.single.$2.map((t) => t['path']).toSet(), {
      'report.odt',
      'old.txt',
    });
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('Select mode: a live file with a copy allows Delete and '
      'Dismiss; a plain file allows Delete only, with no Dismiss button', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('select-button')));
    await tester.pumpAndSettle();
    bool enabled(String key) =>
        tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed !=
        null;
    await tester.tap(find.byKey(const ValueKey('select-card:plain.txt')));
    await tester.pump();
    // Without a recovery row selected the bar is unchanged.
    expect(find.byKey(const ValueKey('bulk-dismiss')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('select-card:plain.txt')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('select-card:replaced.txt')));
    await tester.pump();
    expect(enabled('bulk-dismiss'), isTrue);
    expect(enabled('bulk-delete'), isTrue);
    await tester.tap(find.byKey(const ValueKey('select-card:plain.txt')));
    await tester.pump();
    expect(enabled('bulk-dismiss'), isFalse);
    expect(enabled('bulk-delete'), isTrue);
  });

  testWidgets('a selected recovery row whose copies changed is deselected', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('select-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-card:report.odt')));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    controller.entries = [
      for (final e in _fixture())
        if (e['path'] == 'report.odt')
          _file(
            'report.odt',
            status: 'removed locally',
            copies: ['/s/upload-1', '/s/upload-2'],
            bytes: 301 * _mb,
          )
        else
          e,
    ];
    controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('in the flat Recent and New lists too', (tester) async {
    await pump(tester);
    for (final policy in [LibraryPolicy.recent, LibraryPolicy.added]) {
      controller.batches.clear();
      await tester.tap(find.byKey(ValueKey('policy:${policy.name}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LibraryEntryCard>(
              find.byKey(const ValueKey('row:report.odt')),
            )
            .flat,
        isTrue,
      );
      await openMenu(tester, 'report.odt');
      expect(find.byKey(const ValueKey('recover:report.odt')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dismiss:report.odt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-dismiss')));
      await tester.pumpAndSettle();
      expect(controller.batches.single.$1, 'dismiss');
      // The outcome's snackbar would cover the next row's menu.
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await openMenu(tester, 'replaced.txt');
      await tester.tap(find.byKey(const ValueKey('recover:replaced.txt')));
      await tester.pumpAndSettle();
      expect(controller.batches.last.$1, 'recover');
      expect(controller.batches.last.$2.single['path'], 'replaced.txt');
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await openMenu(tester, 'plain.txt');
      expect(find.byKey(const ValueKey('dismiss:plain.txt')), findsNothing);
      await closeMenu(tester);
    }
  });

  testWidgets('evidence: the menu and the confirmation', (tester) async {
    final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
    final boundary = GlobalKey();
    await pump(
      tester,
      wrap: (app) => RepaintBoundary(key: boundary, child: app),
    );
    Future<void> capture(String name) async {
      if (evidence == null) return;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(evidence).createSync(recursive: true);
        File('$evidence/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await openMenu(tester, 'report.odt');
    await capture('recover-dismiss-menu');
    await tester.tap(find.byKey(const ValueKey('dismiss:report.odt')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await capture('dismiss-confirmation');
    await tester.tap(find.byKey(const ValueKey('cancel-dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-card:report.odt')));
    await tester.tap(find.byKey(const ValueKey('select-card:old.txt')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bulk-dismiss')));
    await tester.pumpAndSettle();
    await capture('bulk-dismiss-confirmation');
    expect(find.text('Delete recovery copies?'), findsOneWidget);
    expect(dismissPrompt([_fixture()[0], _fixture()[1]]), contains('312 MB'));
  });
}
