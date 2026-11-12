import 'dart:async';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _DirectoryController extends ClientController {
  _DirectoryController()
    : super(Directory('/unused-directory-ui'), secrets: MemorySecrets());
  bool ready = true;
  final requests = <({String parent, String name, Retention retention})>[];
  final responses = <Completer<String>>[];
  String? action;
  String? actionPath;
  String? actionValue;

  @override
  bool get canCreateFolder => ready;

  @override
  Future<String> createFolder({
    required String parent,
    required String name,
    required Retention retention,
  }) {
    requests.add((parent: parent, name: name, retention: retention));
    final response = Completer<String>();
    responses.add(response);
    return response.future;
  }

  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {
    this.action = action;
    actionPath = path;
    actionValue = value;
  }
}

Map<String, dynamic> _entry(
  String path, {
  String kind = 'file',
  String policy = 'local',
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': kind,
  'effectiveRetention': policy,
  'status': 'current local',
  ...extra,
};

Future<void> _close(WidgetTester tester, ClientController controller) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

void main() {
  testWidgets(
    'combined filters reveal matches and restore collapsed state, with keyboard search',
    (tester) async {
      final controller = _DirectoryController()
        ..root = '/synthetic/anj-cloud'
        ..entries = [
          _entry('Documents', kind: 'directory'),
          _entry(
            'Documents/deep/cloud.txt',
            policy: 'cloud',
            extra: {'status': 'queued'},
          ),
          _entry('Documents/deep/local.txt'),
        ];
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.text('cloud.txt'), findsNothing);
      expect(find.text('Storage choices apply to this device'), findsNothing);
      expect(find.text('AnJ Cloud'), findsOneWidget);
      expect(find.bySemanticsLabel('AnJ Cloud cloud seal'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('policy:cloud')));
      await tester.pumpAndSettle();
      expect(find.text('cloud.txt'), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('local.txt'), findsNothing);
      final chevron = tester.widget<IconButton>(
        find.byKey(const ValueKey('toggle:Documents')),
      );
      expect(chevron.onPressed, isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final search = tester.widget<TextField>(
        find.byKey(const ValueKey('library-search')),
      );
      expect(search.focusNode!.hasFocus, true);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'NO MATCH',
      );
      await tester.pump();
      expect(find.text('No files match your search.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('cloud.txt'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('policy:all')));
      await tester.pumpAndSettle();
      expect(find.text('cloud.txt'), findsNothing);
      expect(find.byTooltip('Expand Documents'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'DOCUMENTS/DEEP',
      );
      await tester.pumpAndSettle();
      expect(find.text('cloud.txt'), findsOneWidget);
      expect(find.text('local.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('cloud.txt'), findsNothing);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'narrow toolbar wraps and filter chips accept keyboard selection',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _DirectoryController()..root = '/synthetic/anj-cloud';
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final chip = find.byKey(const ValueKey('policy:local'));
      Focus.of(
        tester.element(find.descendant(of: chip, matching: find.text('Local'))),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, true);
      expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('create-folder-button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'create defaults to root and Local and waits for worker success',
    (tester) async {
      final controller = _DirectoryController()..root = '/synthetic/anj-cloud';
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byKey(const ValueKey('create-folder-button')));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('anj-cloud (root)')),
        findsOneWidget,
      );
      final choice = tester.widget<SegmentedButton<Retention>>(
        find.byType(SegmentedButton<Retention>),
      );
      expect(choice.selected, {Retention.local});
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'Notes',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(controller.requests, [
        (parent: '', name: 'Notes', retention: Retention.local),
      ]);
      expect(find.text('Creating…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm-create-folder')),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(dialog, findsOneWidget);
      expect(controller.requests.length, 1);
      controller.responses.single.complete('Notes');
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('Created folder: Notes'), findsOneWidget);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'create lists supported local parents, shows error and allows Cloud retry',
    (tester) async {
      final controller = _DirectoryController()
        ..root = '/synthetic/anj-cloud'
        ..entries = [
          _entry(
            'Ready',
            kind: 'directory',
            extra: {'localDirectoryAvailable': true},
          ),
          _entry('Remote only', kind: 'directory', policy: 'cloud'),
          _entry(
            'Conflicted',
            kind: 'directory',
            extra: {'localDirectoryAvailable': true, 'conflict': 'changed'},
          ),
          _entry(
            'Unsupported',
            kind: 'unsupported',
            extra: {'localDirectoryAvailable': true},
          ),
        ];
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byKey(const ValueKey('create-folder-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-parent')));
      await tester.pumpAndSettle();
      final menu = find.byType(DropdownMenuItem<String>);
      expect(
        find.descendant(of: menu, matching: find.text('Ready')),
        findsWidgets,
      );
      expect(
        find.descendant(of: menu, matching: find.text('Remote only')),
        findsNothing,
      );
      expect(
        find.descendant(of: menu, matching: find.text('Conflicted')),
        findsNothing,
      );
      expect(
        find.descendant(of: menu, matching: find.text('Unsupported')),
        findsNothing,
      );
      await tester.tap(find.text('Ready').last);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Cloud')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'New folder',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-create-folder')));
      await tester.pump();
      expect(controller.requests.single, (
        parent: 'Ready',
        name: 'New folder',
        retention: Retention.cloud,
      ));
      controller.entries = [];
      controller.responses.single.completeError(
        StateError('A folder with that name already exists.'),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('A folder with that name already exists.'),
        findsOneWidget,
      );
      expect(dialog, findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'Another',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-create-folder')));
      await tester.pump();
      expect(controller.requests.last, (
        parent: 'Ready',
        name: 'Another',
        retention: Retention.cloud,
      ));
      controller.responses.last.complete('Ready/Another');
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'invalid names stay in the dialog, cancel and unavailable worker do not create',
    (tester) async {
      final controller = _DirectoryController()..root = '/synthetic/anj-cloud';
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byKey(const ValueKey('create-folder-button')));
      await tester.pumpAndSettle();
      for (final name in [
        '',
        ' ',
        '.',
        '..',
        'parent/child',
        r'parent\child',
      ]) {
        await tester.enterText(find.byKey(const ValueKey('folder-name')), name);
        await tester.tap(find.byKey(const ValueKey('confirm-create-folder')));
        await tester.pumpAndSettle();
        expect(controller.requests, isEmpty, reason: name);
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      controller.ready = false;
      controller.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('create-folder-button')),
            )
            .onPressed,
        isNull,
      );
      expect(controller.requests, isEmpty);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'storage actions appear on directories, file delete retains confirmation',
    (tester) async {
      final controller = _DirectoryController()
        ..root = '/synthetic/anj-cloud'
        ..entries = [_entry('Folder', kind: 'directory'), _entry('note.txt')];
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byTooltip('Folder actions'));
      await tester.pumpAndSettle();
      expect(find.text('Local and cloud'), findsOneWidget);
      await tester.tap(find.text('Cloud-only / free up space'));
      await tester.pumpAndSettle();
      expect(controller.action, 'retention');
      expect(controller.actionPath, 'Folder');
      expect(controller.actionValue, 'cloud');
      controller.action = null;
      await tester.tap(find.byTooltip('File actions'));
      await tester.pumpAndSettle();
      expect(find.text('Local and cloud'), findsNothing);
      await tester.tap(find.text('Delete everywhere'));
      await tester.pumpAndSettle();
      expect(find.text('Delete everywhere?'), findsOneWidget);
      expect(controller.action, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.action, isNull);
      await _close(tester, controller);
    },
  );

  testWidgets(
    "a file's menu offers both storage choices, the current one checked, "
    '"(as folder)" when it follows its folder (spec #45 R3)',
    (tester) async {
      final controller = _DirectoryController()
        ..root = '/synthetic/anj-cloud'
        ..entries = [
          _entry('song.mp3'),
          _entry(
            'video.mp4',
            policy: 'cloud',
            extra: {'override': 'cloud', 'status': 'cloud-only'},
          ),
        ];
      await tester.pumpWidget(CloudApp(controller: controller));
      CheckedPopupMenuItem<String> item(String key) => tester
          .widget<CheckedPopupMenuItem<String>>(find.byKey(ValueKey(key)));

      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      expect(item('file-local:song.mp3').checked, isTrue);
      expect(item('file-cloud:song.mp3').checked, isFalse);
      expect(find.text('Keep on this device (as folder)'), findsOneWidget);
      expect(find.text('Cloud-only / free up space'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('file-cloud:song.mp3')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.action, 'retention');
      expect(controller.actionPath, 'song.mp3');
      expect(controller.actionValue, 'cloud');

      await tester.tap(find.byTooltip('File actions').last);
      await tester.pumpAndSettle();
      expect(item('file-cloud:video.mp4').checked, isTrue);
      expect(item('file-local:video.mp4').checked, isFalse);
      // Its own choice: no "(as folder)".
      expect(find.text('Cloud-only / free up space'), findsOneWidget);
      expect(find.text('Keep on this device'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('file-local:video.mp4')));
      await tester.pumpAndSettle();
      expect(controller.actionPath, 'video.mp4');
      expect(controller.actionValue, 'local');
      await _close(tester, controller);
    },
  );
}
