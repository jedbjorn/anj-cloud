import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/app/lifecycle.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_activity.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dbus_harness.dart' show eventually;
import 'fakes.dart';

Map<String, dynamic> _file(
  String path, {
  String status = 'current local',
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': 'file',
  'selectionVersion': '1',
  'status': status,
  'effectiveRetention': 'local',
  ...extra,
};

Map<String, dynamic> _dir(String path) => {
  'path': path,
  'kind': 'directory',
  'selectionVersion': '1',
  'status': 'current local',
  'effectiveRetention': 'local',
};

const _deep = 'Projects/2026/Q4/drafts/report.docx';

class _Controller extends ClientController {
  _Controller(super.profile);
  void report(Set<String> paths) {
    syncing = paths;
    notifyListeners();
  }

  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {}
}

class _Window implements WindowControl {
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> exit() async {}
}

class _Tray implements TrayControl {
  @override
  bool get hostAvailable => true;
  @override
  Stream<bool> get hostChanges => const Stream.empty();
  @override
  Future<void> setState(SyncStatus status, {required bool paused}) async {}
  @override
  Future<void> close() async {}
}

/// While [release] is set, uploads wait until it completes.
class _HeldCloud extends FakeCloud {
  final held = <String>[];
  Completer<void>? release = Completer<void>();

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    final wait = release;
    if (wait != null) {
      held.add(path);
      await wait.future;
    }
    return super.upload(path, source, etag: etag);
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

  Color bar(WidgetTester tester, String path) {
    final container = tester.widget<Container>(
      find.byKey(ValueKey('attention:$path')),
    );
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.left.width, 3, reason: path);
    return border.left.color;
  }

  Finder spinning(String path) => find.descendant(
    of: find.byKey(ValueKey('syncing-icon:$path')),
    matching: find.byType(RotationTransition),
  );

  // The syncing icon repeats, so the tree never settles: pump frames.
  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> expand(WidgetTester tester, List<String> paths) async {
    for (final path in paths) {
      await tester.tap(find.byKey(ValueKey('toggle:$path')));
      await frames(tester);
    }
  }

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

  group('library rows', () {
    final entries = [
      _dir('Projects'),
      _dir('Projects/2026'),
      _dir('Projects/2026/Q4'),
      _dir('Projects/2026/Q4/drafts'),
      _file(_deep),
      _file('Projects/2026/Q4/plan.txt'),
      _dir('Projects/2025'),
      _file('Projects/2025/old.txt'),
      _dir('Music'),
      _file('Music/song.mp3'),
    ];

    test('every ancestor of a syncing file is marked, to the top', () {
      final rows = libraryRows(entries, LibraryTab.home, {}, syncing: {_deep});
      expect(rows.where((r) => r.syncingWithin).map((r) => r.path).toList(), [
        'Projects',
        'Projects/2026',
        'Projects/2026/Q4',
        'Projects/2026/Q4/drafts',
      ]);
      expect(rows.where((r) => r.syncing).map((r) => r.path), [_deep]);
      expect(rows.firstWhere((r) => r.path == _deep).syncingWithin, isFalse);
    });

    test('collapsed folders and file-only search keep the marks', () {
      // Collapsed: the hidden file still marks the top folder.
      final collapsed = libraryRows(
        entries,
        LibraryTab.home,
        {'Projects', 'Music'},
        syncing: {_deep},
      );
      expect(collapsed.map((r) => r.path), ['Music', 'Projects']);
      expect(collapsed.last.syncingWithin, isTrue);
      expect(collapsed.first.syncingWithin, isFalse);
      // Search shows files only; the file keeps its own mark.
      final found = libraryRows(
        entries,
        LibraryTab.home,
        {},
        search: 'report',
        syncing: {_deep},
      );
      expect(found.single.syncing, isTrue);
      // Synthetic ancestors of a sparse catalogue are marked too.
      final sparse = libraryRows(
        [_file('a/b/c/d/e/f/g.txt')],
        LibraryTab.home,
        {},
        syncing: {'a/b/c/d/e/f/g.txt'},
      );
      expect(sparse.where((r) => r.syncingWithin).length, 6);
    });

    test('a file new during the pass gets a provisional row and bars', () {
      // The catalogue (last post-pass state) does not list it yet, nor its
      // new folder.
      const fresh = 'Projects/2026/Q4/scans/new.pdf';
      final rows = libraryRows(entries, LibraryTab.home, {}, syncing: {fresh});
      final row = rows.firstWhere((r) => r.path == fresh);
      expect(row.syncing, isTrue);
      expect(row.entry['synthetic'], isTrue);
      expect(row.entry['provisional'], isTrue);
      expect(rows.where((r) => r.syncingWithin).map((r) => r.path).toList(), [
        'Projects',
        'Projects/2026',
        'Projects/2026/Q4',
        'Projects/2026/Q4/scans',
      ]);
      // Its storage choice is not known: shown under All, not Local/Cloud.
      expect(
        libraryRows(
          entries,
          LibraryTab.home,
          {},
          policy: LibraryPolicy.local,
          syncing: {fresh},
        ).map((r) => r.path),
        isNot(contains(fresh)),
      );
      // Gone once the transfer ends.
      expect(
        libraryRows(entries, LibraryTab.home, {}).map((r) => r.path),
        isNot(contains(fresh)),
      );
    });

    test('a file that needs attention stays amber, never syncing', () {
      final failing = [
        ...entries,
        _file('Music/huge.flac', status: 'pending: upload refused (413)'),
      ];
      final rows = libraryRows(
        failing,
        LibraryTab.home,
        {},
        syncing: {'Music/huge.flac'},
      );
      final file = rows.firstWhere((r) => r.path == 'Music/huge.flac');
      expect(file.syncing, isFalse);
      expect(file.attention, isTrue);
      expect(rows.firstWhere((r) => r.path == 'Music').syncingWithin, isFalse);
      expect(activeSyncing(failing, {'Music/huge.flac', _deep}), {_deep});
    });

    test('the header says how many files are syncing', () {
      expect(headerStatus(SyncStatus.upToDate, 0).label, 'Up to date');
      expect(headerStatus(SyncStatus.upToDate, 1).label, 'Syncing 1 file');
      expect(headerStatus(SyncStatus.syncing, 3), (
        status: SyncStatus.syncing,
        label: 'Syncing 3 files',
      ));
      // More significant states keep their own label.
      for (final status in [
        SyncStatus.paused,
        SyncStatus.offline,
        SyncStatus.attention,
      ]) {
        expect(headerStatus(status, 4), (status: status, label: status.label));
      }
    });

    test('nothing is marked once the transfer clears', () {
      final rows = libraryRows(entries, LibraryTab.home, {});
      expect(rows.any((r) => r.syncing || r.syncingWithin), isFalse);
    });
  });

  test('a paused controller reports nothing as syncing', () {
    final profile = Directory.systemTemp.createTempSync('anj-activity-');
    addTearDown(() => profile.deleteSync(recursive: true));
    final controller = _Controller(profile)..syncing = {_deep};
    addTearDown(controller.dispose);
    expect(controller.syncing, {_deep});
    controller.paused = true;
    expect(controller.syncing, isEmpty);
    controller.paused = false;
    expect(controller.syncing, {_deep});
  });

  group('worker activity events', () {
    late Directory fixture;
    late Directory profile;
    late RootTree tree;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('anj-activity-worker-');
      profile = Directory('${fixture.path}/profile');
      final parent = Directory('${fixture.path}/files')..createSync();
      tree = RootTree.setup(parent.path, 'activity', NativeRootFs());
      Manifest(profile)
        ..setSetting('retention', 'local')
        ..close();
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    ({WorkerLoop loop, Future<void> done, StreamController<Object?> input})
    start(
      FakeCloud cloud,
      List<Map> events, {
      Duration activityInterval = const Duration(milliseconds: 500),
    }) {
      final activity = SyncActivity();
      final gate = PausableCloud(cloud);
      final engine = SyncEngine(
        Manifest(profile),
        RootTree(tree.root, tree.staging, NativeRootFs()),
        ActivityCloud(gate, activity),
        activity: activity,
      );
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        engine,
        (event) => events.add(event as Map),
        interval: const Duration(seconds: 30),
        gate: gate,
        activityInterval: activityInterval,
      );
      return (loop: loop, done: loop.run(input.stream), input: input);
    }

    List<List<String>> activity(List<Map> events) => [
      for (final event in events)
        if (event['event'] == 'activity') (event['paths'] as List).cast(),
    ];

    test(
      'an in-flight upload is reported, then cleared when it completes',
      () async {
        Directory('${tree.root.path}/a/b/c').createSync(recursive: true);
        File('${tree.root.path}/a/b/c/note.txt').writeAsStringSync('hello');
        final cloud = _HeldCloud();
        final events = <Map>[];
        final worker = start(cloud, events);
        await eventually(() => cloud.held.isNotEmpty);
        expect(activity(events).last, ['a/b/c/note.txt']);
        // Directories are never reported themselves: the UI derives them.
        expect(activity(events).expand((v) => v), isNot(contains('a/b/c')));
        cloud.release!.complete();
        await eventually(
          () =>
              events.any(
                (e) =>
                    e['event'] == 'state' &&
                    (e['entries'] as List).any(
                      (v) =>
                          v['path'] == 'a/b/c/note.txt' &&
                          v['status'] == 'current local',
                    ),
              ) &&
              activity(events).last.isEmpty,
        );
        // Cleared before the state that shows the finished file.
        final cleared = events.lastIndexWhere(
          (e) => e['event'] == 'activity' && (e['paths'] as List).isEmpty,
        );
        final finished = events.lastIndexWhere((e) => e['event'] == 'state');
        expect(cleared, lessThan(finished));
        worker.input.add({'action': 'stop'});
        await worker.done;
      },
    );

    test(
      'many transfers coalesce into a few events, not one per file',
      () async {
        for (var i = 0; i < 20; i++) {
          File('${tree.root.path}/batch-$i.txt').writeAsStringSync('$i');
        }
        final cloud = FakeCloud();
        final events = <Map>[];
        final worker = start(
          cloud,
          events,
          activityInterval: const Duration(seconds: 30),
        );
        await eventually(
          () => cloud.uploads == 20 && events.any((e) => e['event'] == 'state'),
        );
        // The committed queue once, then the clear: no per-file events.
        expect(activity(events), hasLength(2));
        expect(activity(events).first, hasLength(20));
        expect(activity(events).last, isEmpty);
        expect(worker.loop.activityEmitted, 2);
        worker.input.add({'action': 'stop'});
        await worker.done;
      },
    );
  });

  testWidgets(
    'a file new during a pass shows its icon and folder bars before it ends',
    (tester) async {
      late Directory fixture;
      late _HeldCloud cloud;
      late ({
        WorkerLoop loop,
        Future<void> done,
        StreamController<Object?> input,
      })
      worker;
      final events = <Map>[];
      Map? lastState() =>
          events.lastWhere((e) => e['event'] == 'state', orElse: () => {});
      bool listed(String path) => ((lastState()?['entries'] as List?) ?? [])
          .any((v) => v['path'] == path);
      await tester.runAsync(() async {
        fixture = Directory.systemTemp.createTempSync('anj-activity-new-');
        final profile = Directory('${fixture.path}/profile');
        final parent = Directory('${fixture.path}/files')..createSync();
        final tree = RootTree.setup(parent.path, 'fresh', NativeRootFs());
        Manifest(profile)
          ..setSetting('retention', 'local')
          ..close();
        Directory('${tree.root.path}/Photos').createSync();
        File('${tree.root.path}/Photos/old.jpg').writeAsStringSync('old');
        cloud = _HeldCloud()..release = null;
        final activity = SyncActivity();
        final gate = PausableCloud(cloud);
        final engine = SyncEngine(
          Manifest(profile),
          RootTree(tree.root, tree.staging, NativeRootFs()),
          ActivityCloud(gate, activity),
          activity: activity,
        );
        final input = StreamController<Object?>();
        final loop = WorkerLoop(
          engine,
          (event) => events.add(event as Map),
          interval: const Duration(minutes: 5),
          gate: gate,
        );
        worker = (loop: loop, done: loop.run(input.stream), input: input);
        // Pass 1 synchronizes Photos/old.jpg.
        await eventually(() => listed('Photos/old.jpg'));
        // The user drops a new photo; the next pass holds its upload.
        cloud.release = Completer<void>();
        File('${tree.root.path}/Photos/new.jpg').writeAsStringSync('new');
        input.add({'action': 'tick'});
        await eventually(() => cloud.held.contains('Photos/new.jpg'));
        // Coalesced: the event follows within one activity interval.
        await eventually(
          () =>
              (events.lastWhere((e) => e['event'] == 'activity')['paths']
                      as List)
                  .isNotEmpty,
        );
      });
      // Mid-pass: the catalogue does not list the file yet.
      expect(listed('Photos/new.jpg'), isFalse);
      final paths =
          events.lastWhere((e) => e['event'] == 'activity')['paths'] as List;
      expect(paths, ['Photos/new.jpg']);

      // The UI sees exactly what the worker sent.
      final profile = Directory.systemTemp.createTempSync('anj-activity-ui-');
      final controller = _Controller(profile)
        ..root = '/synthetic/files'
        ..entries = [
          for (final entry in lastState()!['entries'] as List)
            Map<String, dynamic>.from(entry as Map),
        ];
      controller.report(paths.cast<String>().toSet());
      tester.view.physicalSize = const Size(1280, 720);
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
      await frames(tester);
      // Collapsed by default: the folder bar points inward.
      expect(bar(tester, 'Photos'), syncBarColor);
      expect(find.text('Syncing 1 file'), findsOneWidget);
      await expand(tester, ['Photos']);
      expect(spinning('Photos/new.jpg'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('entry-icon:Photos/old.jpg')),
        findsOneWidget,
      );
      await preview(tester, boundary, 'new-file-mid-pass');

      await tester.runAsync(() async {
        cloud.release!.complete();
        await eventually(
          () =>
              listed('Photos/new.jpg') &&
              (events.lastWhere((e) => e['event'] == 'activity')['paths']
                      as List)
                  .isEmpty,
        );
        worker.input.add({'action': 'stop'});
        await worker.done;
      });
      controller
        ..entries = [
          for (final entry in lastState()!['entries'] as List)
            Map<String, dynamic>.from(entry as Map),
        ]
        ..report({});
      await frames(tester);
      expect(find.byType(SyncingIcon), findsNothing);
      expect(bar(tester, 'Photos'), Colors.transparent);
      expect(
        find.byKey(const ValueKey('entry-icon:Photos/new.jpg')),
        findsOneWidget,
      );
      expect(find.text('Up to date'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      profile.deleteSync(recursive: true);
      fixture.deleteSync(recursive: true);
    },
  );

  group('worker activity cost', () {
    late Directory fixture;
    late RootTree tree;
    late Directory profile;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('anj-activity-cost-');
      profile = Directory('${fixture.path}/profile');
      final parent = Directory('${fixture.path}/files')..createSync();
      tree = RootTree.setup(parent.path, 'cost', NativeRootFs());
      Manifest(profile)
        ..setSetting('retention', 'local')
        ..close();
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    /// One pass's worth of queue churn: plan [count] files, retire each.
    Duration churn(int count) {
      final engine = SyncEngine(
        Manifest(profile),
        RootTree(tree.root, tree.staging, NativeRootFs()),
        FakeCloud(),
      );
      final events = <Object?>[];
      final loop = WorkerLoop(
        engine,
        events.add,
        activityInterval: const Duration(hours: 1),
      );
      final paths = [for (var i = 0; i < count; i++) 'dir/file-$i.bin'];
      final watch = Stopwatch()..start();
      engine.activity.plan(paths);
      for (final path in paths) {
        engine.activity.retire(path);
      }
      watch.stop();
      // Coalesced: the queue once, then the clear.
      expect(loop.activityEmitted, 2);
      engine.close();
      return watch.elapsed;
    }

    Duration best(int count) =>
        [for (var i = 0; i < 3; i++) churn(count)]
            .reduce((a, b) => a < b ? a : b);

    test('activity updates stay linear in the queue length', () {
      final small = best(20000);
      final large = best(80000);
      // Linear is ~4x; the former quadratic path was ~16x (6.4 s at 20k).
      expect(
        large,
        lessThan(small * 8 + const Duration(milliseconds: 50)),
        reason: '20k: $small, 80k: $large',
      );
      expect(large, lessThan(const Duration(seconds: 2)));
    });
  });

  group('library indicators', () {
    late Directory profile;
    late _Controller controller;

    setUp(() {
      profile = Directory.systemTemp.createTempSync('anj-activity-ui-');
      controller = _Controller(profile)
        ..root = '/synthetic/files'
        ..entries = [
          _dir('Projects'),
          _dir('Projects/2026'),
          _dir('Projects/2026/Q4'),
          _dir('Projects/2026/Q4/drafts'),
          _file(_deep, status: 'queued'),
          _file('Projects/2026/Q4/plan.txt'),
          _dir('Photos'),
          _file('Photos/new.jpg', status: 'queued'),
          _file(
            'Photos/beach.jpg',
            status: 'upload failed: server unavailable',
          ),
          _dir('Music'),
          _file('Music/song.mp3'),
        ];
    });
    tearDown(() {
      controller.dispose();
      profile.deleteSync(recursive: true);
    });

    Future<void> show(
      WidgetTester tester,
      GlobalKey boundary, {
      DesktopLifecycle? lifecycle,
    }) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: CloudApp(controller: controller, lifecycle: lifecycle),
        ),
      );
      await tester.pumpAndSettle();
      await expand(tester, [
        'Projects',
        'Projects/2026',
        'Projects/2026/Q4',
        'Projects/2026/Q4/drafts',
        'Photos',
      ]);
      // Nothing syncs yet, so the tap ripples are the only animations.
      await tester.pumpAndSettle();
    }

    testWidgets('blue folders lead to a turning sync icon; cleared on finish', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await show(tester, boundary);
      // Idle: no indicator, no animation controller, no ticker.
      expect(find.byType(SyncingIcon), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      for (final path in ['Projects', 'Projects/2026/Q4/drafts', 'Music']) {
        expect(bar(tester, path), Colors.transparent, reason: path);
      }
      await preview(tester, boundary, 'before-idle');

      expect(find.text('Up to date'), findsOneWidget);
      controller.report({_deep, 'Photos/new.jpg'});
      await frames(tester);
      expect(find.text('Syncing 2 files'), findsOneWidget);
      for (final path in [
        'Projects',
        'Projects/2026',
        'Projects/2026/Q4',
        'Projects/2026/Q4/drafts',
      ]) {
        expect(bar(tester, path), syncBarColor, reason: path);
      }
      // Files never take the folder bar; the syncing file shows the icon.
      expect(bar(tester, _deep), Colors.transparent);
      expect(bar(tester, 'Projects/2026/Q4/plan.txt'), Colors.transparent);
      expect(bar(tester, 'Music'), Colors.transparent);
      expect(find.byKey(const ValueKey('entry-icon:$_deep')), findsNothing);
      expect(spinning(_deep), findsOneWidget);
      expect(
        find.byKey(const ValueKey('entry-icon:Projects/2026/Q4/plan.txt')),
        findsOneWidget,
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      final semantics = tester.ensureSemantics();
      await tester.pump();
      // The row's button announces it first: "Syncing, report.docx".
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('syncing-icon:$_deep')))
            .label,
        startsWith('Syncing\nreport.docx'),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey('entry-icon:Projects/2026/Q4/plan.txt'),
              ),
            )
            .label,
        isNot(contains('Syncing')),
      );
      // The blue bar is announced on its folder; amber keeps its own text.
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('entry-icon:Projects')))
            .label,
        startsWith('Syncing inside this folder\nProjects'),
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('entry-icon:Photos')))
            .label,
        allOf(
          contains('Needs attention in this folder'),
          isNot(contains('Syncing inside')),
        ),
      );
      semantics.dispose();
      // Amber (needs attention) outranks blue (information) on one folder.
      expect(bar(tester, 'Photos'), attentionBarColor);
      expect(bar(tester, 'Photos/beach.jpg'), attentionBarColor);
      await preview(tester, boundary, 'after-syncing');

      // Finished: back to the normal icon and plain bars; ticker gone.
      controller.report({});
      await frames(tester);
      expect(find.byType(SyncingIcon), findsNothing);
      expect(find.byKey(const ValueKey('entry-icon:$_deep')), findsOneWidget);
      expect(bar(tester, 'Projects'), Colors.transparent);
      expect(bar(tester, 'Projects/2026/Q4/drafts'), Colors.transparent);
      expect(bar(tester, 'Photos'), attentionBarColor);
      expect(find.text('Up to date'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a paused client shows nothing as syncing', (tester) async {
      await show(tester, GlobalKey());
      controller.report({_deep});
      await frames(tester);
      expect(find.byType(SyncingIcon), findsOneWidget);
      controller.setPaused(true);
      await frames(tester);
      expect(find.byType(SyncingIcon), findsNothing);
      expect(find.text('Paused'), findsOneWidget);
      expect(bar(tester, 'Projects'), Colors.transparent);
      expect(tester.binding.transientCallbackCount, 0);
      controller.setPaused(false);
      await frames(tester);
      expect(spinning(_deep), findsOneWidget);
      controller.report({});
      await frames(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion shows the static sync icon', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await show(tester, GlobalKey());
      controller.report({_deep});
      await frames(tester);
      expect(find.byKey(const ValueKey('syncing-icon:$_deep')), findsOneWidget);
      expect(spinning(_deep), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('syncing-icon:$_deep')),
          matching: find.byIcon(Icons.sync),
        ),
        findsOneWidget,
      );
      expect(bar(tester, 'Projects'), syncBarColor);
      expect(tester.binding.transientCallbackCount, 0);
      controller.report({});
      await frames(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a window hidden in the tray runs no ticker', (tester) async {
      final lifecycle = DesktopLifecycle(
        window: _Window(),
        stopSync: () async => true,
        tray: _Tray(),
      );
      addTearDown(lifecycle.dispose);
      await show(tester, GlobalKey(), lifecycle: lifecycle);
      controller.report({_deep});
      await frames(tester);
      expect(spinning(_deep), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await lifecycle.closeRequested();
      await frames(tester);
      expect(lifecycle.visible, isFalse);
      expect(find.byKey(const ValueKey('syncing-icon:$_deep')), findsOneWidget);
      expect(spinning(_deep), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);

      await lifecycle.open();
      await frames(tester);
      expect(spinning(_deep), findsOneWidget);
      controller.report({});
      await frames(tester);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
