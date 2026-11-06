import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _file(
  String path, {
  String status = 'current local',
  String policy = 'local',
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': 'file',
  'selectionVersion': '1',
  'status': status,
  'effectiveRetention': policy,
  ...extra,
};

Map<String, dynamic> _dir(String path, {String policy = 'local'}) => {
  'path': path,
  'kind': 'directory',
  'selectionVersion': '1',
  'status': 'current local',
  'effectiveRetention': policy,
};

/// A completed local deletion whose only-on-this-device bytes were retained:
/// the field case that made ancestors amber while the file row stayed plain.
Map<String, dynamic> _recovered(String path, {String policy = 'local'}) =>
    _file(
      path,
      status: 'removed locally',
      policy: policy,
      extra: {
        'hasRecovery': true,
        'preservedCopies': ['/private/preserved-1'],
      },
    );

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
    profile = Directory.systemTemp.createTempSync('anj-attention-');
    controller = _Controller(profile)
      ..root = '/synthetic/files'
      ..entries = [
        _dir('Documents'),
        _dir('Documents/Taxes'),
        _recovered('Documents/Taxes/2025-return.pdf'),
        _file('Documents/Taxes/2024-return.pdf'),
        _file(
          'Documents/plan.txt',
          status: 'conflict',
          extra: {'conflict': 'changed on another device'},
        ),
        _file('Documents/readme.txt'),
        _dir('Photos', policy: 'cloud'),
        _file(
          'Photos/beach.jpg',
          status: 'upload failed: server unavailable',
          policy: 'cloud',
        ),
        _file('Photos/sunset.jpg', status: 'cloud-only', policy: 'cloud'),
        _dir('Music'),
        _file('Music/song.mp3'),
      ];
  });
  tearDown(() {
    controller.dispose();
    profile.deleteSync(recursive: true);
  });

  Color bar(WidgetTester tester, String path) {
    final container = tester.widget<Container>(
      find.byKey(ValueKey('attention:$path')),
    );
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.left.width, 3, reason: path);
    return border.left.color;
  }

  void expectAmber(WidgetTester tester, Iterable<String> paths) {
    for (final path in paths) {
      expect(bar(tester, path), Colors.amber, reason: path);
    }
  }

  void expectPlain(WidgetTester tester, Iterable<String> paths) {
    for (final path in paths) {
      expect(bar(tester, path), Colors.transparent, reason: path);
    }
  }

  Future<void> toggle(WidgetTester tester, String path) async {
    final button = find.byKey(ValueKey('toggle:$path'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('library-search')), text);
    await tester.pumpAndSettle();
  }

  test('every amber folder leads to an amber file beneath it', () {
    final rows = libraryRows(controller.entries, LibraryTab.home, {});
    final amberFiles = rows
        .where((r) => !r.directory && r.attention)
        .map((r) => r.path)
        .toList();
    expect(amberFiles..sort(), [
      'Documents/Taxes/2025-return.pdf',
      'Documents/plan.txt',
      'Photos/beach.jpg',
    ]);
    for (final folder in rows.where((r) => r.directory && r.attention)) {
      expect(
        amberFiles.any((path) => path.startsWith('${folder.path}/')),
        isTrue,
        reason: folder.path,
      );
    }
  });

  for (final width in [1280.0, 360.0]) {
    testWidgets(
      'files needing attention carry the amber bar in every view at width $width',
      (tester) async {
        // Tall enough that every row of the expanded fixture is built at
        // either width; the narrow layout wraps controls below the title.
        tester.view.physicalSize = Size(width, 1400);
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
        await tester.pumpAndSettle();

        // Home starts with folders collapsed; the folder bar points inward.
        expectAmber(tester, ['Documents', 'Photos']);
        expectPlain(tester, ['Music']);

        // Hierarchy: the file itself, and its ancestors, are amber; healthy
        // siblings and healthy folders are not.
        await toggle(tester, 'Documents');
        await toggle(tester, 'Documents/Taxes');
        expectAmber(tester, [
          'Documents',
          'Documents/Taxes',
          'Documents/Taxes/2025-return.pdf',
          'Documents/plan.txt',
        ]);
        expectPlain(tester, [
          'Documents/Taxes/2024-return.pdf',
          'Documents/readme.txt',
        ]);
        // Badges and text keep their existing meaning; the folder sentence
        // stays on folders only.
        expect(find.text('Recovery copy'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('card:Documents/plan.txt')),
            matching: find.widgetWithText(Chip, 'Conflict'),
          ),
          findsOneWidget,
        );
        expect(find.text('Needs attention in this folder'), findsNWidgets(3));
        await preview(tester, boundary, 'hierarchy-${width.toInt()}');
        await toggle(tester, 'Documents');
        await toggle(tester, 'Photos');
        await toggle(tester, 'Music');
        expectAmber(tester, ['Photos', 'Photos/beach.jpg']);
        expectPlain(tester, ['Photos/sunset.jpg', 'Music', 'Music/song.mp3']);
        await toggle(tester, 'Photos');
        await toggle(tester, 'Music');
        await toggle(tester, 'Documents');

        // Policy filter keeps the hierarchy and the file's own bar.
        await tester.tap(find.byKey(const ValueKey('policy:cloud')));
        await tester.pumpAndSettle();
        expectAmber(tester, ['Photos', 'Photos/beach.jpg']);
        expectPlain(tester, ['Photos/sunset.jpg']);
        await tester.tap(find.byKey(const ValueKey('policy:all')));
        await tester.pumpAndSettle();

        // Conflict tab.
        await tester.tap(find.widgetWithText(Tab, 'Conflict'));
        await tester.pumpAndSettle();
        expectAmber(tester, ['Documents', 'Documents/plan.txt']);
        await tester.tap(find.widgetWithText(Tab, 'Home'));
        await tester.pumpAndSettle();

        // File-only search results.
        await search(tester, 'return');
        expectAmber(tester, ['Documents/Taxes/2025-return.pdf']);
        expectPlain(tester, ['Documents/Taxes/2024-return.pdf']);
        expect(find.byKey(const ValueKey('attention:Documents')), findsNothing);
        await preview(tester, boundary, 'search-${width.toInt()}');

        // Selection mode over search results and over the hierarchy.
        await tester.tap(find.byKey(const ValueKey('select-button')));
        await tester.pumpAndSettle();
        expectAmber(tester, ['Documents/Taxes/2025-return.pdf']);
        expectPlain(tester, ['Documents/Taxes/2024-return.pdf']);
        await search(tester, '');
        expectAmber(tester, [
          'Documents',
          'Documents/Taxes/2025-return.pdf',
          'Documents/plan.txt',
        ]);
        expectPlain(tester, ['Documents/readme.txt']);

        expect(tester.takeException(), isNull);
        expect(controller.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
