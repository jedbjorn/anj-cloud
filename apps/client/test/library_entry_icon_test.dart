import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_fixtures.dart' show loadPreviewFonts;

Finder keyed(String key) => find.byKey(ValueKey(key));

Map<String, dynamic> entry(String path, [String kind = 'file']) => {
  'path': path,
  'kind': kind,
  'status': 'current local',
  'effectiveRetention': 'local',
  'selectionVersion': '1',
};

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final directory = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
  if (directory == null) return;
  final render =
      boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$directory/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadPreviewFonts);

  testWidgets('the leading icon follows the displayed basename and entry kind', (
    tester,
  ) async {
    // Keep the same local row while the cloud name changes, as after a rename.
    Future<void> check(
      String name,
      IconData glyph, {
      bool folder = false,
    }) async {
      final row = LibraryRow(
        entry('local-name', folder ? 'directory' : 'file')
          ..['cloudPath'] = 'Archive/Music/$name',
        attention: false,
        contextOnly: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryEntryCard(
              row: row,
              collapsed: true,
              showPath: false,
              onToggle: null,
              onOpen: null,
              onColorChanged: (_) {},
            ),
          ),
        ),
      );
      final content = keyed('content:local-name');
      final icons = tester.widgetList<Icon>(
        find.descendant(of: content, matching: find.byType(Icon)),
      );
      expect(icons.map((icon) => icon.icon), [
        if (folder && glyph != Icons.folder_outlined) Icons.folder_outlined,
        glyph,
      ], reason: name);
      expect(find.text(name), findsOneWidget);
    }

    for (final (folders, extensions, glyph) in [
      (
        ['Music'],
        'mp3 m4a aac flac wav ogg opus aiff wma',
        Icons.music_note_outlined,
      ),
      (
        ['Documents'],
        'pdf doc docx odt rtf txt md',
        Icons.description_outlined,
      ),
      (
        ['Videos', 'Movies'],
        'mp4 m4v mov mkv webm avi',
        Icons.theaters_outlined,
      ),
      (
        ['Pictures', 'Photos', 'Screenshots'],
        'png jpg jpeg gif webp heic svg',
        Icons.image_outlined,
      ),
      (['Presentations'], 'ppt pptx odp', Icons.slideshow_outlined),
    ]) {
      for (final folder in folders) {
        await check(folder.toUpperCase(), glyph, folder: true);
      }
      for (final extension in extensions.split(' ')) {
        await check('example.${extension.toUpperCase()}', glyph);
      }
    }
    for (final name in ['song.mp3', 'Music archive', 'Pictures.old']) {
      await check(name, Icons.folder_outlined, folder: true);
    }
    for (final name in [
      'Music',
      '.mp3',
      'mix.mp3.bak',
      'name.',
      'unknown.xyz',
    ]) {
      await check(name, Icons.insert_drive_file_outlined);
    }
    await check('.private.Mp3', Icons.music_note_outlined);
  });

  testWidgets(
    'expand, recolour, search and select typed rows with status cues',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.reset);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final profile = Directory.systemTemp.createTempSync('anj-row-icons-');
      final controller = ClientController(profile)
        ..root = '/example/library'
        ..entries = [
          for (final path in [
            'Music',
            'Documents',
            'Videos',
            'Pictures',
            'Presentations',
          ])
            entry(path, 'directory'),
          entry('Music/Track.Mp3'),
          entry('Music/Transfer.flac'),
          entry('Music/Blocked.wav', 'unsupported')
            ..['status'] = 'Unsupported item',
        ]
        ..syncing = {'Music/Transfer.flac'};
      addTearDown(() {
        controller.dispose();
        profile.deleteSync(recursive: true);
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: CloudApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand Music'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Collapse Music'), findsOneWidget);
      expect(
        tester.getSemantics(keyed('entry-icon:Music')).label,
        'Music\nNeeds attention in this folder',
      );
      expect(
        tester.getSemantics(keyed('syncing-icon:Music/Transfer.flac')).label,
        contains('Syncing\nTransfer.flac'),
      );
      expect(keyed('entry-icon:Music/Transfer.flac'), findsNothing);
      expect(
        tester.widget<Icon>(keyed('entry-icon:Music/Blocked.wav')).icon,
        Icons.block,
      );
      expect(
        find.descendant(
          of: keyed('badge:Music/Blocked.wav'),
          matching: find.text('Needs attention'),
        ),
        findsOneWidget,
      );
      await tester.tap(keyed('content:Music'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, 'Blue'));
      await tester.pumpAndSettle();
      final icons = tester.widgetList<Icon>(
        find.descendant(
          of: keyed('content:Music'),
          matching: find.byType(Icon),
        ),
      );
      expect(icons.map((icon) => icon.color), const [
        Color(0xff225bb5),
        Color(0xff225bb5),
      ]);
      final track = keyed('entry-icon:Music/Track.Mp3');
      expect(tester.widget<Icon>(track).color, isNot(const Color(0xff225bb5)));
      expect(tester.getSemantics(track).label, 'Track.Mp3');
      await capture(tester, boundary, 'library-rows');

      await tester.enterText(keyed('library-search'), 'Track');
      await tester.pumpAndSettle();
      expect(find.text('Music/Track.Mp3'), findsOneWidget);
      expect(tester.widget<Icon>(track).icon, Icons.music_note_outlined);
      expect(find.text('Show in folder'), findsOneWidget);
      await capture(tester, boundary, 'library-search');
      await tester.tap(keyed('select-button'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('select-card:Music/Track.Mp3'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(
        tester.widget<LibraryEntryCard>(keyed('row:Music/Track.Mp3')).selected,
        isTrue,
      );
      expect(find.text('Show in folder'), findsNothing);
      await capture(tester, boundary, 'library-selection');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
