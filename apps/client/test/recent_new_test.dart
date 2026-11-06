// Recent and New filter chips (spec #24, decision #56).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_list.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Unix seconds for a local wall-clock time on this device.
int local(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> file(
  String path, {
  String policy = 'local',
  int? fileId,
  int? modified,
  int? added,
  int? localModified,
  bool pending = false,
  String? status,
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': 'file',
  'selectionVersion': '1',
  'status': status ?? (policy == 'cloud' ? 'cloud-only' : 'current local'),
  'effectiveRetention': policy,
  'fileId': ?fileId,
  'remoteModified': ?modified,
  'addedAt': ?added,
  'localModified': ?localModified,
  'pendingLocalEdit': pending,
  ...extra,
};

Map<String, dynamic> folder(String path) => {
  'path': path,
  'kind': 'directory',
  'selectionVersion': '1',
  'status': 'current local',
  'effectiveRetention': 'local',
};

/// Directories, a cloud-only file, a pending local edit and undated entries.
List<Map<String, dynamic>> fixture() => [
  folder('Docs'),
  folder('Docs/Old'),
  file(
    'Docs/report.txt',
    fileId: 640,
    modified: local(2026, 11, 1, 9, 0),
    added: local(2026, 10, 30, 8, 0),
  ),
  file(
    'Docs/cloud-only.pdf',
    policy: 'cloud',
    fileId: 700,
    modified: local(2026, 11, 2, 10, 0),
    added: local(2026, 11, 2, 10, 0),
  ),
  // Edited here after its last sync: Recent ranks it by the local time.
  file(
    'Docs/Old/draft.txt',
    fileId: 610,
    modified: local(2026, 10, 1, 12, 0),
    localModified: local(2026, 11, 2, 14, 5),
    pending: true,
    status: 'queued',
  ),
  // Added before the gateway recorded added times.
  file('legacy.txt', fileId: 300, modified: local(2026, 9, 1, 7, 30)),
  // Never listed (no file ID, no cloud time): undated in both lists.
  file('Docs/unlisted.txt'),
];

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
  group('projection', () {
    test('dates are local time in the compact style', () {
      expect(formatLibraryDate(local(2026, 11, 2, 14, 5)), '2 Nov 2026, 14:05');
      expect(formatLibraryDate(local(2027, 1, 9, 0, 7)), '9 Jan 2027, 00:07');
    });

    test('Recent: files only, newest change first, pending edit on top, '
        'undated last with "Date unknown"', () {
      final rows = libraryRows(fixture(), LibraryTab.home, {
        'Docs',
      }, policy: LibraryPolicy.recent);
      expect(rows.map((r) => r.path), [
        'Docs/Old/draft.txt',
        'Docs/cloud-only.pdf',
        'Docs/report.txt',
        'legacy.txt',
        'Docs/unlisted.txt',
      ]);
      expect(rows.every((r) => !r.directory && !r.contextOnly), isTrue);
      expect(rows.map((r) => r.date), [
        'Modified 2 Nov 2026, 14:05',
        'Modified 2 Nov 2026, 10:00',
        'Modified 1 Nov 2026, 09:00',
        'Modified 1 Sep 2026, 07:30',
        'Date unknown',
      ]);
      // The cloud-only file keeps its usual badge.
      expect(fileBadge(rows[1].entry), 'Cloud');
    });

    test('New: by file ID newest first; no record shows "Added earlier"; '
        'unidentified last', () {
      final rows = libraryRows(
        fixture(),
        LibraryTab.home,
        {},
        policy: LibraryPolicy.added,
      );
      expect(rows.map((r) => r.path), [
        'Docs/cloud-only.pdf',
        'Docs/report.txt',
        'Docs/Old/draft.txt',
        'legacy.txt',
        'Docs/unlisted.txt',
      ]);
      expect(rows.map((r) => r.date), [
        'Added 2 Nov 2026, 10:00',
        'Added 30 Oct 2026, 08:00',
        'Added earlier',
        'Added earlier',
        'Added earlier',
      ]);
    });

    test('ranked rows keep the attention bar and syncing icon', () {
      final entries = [
        file('a.txt', fileId: 2, modified: 20),
        file('b.txt', fileId: 1, modified: 10, extra: {'conflict': 'x'}),
      ];
      final rows = libraryRows(
        entries,
        LibraryTab.home,
        {},
        policy: LibraryPolicy.recent,
        syncing: {'a.txt'},
      );
      expect(rows.map((r) => (r.path, r.syncing, r.attention)), [
        ('a.txt', true, false),
        ('b.txt', false, true),
      ]);
    });

    test('search bypasses every chip; the tab still applies', () {
      final entries = fixture();
      final results = {
        for (final policy in LibraryPolicy.values)
          policy: libraryRows(
            entries,
            LibraryTab.home,
            {'Docs'},
            policy: policy,
            search: 'docs/',
          ).map((r) => r.path).toList(),
      };
      for (final policy in LibraryPolicy.values) {
        expect(results[policy], results[LibraryPolicy.all], reason: '$policy');
        expect(
          libraryRows(
            entries,
            LibraryTab.home,
            {},
            policy: policy,
            search: 'docs/',
          ).every((r) => r.date == null),
          isTrue,
        );
      }
      expect(results[LibraryPolicy.all], [
        'Docs/Old/draft.txt',
        'Docs/cloud-only.pdf',
        'Docs/report.txt',
        'Docs/unlisted.txt',
      ]);
      expect(
        libraryRows(
          entries,
          LibraryTab.conflict,
          {},
          policy: LibraryPolicy.recent,
          search: 'docs/',
        ),
        isEmpty,
      );
    });
  });

  group('window', () {
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
      profile = Directory.systemTemp.createTempSync('anj-chips-');
      controller = _Controller(profile)..root = '/synthetic/files';
    });
    tearDown(() {
      controller.dispose();
      profile.deleteSync(recursive: true);
    });

    Finder chip(LibraryPolicy policy) =>
        find.byKey(ValueKey('policy:${policy.name}'));
    Future<void> choose(WidgetTester tester, LibraryPolicy policy) async {
      await tester.tap(chip(policy));
      await tester.pumpAndSettle();
    }

    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        text,
      );
      await tester.pumpAndSettle();
    }

    int listed(WidgetTester tester) =>
        tester.widget<LibraryList>(find.byType(LibraryList)).itemCount;
    Finder more() => find.byKey(const ValueKey('ranked-more'));
    Finder less() => find.byKey(const ValueKey('ranked-less'));
    Future<void> toEnd(WidgetTester tester) async {
      final list = find.descendant(
        of: find.byType(LibraryList),
        matching: find.byType(Scrollable),
      );
      await tester.drag(list.first, const Offset(0, -100000));
      await tester.pumpAndSettle();
    }

    List<Map<String, dynamic>> many(int count) => [
      for (var i = 0; i < count; i++)
        file(
          'f${i.toString().padLeft(3, '0')}.txt',
          fileId: 1000 + i,
          modified: 1793600000 + i,
          added: 1793500000 + i,
        ),
    ];

    testWidgets('chips are All, Recent, New, Cloud, Local; one is selected', (
      tester,
    ) async {
      controller.entries = fixture();
      await tester.pumpWidget(CloudApp(controller: controller));
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      expect(chips.map((c) => (c.label as Text).data), [
        'All',
        'Recent',
        'New',
        'Cloud',
        'Local',
      ]);
      expect(chips.map((c) => c.key), [
        for (final policy in LibraryPolicy.values)
          ValueKey('policy:${policy.name}'),
      ]);
      for (final policy in LibraryPolicy.values) {
        await choose(tester, policy);
        final selected = tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .where((c) => c.selected)
            .map((c) => c.key);
        expect(selected, [ValueKey('policy:${policy.name}')]);
      }
    });

    testWidgets('Recent and New show flat dated files with no folder rows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.entries = fixture();
      await tester.pumpWidget(CloudApp(controller: controller));
      await choose(tester, LibraryPolicy.recent);
      expect(find.byKey(const ValueKey('card:Docs')), findsNothing);
      expect(
        find.byKey(const ValueKey('date:Docs/Old/draft.txt')),
        findsOneWidget,
      );
      expect(find.text('Modified 2 Nov 2026, 14:05'), findsOneWidget);
      expect(find.text('Date unknown'), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('card:Docs/Old/draft.txt')))
            .dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('card:legacy.txt'))).dy,
        ),
      );
      // Flat like search: no indentation, Show in folder available.
      expect(
        tester
            .widget<LibraryEntryCard>(
              find.byKey(const ValueKey('row:Docs/Old/draft.txt')),
            )
            .flat,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('show-in-folder:Docs/Old/draft.txt')),
        findsOneWidget,
      );
      await choose(tester, LibraryPolicy.added);
      expect(find.text('Added 2 Nov 2026, 10:00'), findsOneWidget);
      expect(find.text('Added earlier'), findsNWidgets(3));
      expect(find.text('Cloud'), findsWidgets);
    });

    for (final count in [0, 20, 21, 45]) {
      testWidgets('paging with $count files: 20, More adds 20, Less resets', (
        tester,
      ) async {
        controller.entries = many(count);
        await tester.pumpWidget(CloudApp(controller: controller));
        for (final policy in [LibraryPolicy.recent, LibraryPolicy.added]) {
          await choose(tester, policy);
          if (count == 0) {
            expect(find.text('No files yet.'), findsOneWidget);
            expect(find.byType(LibraryList), findsNothing);
            continue;
          }
          final first = count < 20 ? count : 20;
          final pager = count > 20 ? 1 : 0;
          expect(listed(tester), first + pager, reason: '$policy');
          await toEnd(tester);
          expect(more(), count > 20 ? findsOneWidget : findsNothing);
          expect(less(), findsNothing);
          var shown = first;
          while (shown < count) {
            await tester.tap(more());
            await tester.pumpAndSettle();
            shown = shown + 20 > count ? count : shown + 20;
            expect(listed(tester), shown + 1);
            await toEnd(tester);
            expect(less(), findsOneWidget);
            expect(more(), shown < count ? findsOneWidget : findsNothing);
          }
          if (count > 20) {
            // Centred, borderless, theme-blue text buttons.
            final button = tester.widget<TextButton>(less());
            expect(button.style, isNull);
            final scheme = Theme.of(tester.element(less())).colorScheme;
            final label = tester.renderObject<RenderParagraph>(
              find.descendant(of: less(), matching: find.byType(RichText)),
            );
            expect(label.text.style?.color, scheme.primary);
            final listRect = tester.getRect(find.byType(LibraryList));
            expect(
              (tester.getCenter(less()).dx - listRect.center.dx).abs(),
              lessThan(1),
            );
            await tester.tap(less());
            await tester.pumpAndSettle();
            expect(listed(tester), 21);
            await toEnd(tester);
            expect(less(), findsNothing);
            expect(more(), findsOneWidget);
          }
        }
        // Another chip starts again at the first page.
        if (count > 20) {
          await choose(tester, LibraryPolicy.recent);
          await toEnd(tester);
          await tester.tap(more());
          await tester.pumpAndSettle();
          await choose(tester, LibraryPolicy.added);
          expect(listed(tester), 21);
        }
      });
    }

    testWidgets('search gives the same results under every chip and the '
        'chip returns when search is cleared', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.entries = fixture();
      await tester.pumpWidget(CloudApp(controller: controller));
      List<String> cards() => tester
          .widgetList<LibraryEntryCard>(find.byType(LibraryEntryCard))
          .map((card) => card.row.path)
          .toList();
      await search(tester, 'docs/');
      final expected = cards();
      expect(expected, hasLength(4));
      for (final policy in LibraryPolicy.values) {
        await choose(tester, policy);
        expect(cards(), expected, reason: '$policy');
        expect(find.textContaining('Modified '), findsNothing);
        await search(tester, 'no such file');
        expect(find.text('No files match your search.'), findsOneWidget);
        await search(tester, 'docs/');
      }
      await choose(tester, LibraryPolicy.recent);
      await search(tester, '');
      expect(
        tester.widget<ChoiceChip>(chip(LibraryPolicy.recent)).selected,
        isTrue,
      );
      expect(cards().first, 'Docs/Old/draft.txt');
      expect(find.text('Date unknown'), findsOneWidget);
    });

    testWidgets('evidence: each chip on a synthetic tree', (tester) async {
      final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.entries = [...fixture(), ...many(23)];
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: CloudApp(controller: controller),
        ),
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

      for (final policy in LibraryPolicy.values) {
        await choose(tester, policy);
        final name = 'chip-${policy.label.toLowerCase()}';
        await capture(name);
        if (!policy.ranked) continue;
        await toEnd(tester);
        await capture('$name-end');
        await tester.tap(find.byKey(const ValueKey('ranked-more')));
        await tester.pumpAndSettle();
        await toEnd(tester);
        await capture('$name-more-less');
      }
    });
  });

  group('engine', () {
    late Directory dir;
    late RootTree tree;
    late Manifest store;
    late FakeCloud cloud;
    late SyncEngine engine;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('anj-recent-new-');
      final parent = Directory('${dir.path}/root')..createSync();
      tree = RootTree.setup(parent.path, 'root', NativeRootFs());
      store = Manifest(Directory('${dir.path}/profile'));
      store.setSetting('retention', 'local');
      cloud = FakeCloud();
      engine = SyncEngine(store, tree, cloud);
    });
    tearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });
    File local(String path) => File('${tree.root.path}/$path');

    test(
      'listing metadata and added times are stored per entry, fetched '
      'only when the listing changed, and written only when they change',
      () async {
        cloud.added = {};
        cloud.put('remote.txt', 'from another device', modifiedAt: 1793600000);
        cloud.added![cloud.fileIds['remote.txt']!] = 1793600001;
        local('mine.txt').writeAsStringSync('added here');
        await engine.tick();
        // The upload's file ID reaches the entry with the next listing.
        cloud.added![cloud.fileIds['mine.txt']!] = 1793600050;
        cloud.modified['mine.txt'] = 1793600049;
        await engine.tick();
        final remote = store.entries['remote.txt']!;
        final mine = store.entries['mine.txt']!;
        expect(
          (remote.fileId, remote.remoteModified, remote.addedAt),
          (cloud.fileIds['remote.txt'], 1793600000, 1793600001),
        );
        expect(
          (mine.fileId, mine.addedAt),
          (cloud.fileIds['mine.txt'], 1793600050),
        );
        expect(mine.localModified, isNotNull);
        final fetches = cloud.addedFetches;
        final after = cloud.addedAfter.last;
        expect(after, greaterThan(0), reason: 'the cursor advanced');
        await engine.tick();
        expect(cloud.addedFetches, fetches, reason: 'listing unchanged');
        expect(engine.lastPass!.rowsWritten, 0);
        cloud.put('later.txt', 'new');
        cloud.added![cloud.fileIds['later.txt']!] = 1793600100;
        await engine.tick();
        expect(cloud.addedFetches, fetches + 1);
        // Incremental: resumes after the last row already fetched.
        expect(cloud.addedAfter.last, greaterThan(after));
        expect(cloud.addedAfter.last, cloud.fileIds['mine.txt']);
        expect(store.entries['later.txt']!.addedAt, 1793600100);
        // Dates persist: a restart shows them before any fetch.
        engine.close();
        store = Manifest(Directory('${dir.path}/profile'));
        expect(store.entries['remote.txt']!.addedAt, 1793600001);
        tree = RootTree(
          Directory('${dir.path}/root/anj-cloud'),
          Directory('${dir.path}/root/.anj-cloud-root'),
          NativeRootFs(),
        );
        engine = SyncEngine(store, tree, cloud);
      },
    );

    test('pages and a reset rebuild the map', () async {
      cloud.added = {};
      cloud.addedPage = 2;
      for (var i = 0; i < 5; i++) {
        cloud.put('f$i.txt', '$i');
        cloud.added![cloud.fileIds['f$i.txt']!] = 1793600000 + i;
      }
      await engine.tick();
      expect(cloud.addedFetches, 3);
      for (var i = 0; i < 5; i++) {
        expect(store.entries['f$i.txt']!.addedAt, 1793600000 + i);
      }
      // A replaced registry: the client starts again from 0.
      cloud.resetAdded = true;
      cloud.put('g.txt', 'g');
      cloud.added![cloud.fileIds['g.txt']!] = 1793600009;
      cloud.added![cloud.fileIds['f0.txt']!] = 1793600008;
      await engine.tick();
      expect(cloud.addedAfter.skip(3).first, greaterThan(0));
      expect(cloud.addedAfter.skip(4).first, 0);
      expect(store.entries['g.txt']!.addedAt, 1793600009);
      expect(store.entries['f0.txt']!.addedAt, 1793600008);
    });

    test('an older gateway (404) or a failed fetch leaves New ordered and '
        'undated without failing the pass', () async {
      cloud.put('a.txt', 'a');
      cloud.put('b.txt', 'b');
      await engine.tick();
      expect(engine.message, startsWith('Reconciled'));
      expect(cloud.addedFetches, 1);
      expect(
        store.entries['b.txt']!.fileId,
        greaterThan(store.entries['a.txt']!.fileId!),
      );
      expect(store.entries['a.txt']!.addedAt, isNull);
      cloud.added = {store.entries['a.txt']!.fileId!: 1793600000};
      cloud.failAdded = true;
      cloud.put('c.txt', 'c');
      await engine.tick();
      expect(engine.message, startsWith('Reconciled'));
      expect(store.entries['c.txt']!.fileId, isNotNull);
      expect(store.entries['a.txt']!.addedAt, isNull);
    });

    test('Recent ranks an unsynced local edit by its local time', () async {
      cloud.put('a.txt', 'a', modifiedAt: 100);
      await engine.tick();
      final entry = store.entries['a.txt']!;
      var projected = await projectEntry(engine, entry);
      expect(projected['pendingLocalEdit'], isFalse);
      expect(recentTime(projected), 100);
      cloud.online = false; // The edit stays pending.
      local('a.txt').writeAsStringSync('edited here');
      await engine.tick();
      projected = await projectEntry(engine, entry);
      expect(projected['pendingLocalEdit'], isTrue);
      expect(recentTime(projected), entry.localModified);
      expect(entry.localModified, greaterThan(100));
    });
  });
}
