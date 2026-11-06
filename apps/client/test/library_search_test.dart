import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_list.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entry(
  String path, {
  String policy = 'local',
  bool editing = false,
  String version = '1',
}) => {
  'path': path,
  'kind': 'file',
  'selectionVersion': version,
  'status': policy == 'cloud' ? 'cloud-only' : 'current local',
  'effectiveRetention': policy,
  if (editing) 'finishPending': true,
};

class _Controller extends ClientController {
  _Controller(super.profile);
  final commands = <String>[];
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

void main() {
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
  Future<void> preview(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
    if (evidence == null) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(evidence).createSync(recursive: true);
      File('$evidence/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  late Directory profile;
  late _Controller controller;
  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-search-');
    controller = _Controller(profile)..root = '/synthetic/files';
  });
  tearDown(() {
    controller.dispose();
    profile.deleteSync(recursive: true);
  });

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('library-search')), text);
    await tester.pumpAndSettle();
  }

  Finder card(String path) => find.byKey(ValueKey('card:$path'));
  Finder reveal(String path) => find.byKey(ValueKey('show-in-folder:$path'));

  testWidgets(
    'flat file results retain duplicate paths and policy-only hierarchy',
    (tester) async {
      // Five rows below the two-line toolbar used under 1000 px wide.
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.entries = [
        entry('a/same.txt', policy: 'cloud'),
        entry('b/same.txt', policy: 'cloud'),
        {
          'path': 'same directory',
          'kind': 'directory',
          'effectiveRetention': 'cloud',
        },
      ];
      await tester.pumpWidget(CloudApp(controller: controller));
      await search(tester, ' SAME ');
      expect(find.byType(LibraryEntryCard), findsNWidgets(2));
      expect(find.text('a/same.txt'), findsOneWidget);
      expect(find.text('b/same.txt'), findsOneWidget);
      expect(card('a'), findsNothing);
      expect(card('same directory'), findsNothing);
      await search(tester, '   ');
      await tester.tap(find.byKey(const ValueKey('policy:cloud')));
      await tester.pumpAndSettle();
      expect(card('a'), findsOneWidget);
      expect(card('b'), findsOneWidget);
      expect(card('same directory'), findsOneWidget);
      expect(find.text('Show in folder'), findsNothing);
      expect(controller.commands, isEmpty);
    },
  );

  for (final width in [1280.0, 360.0]) {
    testWidgets(
      'reveal exact distant file with variable rows at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const target = 'z-last/deep/needle.txt';
        controller.entries = [
          for (var i = 0; i < 1200; i++)
            entry('z-last/deep/a-${i.toString().padLeft(4, '0')}.txt')
              ..['status'] = i.isEven
                  ? 'Queued\nAdditional variable-height detail\nThird line'
                  : 'current local',
          entry('b-duplicate/needle.txt'),
          entry(target, policy: 'cloud', editing: true),
        ];
        expect(
          libraryRows(
            controller.entries,
            LibraryTab.home,
            {},
          ).indexWhere((row) => row.path == target),
          greaterThan(1200),
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: CloudApp(controller: controller),
          ),
        );
        await tester.tap(find.text('Editing'));
        await tester.pumpAndSettle();
        await search(tester, 'needle');
        expect(find.byType(LibraryEntryCard), findsOneWidget);
        await preview(tester, boundary, 'file-search-${width.toInt()}');
        await tester.tap(reveal(target));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('library-search')))
              .controller!
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(const ValueKey('policy:all')))
              .selected,
          isTrue,
        );
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
        expect(card(target).hitTestable(), findsOneWidget);
        await preview(tester, boundary, 'show-in-folder-${width.toInt()}');
        expect(find.text(target), findsOneWidget);
        expect(
          tester
              .widget<LibraryEntryCard>(
                find.byKey(const ValueKey('row:z-last/deep/needle.txt')),
              )
              .revealed,
          isTrue,
        );
        expect(find.byType(LibraryEntryCard).evaluate().length, lessThan(40));
        expect(controller.commands, isEmpty);
        expect(controller.entries.last['effectiveRetention'], 'cloud');
        expect(profile.listSync(), isEmpty);

        // Removing preceding files preserves the path anchor and lets us
        // inspect the expanded ancestors without traversing all 1200 rows.
        controller.entries.removeWhere(
          (entry) => (entry['path'] as String).startsWith('z-last/deep/a-'),
        );
        controller.notifyListeners();
        await tester.pumpAndSettle();
        expect(card(target).hitTestable(), findsOneWidget);

        // Upward scrolling reaches predecessors in normal order, not a reversed
        // copy of the catalogue; both ancestors remain expanded in Home.
        final scrollable = find.descendant(
          of: find.byType(LibraryList),
          matching: find.byType(Scrollable),
        );
        await tester.drag(scrollable, const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(card('z-last'), findsOneWidget);
        expect(find.byTooltip('Collapse z-last/deep'), findsOneWidget);
        expect(
          tester.getTopLeft(card('z-last')).dy,
          lessThan(tester.getTopLeft(card('z-last/deep')).dy),
        );
        expect(
          tester.getTopLeft(card('z-last/deep')).dy,
          lessThan(tester.getTopLeft(card(target)).dy),
        );

        await search(tester, 'needle');
        await tester.tap(find.byKey(const ValueKey('policy:cloud')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('select-button')));
        await tester.pumpAndSettle();
        expect(reveal(target), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('select-card:z-last/deep/needle.txt')),
        );
        await tester.pump();
        expect(find.text('1 selected'), findsOneWidget);
        expect(controller.commands, isEmpty);
        await search(tester, 'none');
        expect(find.text('0 selected'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'root Cloud-only reveal, missing target, and refresh remain safe',
    (tester) async {
      const target = 'root.txt';
      controller.entries = [entry(target, policy: 'cloud')];
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.tap(find.byKey(const ValueKey('policy:cloud')));
      await search(tester, 'root');
      final staleAction = tester.widget<TextButton>(reveal(target)).onPressed!;
      controller.entries = [];
      staleAction();
      await tester.pumpAndSettle();
      expect(find.textContaining('no longer in the library'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        'root',
      );
      controller.entries = [entry(target, policy: 'cloud', version: '2')];
      controller.notifyListeners();
      await tester.pumpAndSettle();
      staleAction();
      await tester.pumpAndSettle();
      expect(card(target).hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('policy:cloud')))
            .selected,
        isTrue,
      );
      final y = tester.getTopLeft(card(target)).dy;
      controller.entries = [entry(target, policy: 'cloud', version: '3')];
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card(target)).dy, y);
      controller.entries = [entry('replacement.txt', policy: 'cloud')];
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(card(target), findsNothing);
      expect(card('replacement.txt'), findsOneWidget);
      expect(
        tester.widget<LibraryEntryCard>(find.byType(LibraryEntryCard)).revealed,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      expect(controller.commands, isEmpty);
      expect(profile.listSync(), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'centered lazy lists retain order and all rows in both directions',
    (tester) async {
      final built = <int>{};
      for (final target in [0, 50, 99]) {
        built.clear();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryList(
                key: ValueKey(target),
                itemCount: 100,
                revealIndex: target,
                itemBuilder: (context, index) {
                  built.add(index);
                  return SizedBox(
                    key: ValueKey('item:$index'),
                    height: 90 + (index % 3) * 30,
                    child: Text('Row $index'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('item:$target')).hitTestable(),
          findsOneWidget,
        );
        expect(built.length, lessThan(20));
        final scrollable = find.byType(Scrollable);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('item:0')),
          -500,
          scrollable: scrollable,
          maxScrolls: 40,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('item:0')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('item:0'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('item:1'))).dy),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('item:99')),
          500,
          scrollable: scrollable,
          maxScrolls: 40,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('item:99')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('item:98'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('item:99'))).dy),
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reveal follows exact path through refresh and selection cannot invoke stale action',
    (tester) async {
      const target = 'z/deep/needle.txt';
      controller.entries = [entry('a/needle.txt'), entry(target)];
      await tester.pumpWidget(CloudApp(controller: controller));
      await search(tester, 'z/deep/needle');
      final callback = tester.widget<TextButton>(reveal(target)).onPressed!;
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        'z/deep/needle',
      );
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pumpAndSettle();
      await tester.tap(reveal(target));
      await tester.pumpAndSettle();
      final y = tester.getTopLeft(card(target)).dy;
      controller.entries.insert(0, entry('before.txt'));
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card(target)).dy, y);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card(target)).dy, y);
      expect(
        tester
            .widget<LibraryEntryCard>(
              find.byKey(const ValueKey('row:z/deep/needle.txt')),
            )
            .revealed,
        isFalse,
      );
      controller.entries.removeWhere((entry) => entry['path'] == target);
      controller.entries.add({
        'path': target,
        'kind': 'directory',
        'effectiveRetention': 'local',
      });
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(CustomScrollView), findsNothing);
      expect(controller.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
