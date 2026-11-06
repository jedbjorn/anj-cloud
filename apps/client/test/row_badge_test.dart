import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/design/badge_palette.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/model.dart';
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

final _tooLarge = tooLargeMessage(64 * 1024 * 1024);

/// One synthetic row per badge, as the projection would report it.
final _samples = <RowBadge, Map<String, dynamic>>{
  RowBadge.recoveryCopy: _file(
    'recovered.txt',
    status: 'removed locally',
    extra: {
      'hasRecovery': true,
      'preservedCopies': ['/private/preserved-1'],
    },
  ),
  RowBadge.conflict: _file(
    'plan.txt',
    status: 'conflict',
    extra: {'conflict': 'changed on another device'},
  ),
  // SC-033: refused as too large, as projectEntry reports it.
  RowBadge.needsAttention: _file(
    'video.mkv',
    status: _tooLarge,
    extra: {
      'syncPending': true,
      'presentationErrors': [_tooLarge],
    },
  ),
  RowBadge.editing: _file(
    'notes.odt',
    status:
        'Cloud pending: editor working copies stay pinned in this prototype.',
    policy: 'cloud',
    extra: {
      'workingCopies': [
        {'id': 'session'},
      ],
    },
  ),
  RowBadge.queued: _file('draft.txt', status: 'queued'),
  RowBadge.cloud: _file('photo.jpg', status: 'cloud-only', policy: 'cloud'),
  RowBadge.local: _file('readme.txt'),
};

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff245b69),
    brightness: brightness,
  ),
  useMaterial3: true,
  extensions: [BadgePalette.forBrightness(brightness)],
);

