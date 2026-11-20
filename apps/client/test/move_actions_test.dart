import 'package:anj_cloud/core/app/fetch_jobs.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'layout_fixtures.dart';

class _Controller extends LayoutController {
  final moves = <Map<String, Object?>>[];
  @override
  Future<Map<String, Object?>> documentsCommand(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'moveChoices') {
      return {
        'folders': {'': null, 'Destination': 9},
        'account': 'fixture',
        'files': args['job'] == null
            ? args['files']
            : [
                {'job': args['job'], 'path': 'Videos/clip.mp4', 'fileId': 8},
              ],
      };
    }
    expect(op, 'moveFiles');
    moves.add(args);
    return {
      'results': ['Moved to Destination.'],
    };
  }
}

void moveActions({
  required TargetPlatformVariant platforms,
  bool native = false,
  Future<void> Function(WidgetTester, String)? captureScreen,
}) {
  testWidgets(
    'move from a completed download, a Library file menu and Select',
    (tester) async {
      final phone = defaultTargetPlatform == TargetPlatform.android;
      if (!native) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = phone
            ? const Size(393, 852)
            : const Size(1100, 750);
        addTearDown(tester.view.reset);
      }
      final fetch = FakeFetch()
        ..rows = const [
          FetchJob(
            id: 'finished',
            kind: FetchKind.video,
            state: FetchState.done,
            path: 'Videos/clip.mp4',
          ),
        ];
      final jobs = FetchJobs(fetch, requestSync: () {});
      final c = _Controller()
        ..root = '/fixture'
        ..pairingState = 'paired'
        ..server = 'https://fixture.example'
        ..accountRights = 'write'
        ..message = 'Up to date'
        ..fetch = jobs
        ..entries = [
          for (final name in ['a.txt', 'b.txt'])
            {
              'path': name,
              'kind': 'file',
              'effectiveRetention': 'cloud',
              'status': 'cloud-only',
              'selectionVersion': name,
            },
        ];
      addTearDown(c.dispose);
      addTearDown(jobs.dispose);
      await jobs.probe(c.server);
      await tester.pumpWidget(
        CloudApp(controller: c, touchInput: phone, rootPicker: !phone),
      );
      await tester.pumpAndSettle();
      Future<void> tap(Finder f) async {
        if (native) {
          final deadline = DateTime.now().add(const Duration(seconds: 8));
          while (f.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }
        expect(f, findsOneWidget);
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      Future<void> choose() async {
        await tap(find.text('Destination'));
        expect(find.text('Moved to Destination.'), findsOneWidget);
        await tap(find.text('Close'));
      }

      await captureScreen?.call(tester, 'move-home');
      await tap(find.byTooltip('Downloader'));
      final direct = find.byKey(const ValueKey('job-move:finished'));
      await tap(direct);
      await captureScreen?.call(tester, 'move-picker');
      await tap(find.text('Cancel'));
      expect(c.moves, isEmpty);
      await tap(direct);
      await choose();
      expect((c.moves.last['files'] as List).single['job'], 'finished');
      await tap(find.byTooltip('Home'));
      await tap(find.byTooltip('File actions').first);
      await tap(find.text('Move to…'));
      await choose();
      expect((c.moves.last['files'] as List).single['path'], 'a.txt');
      await tap(find.byKey(const ValueKey('select-button')));
      for (final path in ['a.txt', 'b.txt']) {
        await tap(find.byKey(ValueKey('select-card:$path')));
      }
      await tap(find.byKey(const ValueKey('bulk-move')));
      await choose();
      expect(
        [for (final f in c.moves.last['files'] as List) f['path']],
        ['a.txt', 'b.txt'],
      );
      expect(c.moves.every((move) => move['parentId'] == 9), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
    variant: platforms,
  );
}

void main() => moveActions(
  platforms: TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  }),
);
