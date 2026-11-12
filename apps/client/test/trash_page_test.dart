import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/trash_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final _now = DateTime.utc(2026, 11, 12, 12);
const _day = Duration.millisecondsPerDay;

class _Controller extends ClientController {
  _Controller()
    : super(Directory('/unused-trash-ui'), secrets: MemorySecrets());
  final calls = <(String, Map<String, Object?>)>[];
  String? note;
  List<Map<String, Object?>> entries2 = [
    {
      'path': 'Documents/Trip/photo.jpg',
      'kind': 'file',
      'size': 2048,
      'deleted': _now.millisecondsSinceEpoch - _day,
      'expires': _now.millisecondsSinceEpoch + 6 * _day,
      'serverId': '174',
      'deviceId': 'dev-1',
      'deviceSize': 2048,
      'onlyDevice': false,
    },
    {
      'path': 'notes.txt',
      'kind': 'file',
      'size': 1024,
      'deleted': _now.millisecondsSinceEpoch - 2 * _day,
      'expires': _now.millisecondsSinceEpoch + 5 * _day,
      'serverId': null,
      'deviceId': 'dev-2',
      'deviceSize': 1024,
      'onlyDevice': true,
    },
  ];

  @override
  bool get canCreateFolder => true;

  @override
  Future<Map<String, dynamic>> trash(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add((op, args));
    return switch (op) {
      'list' => {
        'note': note,
        'trashDays': 7,
        'deviceBytes': 3072,
        'entries': entries2,
      },
      'restore' || 'restoreDevice' => {
        'path': 'Documents/Trip/photo (restored).jpg',
        'renamed': true,
      },
      'delete' || 'empty' => {'deleted': 1, 'errors': <String>[]},
      _ => <String, dynamic>{},
    };
  }
}

void main() {
  late _Controller controller;
  setUp(() => controller = _Controller());
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TrashPage(controller: controller, now: () => _now),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists name, folder, deletion, expiry, size and the device '
      'marker, newest first', (tester) async {
    await open(tester);
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.textContaining('In Documents/Trip'), findsOneWidget);
    expect(
      find.textContaining('Deleted permanently in 6 days'),
      findsOneWidget,
    );
    expect(find.textContaining('2 KB'), findsOneWidget);
    expect(find.textContaining('Only on this device'), findsOneWidget);
    expect(find.textContaining("This device's trash: 3 KB"), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('photo.jpg')).dy,
      lessThan(tester.getTopLeft(find.text('notes.txt')).dy),
    );
  });

  testWidgets(
    'Restore needs no confirmation and says when the name was taken',
    (tester) async {
      await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('trash-restore:Documents/Trip/photo.jpg')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.calls[1].$1, 'restore');
      expect(controller.calls[1].$2, {'serverId': '174', 'deviceId': 'dev-1'});
      expect(
        find.text('Restored as photo (restored).jpg: the name was taken.'),
        findsOneWidget,
      );
    },
  );

  testWidgets("the menu offers this device's copy when both exist", (
    tester,
  ) async {
    await open(tester);
    await tester.tap(
      find.byKey(const ValueKey('trash-menu:Documents/Trip/photo.jpg')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Restore this device's copy"));
    await tester.pumpAndSettle();
    expect(controller.calls[1].$1, 'restoreDevice');
    expect(controller.calls[1].$2['deviceId'], 'dev-1');
    await tester.tap(find.byKey(const ValueKey('trash-menu:notes.txt')));
    await tester.pumpAndSettle();
    expect(find.text("Restore this device's copy"), findsNothing);
  });

  testWidgets('Delete now and Empty Trash each ask once, naming count and '
      'size', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('trash-menu:notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete now'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '1 item (1 KB) will be deleted permanently. This cannot be undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.calls.where((c) => c.$1 == 'delete'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('trash-empty')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '2 items (3 KB) will be deleted permanently. This cannot be undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-trash-delete')));
    await tester.pumpAndSettle();
    expect(controller.calls.where((c) => c.$1 == 'empty'), hasLength(1));
    // Select mode: Delete now for the selection.
    await tester.tap(find.byKey(const ValueKey('trash-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trash-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-trash-delete')));
    await tester.pumpAndSettle();
    final delete = controller.calls.lastWhere((c) => c.$1 == 'delete');
    expect(delete.$2, {
      'serverIds': <Object?>[],
      'deviceIds': ['dev-2'],
    });
  });

  testWidgets('offline: the note says only this device is shown', (
    tester,
  ) async {
    controller.note =
        "Can't reach the server: showing only this device's trash";
    await open(tester);
    expect(
      find.text("Can't reach the server: showing only this device's trash"),
      findsOneWidget,
    );
  });

  testWidgets('phone layout: Restore is an icon and nothing overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Restore'), findsNWidgets(2));
  });

  testWidgets('the app menu opens Trash', (tester) async {
    controller.root = '/synthetic/anj-cloud';
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.tap(find.byTooltip('AnJ Cloud menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-trash')));
    await tester.pumpAndSettle();
    expect(find.byType(TrashPage), findsOneWidget);
    expect(find.text('Empty Trash'), findsOneWidget);
  });

  test('messages', () {
    expect(movedToTrashText(1), 'Moved to Trash');
    expect(movedToTrashText(3), '3 items moved to Trash');
    expect(
      undoMessage({
        'results': [
          {'path': 'a/b.txt', 'result': 'renamed', 'to': 'a/b (restored).txt'},
        ],
      }),
      'Restored as b (restored).txt: the name was taken.',
    );
    expect(
      undoMessage({
        'results': [
          {'path': 'a.txt', 'result': 'restored', 'to': 'a.txt'},
          {
            'path': 'c.txt',
            'result': 'failed',
            'message': 'No longer in Trash',
          },
        ],
      }),
      "Restored. Couldn't restore c.txt: No longer in Trash. It stays in Trash.",
    );
    expect(expiresText(_day * 10, 0), 'Deleted permanently in 10 days');
    expect(expiresText(_day ~/ 2, 0), 'Deleted permanently within a day');
  });
}
