import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Supply the pinned SDK's material_fonts directory for readable previews.
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
  late Directory profile;
  late _Controller controller;
  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-polish-');
    controller = _Controller(profile)
      ..root = '/home/demo/anj-cloud'
      ..message = 'Up to date'
      ..entries = [
        {
          'path': 'Documents',
          'kind': 'directory',
          'status': 'current local',
          'effectiveRetention': 'local',
        },
        {
          'path': 'notes.txt',
          'kind': 'file',
          'status': 'current local',
          'effectiveRetention': 'local',
        },
      ];
  });
  tearDown(() {
    controller.dispose();
    profile.deleteSync(recursive: true);
  });

  testWidgets(
    'icons open on double-click only; colour selection persists without sync commands',
    (tester) async {
      await tester.pumpWidget(CloudApp(controller: controller));
      final icon = find.byKey(const ValueKey('entry-icon:notes.txt'));
      await tester.tap(icon);
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(controller.commands, isEmpty);
      await tester.tap(icon);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(controller.commands, ['open:notes.txt']);
      controller.commands.clear();
      await tester.tap(icon, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Blue'),
          matching: find.byType(CheckedPopupMenuItem<int>),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Icon>(icon).color, const Color(0xff225bb5));
      expect(controller.commands, isEmpty);
      expect(controller.entries.last['effectiveRetention'], 'local');

      final restarted = _Controller(profile)..iconColors.load();
      expect(restarted.iconColors['notes.txt'], 0xff225bb5);
      restarted.dispose();
      // Keyboard users can both open and reach the same colour menu.
      final content = find.byKey(const ValueKey('content:notes.txt'));
      Focus.of(tester.element(content)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.commands, ['open:notes.txt']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset colour'));
      await tester.pumpAndSettle();
      expect(controller.iconColors['notes.txt'], isNull);
      expect(controller.commands, ['open:notes.txt']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [1280.0, 360.0]) {
    testWidgets('compact library retains warnings and actions at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.entries.addAll([
        {
          'path': 'draft.txt',
          'kind': 'file',
          'status': 'working copy synchronized',
          'effectiveRetention': 'local',
          'workingCopies': [
            {'id': 'edit-1', 'path': '/private/draft.txt', 'size': 40},
          ],
        },
        {
          'path': 'conflict.txt',
          'kind': 'file',
          'status': 'conflict',
          'effectiveRetention': 'local',
          'conflict': 'Changed on another device',
        },
        {
          'path': 'waiting.txt',
          'kind': 'file',
          'status': 'Finish pending: file busy',
          'effectiveRetention': 'local',
          'finishPending': true,
        },
        {
          'path': 'unsupported-link',
          'kind': 'unsupported',
          'status': 'unsupported',
        },
      ]);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: CloudApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Policy:'), findsNothing);
      expect(find.text('current local'), findsNothing);
      expect(find.text('Open folder'), findsNothing);
      expect(find.textContaining('Changed on another device'), findsOneWidget);
      expect(find.text('Finish editing'), findsOneWidget);
      final finish = find.byKey(const ValueKey('finish:draft.txt'));
      final draft = find.byKey(const ValueKey('card:draft.txt'));
      final menu = find.descendant(
        of: draft,
        matching: find.byType(PopupMenuButton<String>),
      );
      expect(
        tester.getRect(menu).right,
        lessThanOrEqualTo(tester.getRect(draft).right),
      );
      expect(
        tester.getRect(finish).left,
        greaterThanOrEqualTo(tester.getRect(draft).left),
      );
      if (width > 600) {
        expect(
          tester.getSize(find.byKey(const ValueKey('card:notes.txt'))).height,
          lessThanOrEqualTo(72),
        );
        expect(
          (tester.getCenter(finish).dy - tester.getCenter(menu).dy).abs(),
          lessThan(1),
        );
      }
      // At narrow widths the responsive toolbar/cards leave later rows below
      // the viewport. Verify the warning after deliberately scrolling to it.
      await tester.scrollUntilVisible(
        find.text('Finish pending: file busy'),
        120,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Finish pending: file busy'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('entry-icon:unsupported-link')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('entry-icon:unsupported-link')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const ValueKey('entry-icon:unsupported-link')),
      );
      await tester.pumpAndSettle();
      expect(controller.commands, isEmpty);

      // Optional review evidence uses synthetic data and never a live profile.
      final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
      if (evidence != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(evidence).createSync(recursive: true);
          File('$evidence/library-${width.toInt()}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final width in [1280.0, 360.0]) {
    testWidgets('completed deletions show Recovery copy or disappear at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.message = 'Reconciled.';
      controller.entries.addAll([
        {
          'path': 'kept.txt',
          'kind': 'file',
          'status': 'deleted',
          'effectiveRetention': 'local',
          'hasRecovery': true,
          'preservedCopies': ['/private/preserved-1'],
          'localArtifacts': {
            'count': 2,
            'bytes': 40,
            'kinds': {'recovery': 1, 'download': 1},
            'files': [],
          },
        },
        {
          'path': 'released.txt',
          'kind': 'file',
          'status': 'deleted',
          'effectiveRetention': 'local',
          'localArtifacts': {'count': 0, 'bytes': 0, 'files': []},
        },
        {
          'path': 'gone-remote.txt',
          'kind': 'file',
          'status': 'deleted remotely',
          'effectiveRetention': 'local',
        },
      ]);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Reconciled.'), findsWidgets);
      expect(find.byKey(const ValueKey('card:kept.txt')), findsOneWidget);
      expect(find.text('Recovery copy'), findsOneWidget);
      expect(find.text('Queued'), findsNothing);
      expect(
        find.textContaining(
          'Local staging files: recovery 1, download 1 (40 bytes)',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('card:released.txt')), findsNothing);
      expect(find.byKey(const ValueKey('card:gone-remote.txt')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