void main() {
  group('precedence', () {
    test('order is Recovery copy > Conflict > Needs attention > Editing > '
        'Queued > Cloud > Local', () {
      expect(RowBadge.values.map((b) => b.label), [
        'Recovery copy',
        'Conflict',
        'Needs attention',
        'Editing',
        'Queued',
        'Cloud',
        'Local',
      ]);
    });

    test('each badge outranks every lower one on the same row', () {
      // A row where every condition holds, then each top reason is removed.
      var row = <String, dynamic>{
        ..._file('all.txt', status: 'removed locally', policy: 'cloud'),
        'hasRecovery': true,
        'preservedCopies': ['/private/preserved-1'],
        'conflict': 'changed on another device',
        'presentationErrors': [_tooLarge],
        'workingCopies': [
          {'id': 'session'},
        ],
      };
      expect(rowBadge(row), RowBadge.recoveryCopy);
      // Not terminal any more (still dispatching): the conflict shows.
      row = {...row, 'syncPending': true};
      expect(rowBadge(row), RowBadge.conflict);
      row = {...row}..remove('conflict');
      expect(rowBadge(row), RowBadge.needsAttention);
      row = {
        ...row,
        'status': 'Cloud pending: editor working copies stay pinned.',
        'hasRecovery': false,
        'preservedCopies': [],
        'presentationErrors': [],
      };
      expect(rowBadge(row), RowBadge.editing);
      row = {...row, 'workingCopies': []};
      expect(rowBadge(row), RowBadge.queued);
      row = {...row, 'syncPending': false, 'status': 'cloud-only'};
      expect(rowBadge(row), RowBadge.cloud);
      row = {...row, 'effectiveRetention': 'local'};
      expect(rowBadge(row), RowBadge.local);
    });

    test('a failed edit outranks Editing; a pending finish reads Editing', () {
      final editing = _samples[RowBadge.editing]!;
      expect(
        fileBadge({...editing, 'status': 'Working copy pending: disk full'}),
        'Needs attention',
      );
      expect(
        fileBadge({
          ...editing,
          'workingCopies': [],
          'finishPending': true,
          'status': 'Finish pending: file changed since preview',
        }),
        'Needs attention',
      );
      final finishing = {
        ...editing,
        'workingCopies': [],
        'finishPending': true,
        'status': 'current local',
      };
      expect(fileBadge(finishing), 'Editing');
      // The amber bar still marks a pending finish.
      expect(needsAttention(finishing), isTrue);
      expect(hasProblem(finishing), isFalse);
    });
  });

  group('each state maps to its badge', () {
    for (final MapEntry(key: badge, value: entry) in _samples.entries) {
      test(badge.label, () => expect(rowBadge(entry), badge));
    }

    test('needs-attention states: too large, refused, failed, unsupported', () {
      for (final entry in [
        // projectEntry reports a size refusal as a presentation error.
        for (final status in [_tooLarge, tooLargeMessage(null, guess: true)])
          _file(
            'a',
            status: status,
            extra: {
              'syncPending': true,
              'presentationErrors': [status],
            },
          ),
        _file('c', status: 'upload failed: server unavailable'),
        _file('d', status: 'pending: connection reset'),
        _file(
          'e',
          status:
              'Cloud pending: filesystem guard refused; file is busy, changed, '
              'linked or unsupported.',
        ),
        {..._file('f'), 'kind': 'unsupported'},
      ]) {
        expect(rowBadge(entry), RowBadge.needsAttention, reason: entry['path']);
        // Same predicate as the amber bar.
        expect(needsAttention(entry), isTrue, reason: entry['path']);
      }
    });

    test('Queued is ordinary pending sync only', () {
      for (final status in ['queued', 'uploading', 'downloading']) {
        final entry = _file('q', status: status);
        expect(rowBadge(entry), RowBadge.queued, reason: status);
        expect(needsAttention(entry), isFalse, reason: status);
      }
      expect(
        rowBadge(_file('q', extra: {'syncPending': true})),
        RowBadge.queued,
      );
    });

    test('SC-033: a too-large row shows Needs attention, not Queued', () {
      final entry = _samples[RowBadge.needsAttention]!;
      expect(hasQueuedWork(entry), isTrue, reason: 'it was Queued before');
      expect(fileBadge(entry), 'Needs attention');
    });

    test('tones follow decision #60', () {
      expect(
        {for (final b in RowBadge.values) b.label: b.tone},
        {
          'Recovery copy': BadgeTone.recovery,
          'Conflict': BadgeTone.attention,
          'Needs attention': BadgeTone.attention,
          'Editing': BadgeTone.editing,
          'Queued': BadgeTone.plain,
          'Cloud': BadgeTone.cloud,
          'Local': BadgeTone.local,
        },
      );
    });
  });

  group('palette', () {
    for (final brightness in Brightness.values) {
      test('badge text contrast is at least 4.5:1 in ${brightness.name}', () {
        final palette = BadgePalette.forBrightness(brightness);
        final scheme = _theme(brightness).colorScheme;
        for (final tone in BadgeTone.values) {
          final colors = palette[tone];
          // Plain shows the row surface: plain, selected or revealed cards.
          final backgrounds = colors.background == null
              ? [scheme.surfaceContainerLow, scheme.secondaryContainer]
              : [colors.background!];
          for (final background in backgrounds) {
            final ratio = _contrast(colors.foreground, background);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '$tone ${brightness.name} ${ratio.toStringAsFixed(2)}',
            );
          }
        }
      });
    }

    test('only Queued is untinted, with an outline', () {
      for (final palette in [BadgePalette.light, BadgePalette.dark]) {
        for (final tone in BadgeTone.values) {
          final colors = palette[tone];
          expect(colors.background == null, tone == BadgeTone.plain);
          expect(colors.border == null, tone != BadgeTone.plain);
        }
      }
    });

    test('tints are low-saturation and read as their hue family', () {
      // Light-theme backgrounds: light (high lightness), soft (low chroma).
      final light = BadgePalette.light;
      for (final tone in BadgeTone.values.where((t) => t != BadgeTone.plain)) {
        final hsl = HSLColor.fromColor(light[tone].background!);
        expect(hsl.lightness, greaterThan(0.85), reason: '$tone');
      }
      double hue(BadgeTone tone) =>
          HSLColor.fromColor(light[tone].background!).hue;
      expect(hue(BadgeTone.cloud), inInclusiveRange(200, 225)); // blue
      expect(hue(BadgeTone.local), inInclusiveRange(110, 150)); // green
      expect(hue(BadgeTone.editing), inInclusiveRange(250, 275)); // lavender
      expect(hue(BadgeTone.attention), inInclusiveRange(38, 50)); // amber
      final amberBar = HSLColor.fromColor(attentionBarColor).hue;
      expect((hue(BadgeTone.attention) - amberBar).abs(), lessThan(8));
      expect(
        HSLColor.fromColor(light[BadgeTone.recovery].background!).saturation,
        lessThan(0.1),
        reason: 'grey',
      );
    });

    test('the palette interpolates between themes', () {
      final mid = BadgePalette.light.lerp(BadgePalette.dark, 0.5);
      expect(mid.plain.background, isNull);
      expect(
        mid.cloud.background,
        Color.lerp(
          BadgePalette.light.cloud.background,
          BadgePalette.dark.cloud.background,
          0.5,
        ),
      );
    });
  });

  group('rendered badges', () {
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

    for (final brightness in Brightness.values) {
      testWidgets('every badge in ${brightness.name}', (tester) async {
        tester.view.physicalSize = const Size(900, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rows = libraryRows(_samples.values.toList(), LibraryTab.home, {});
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(brightness),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: _theme(brightness).colorScheme.surface,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final row in rows)
                        LibraryEntryCard(
                          row: row,
                          collapsed: false,
                          showPath: false,
                          onToggle: null,
                          onOpen: () {},
                          onColorChanged: (_) {},
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final palette = BadgePalette.forBrightness(brightness);
        for (final MapEntry(key: badge, value: entry) in _samples.entries) {
          final path = entry['path'] as String;
          final chip = tester.widget<Chip>(find.byKey(ValueKey('badge:$path')));
          final colors = palette[badge.tone];
          expect((chip.label as Text).data, badge.label);
          expect(chip.labelStyle!.color, colors.foreground, reason: path);
          expect(
            chip.backgroundColor,
            colors.background ?? Colors.transparent,
            reason: path,
          );
          expect(
            chip.side,
            colors.border == null
                ? BorderSide.none
                : BorderSide(color: colors.border!),
            reason: path,
          );
        }
        // SC-033 in the rendered row: the label, not Queued.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('badge:video.mkv')),
            matching: find.text('Needs attention'),
          ),
          findsOneWidget,
        );
        expect(find.text('Queued'), findsOneWidget);
        // The bars are unchanged: amber on the rows that need attention.
        Color bar(String path) {
          final container = tester.widget<Container>(
            find.byKey(ValueKey('attention:$path')),
          );
          return ((container.decoration as BoxDecoration).border as Border)
              .left
              .color;
        }

        for (final path in ['recovered.txt', 'plan.txt', 'video.mkv']) {
          expect(bar(path), attentionBarColor, reason: path);
        }
        for (final path in ['notes.odt', 'draft.txt', 'photo.jpg']) {
          expect(bar(path), Colors.transparent, reason: path);
        }

        final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
        if (evidence == null) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(evidence).createSync(recursive: true);
          File('$evidence/badges-${brightness.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  });
}
