// Spec #42 F5 (acceptance row "Tab behaviour"): the Downloader tab over a
// FakeFetch. The tab is there only while the server offers it; every row
// state with its actions; submit with its outcomes; polling follows the tab
// and the app being on screen; phone and desktop sizes without overflow.
//
// With ANJ_UI_FONT_DIR (the SDK's material_fonts) and ANJ_F22_PREVIEWS (a
// directory) set, the screens are also written as readable PNG previews.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/fetch_jobs.dart';
import 'package:anj_cloud/core/app/lifecycle.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/downloader_tab.dart';
import 'package:anj_cloud/ui/library_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'layout_fixtures.dart';

/// Polls never fire by themselves in these tests.
class _IdleTimer implements Timer {
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
  @override
  int get tick => 0;
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

final _long =
    'https://media.example.com/watch?v=a-very-long-identifier-that-goes${'-on-and-on' * 30}';

/// One row in every state, newest first.
final mixed = [
  FetchJob(
    id: 'w',
    state: FetchState.waiting,
    kind: FetchKind.audio,
    url: _long,
  ),
  const FetchJob(
    id: 'c',
    state: FetchState.checking,
    kind: FetchKind.video,
    url: 'https://media.example.com/clip',
  ),
  const FetchJob(
    id: 'd',
    state: FetchState.downloading,
    kind: FetchKind.video,
    title: 'A walk along the coast in early spring, filmed in one take',
    url: 'https://media.example.com/walk',
    percent: 42.7,
  ),
  const FetchJob(
    id: 'p',
    state: FetchState.placing,
    kind: FetchKind.audio,
    title: 'Evening radio hour',
  ),
  const FetchJob(
    id: 'ok',
    state: FetchState.done,
    kind: FetchKind.audio,
    title: 'Morning songs',
    path: 'Music/Morning songs.m4a',
  ),
  const FetchJob(
    id: 'low',
    state: FetchState.done,
    kind: FetchKind.video,
    title: 'Harbour at night',
    path: 'Videos/Harbour at night.mp4',
    height: 480,
  ),
  const FetchJob(
    id: 'f',
    state: FetchState.failed,
    kind: FetchKind.video,
    title: 'Lecture, part two',
    message: 'The site did not answer. Try again later.',
  ),
  const FetchJob(
    id: 'r',
    state: FetchState.rejected,
    kind: FetchKind.audio,
    url: 'https://media.example.com/live',
    message: 'Live streams are not supported.',
  ),
  const FetchJob(
    id: 'x',
    state: FetchState.cancelled,
    kind: FetchKind.audio,
    title: 'Cancelled talk',
  ),
  const FetchJob(id: 'u', state: FetchState.unknown, rawState: 'converting'),
];

class _Home {
  _Home(this.controller, this.fetch, this.jobs);
  final LayoutController controller;
  final FakeFetch fetch;
  final FetchJobs jobs;
}

final _boundary = GlobalKey();
final _previews = Platform.environment['ANJ_F22_PREVIEWS'];

Future<_Home> _open(
  WidgetTester tester, {
  Size size = const Size(1280, 720),
  double scale = 1,
  List<FetchJob>? rows = const [],
  bool probe = true,
  bool touch = false,
  DesktopLifecycle? lifecycle,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  // The syncing icon turns forever otherwise; pumpAndSettle needs an end.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final fetch = FakeFetch()..rows = rows;
  final jobs = FetchJobs(
    fetch,
    requestSync: () {},
    timer: (_, _) => _IdleTimer(),
  );
  final controller = layoutController()..fetch = jobs;
  addTearDown(controller.dispose);
  addTearDown(jobs.dispose);
  if (probe) await jobs.probe('https://gateway.example.com');
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: CloudApp(
        controller: controller,
        lifecycle: lifecycle,
        rootPicker: !touch,
        touchInput: touch,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Home(controller, fetch, jobs);
}

/// Selects a home tab; at a large font the tabs may scroll sideways.
Future<void> _tab(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  final tab = find.widgetWithText(Tab, label);
  await tester.ensureVisible(tab);
  await tester.pump();
  await tester.tap(tab);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A bar without a value never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Back to the top of the tab, where the form is.
Future<void> _top(WidgetTester tester) async {
  tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('downloader-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('downloader-links')), text);
  await tester.pumpAndSettle();
}

Future<void> _download(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('downloader-submit')));
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed !=
    null;

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('downloader-links')))
    .controller!
    .text;

int _selectedTab(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('downloader-list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

/// No overflow or other error, and every control inside the screen's width.
Future<void> _check(WidgetTester tester, String screen) async {
  expect(tester.takeException(), isNull, reason: screen);
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  bool control(Widget widget) =>
      widget is ButtonStyleButton ||
      widget is IconButton ||
      widget is ChipAttributes ||
      widget is TextField;
  for (final element in find.byWidgetPredicate(control).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    // The home tabs may scroll sideways at a large font, as the Admin tabs.
    if (Scrollable.maybeOf(element, axis: Axis.horizontal) != null) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    expect(
      rect.left >= -0.5 && rect.right <= width + 0.5,
      isTrue,
      reason:
          '$screen: ${element.widget.runtimeType} at $rect leaves the screen',
    );
  }
  // The tab itself never scrolls sideways.
  expect(
    find.descendant(
      of: find.byType(DownloaderTab),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            axisDirectionToAxis(widget.axisDirection) == Axis.horizontal,
      ),
    ),
    findsNothing,
    reason: screen,
  );
  await _preview(tester, screen);
}

Future<void> _preview(WidgetTester tester, String screen) async {
  final directory = _previews;
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$directory/$screen.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadPreviewFonts);

  group('the tab', () {
    testWidgets('is hidden until the server has answered', (tester) async {
      final home = await _open(tester, probe: false);
      expect(home.jobs.availability, FetchAvailability.unknown);
      expect(find.byType(Tab), findsNWidgets(3));
      expect(find.widgetWithText(Tab, 'Downloader'), findsNothing);
    });

    testWidgets('is hidden on a server without it', (tester) async {
      final home = await _open(tester, rows: null);
      expect(home.jobs.availability, FetchAvailability.absent);
      expect(find.byType(Tab), findsNWidgets(3));
      expect(find.widgetWithText(Tab, 'Downloader'), findsNothing);
    });

    testWidgets('is the fourth tab, without the library toolbar', (
      tester,
    ) async {
      await _open(tester);
      expect(tester.widgetList<Tab>(find.byType(Tab)).map((tab) => tab.text), [
        'Home',
        'Editing',
        'Conflict',
        'Downloader',
      ]);
      expect(find.byType(LibraryToolbar), findsOneWidget);
      await _tab(tester, 'Downloader');
      expect(find.byType(DownloaderTab), findsOneWidget);
      expect(find.byType(LibraryToolbar), findsNothing);
      expect(find.byKey(const ValueKey('downloader-empty')), findsOneWidget);
      await _tab(tester, 'Home');
      expect(find.byType(DownloaderTab), findsNothing);
      expect(find.byType(LibraryToolbar), findsOneWidget);
    });

    testWidgets('appears while another tab is selected, which stays', (
      tester,
    ) async {
      final home = await _open(tester, probe: false);
      await _tab(tester, 'Conflict');
      expect(find.byKey(const ValueKey('row:budget.ods')), findsOneWidget);
      await home.jobs.probe('https://gateway.example.com');
      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(4));
      expect(_selectedTab(tester), 2);
      expect(find.byKey(const ValueKey('row:budget.ods')), findsOneWidget);
      // The new tab works, and the old ones still do.
      await _tab(tester, 'Downloader');
      expect(find.byType(DownloaderTab), findsOneWidget);
      await _tab(tester, 'Editing');
      expect(find.byKey(const ValueKey('finish:notes.txt')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disappears while selected: Home is shown', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      expect(home.jobs.tabVisible, isTrue);
      home.fetch.rows = null;
      await home.jobs.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(3));
      expect(_selectedTab(tester), 0);
      expect(find.byType(DownloaderTab), findsNothing);
      expect(find.byType(LibraryToolbar), findsOneWidget);
      expect(find.byKey(const ValueKey('row:Documents')), findsOneWidget);
      expect(home.jobs.tabVisible, isFalse);
      await _tab(tester, 'Conflict');
      expect(find.byKey(const ValueKey('row:budget.ods')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disappears while another tab is selected, which stays', (
      tester,
    ) async {
      final home = await _open(tester);
      await _tab(tester, 'Editing');
      home.fetch.rows = null;
      await home.jobs.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(3));
      expect(_selectedTab(tester), 1);
      expect(find.byKey(const ValueKey('finish:notes.txt')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaves Select mode and the search shortcut to the library', (
      tester,
    ) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-count')), findsOneWidget);
      await _tab(tester, 'Downloader');
      expect(find.byKey(const ValueKey('selection-count')), findsNothing);
      await _tab(tester, 'Home');
      expect(find.byKey(const ValueKey('selection-count')), findsNothing);
      // On the Downloader Ctrl+F does nothing: there is no search there.
      await _tab(tester, 'Downloader');
      await _paste(tester, 'https://media.example.com/a');
      final focused = FocusManager.instance.primaryFocus;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-search')), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(find.byType(DownloaderTab), findsOneWidget);
      expect(_field(tester), 'https://media.example.com/a');
      await _tab(tester, 'Home');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .focusNode!
            .hasFocus,
        isFalse,
        reason: 'the shortcut was not kept for later',
      );
      // Ctrl+F still reaches the library's search.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('polling follows what is on screen', () {
    testWidgets('not while the first-sync screen covers the home', (
      tester,
    ) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      expect(home.jobs.tabVisible, isTrue);
      home.controller.firstSyncPending = true;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      home.controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsNothing);
      expect(home.jobs.tabVisible, isFalse);
      expect(home.jobs.visible, isFalse);
      home.controller.firstSyncPending = false;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      home.controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(DownloaderTab), findsOneWidget);
      expect(home.jobs.tabVisible, isTrue);
    });

    testWidgets('the tab being selected', (tester) async {
      final home = await _open(tester);
      expect(home.jobs.tabVisible, isFalse);
      final before = home.fetch.calls.length;
      await _tab(tester, 'Downloader');
      expect(home.jobs.tabVisible, isTrue);
      // Becoming visible lists once.
      expect(home.fetch.calls.length, before + 1);
      await _tab(tester, 'Conflict');
      expect(home.jobs.tabVisible, isFalse);
      await _tab(tester, 'Downloader');
      expect(home.jobs.tabVisible, isTrue);
    });

    testWidgets('the app in the foreground (Android)', (tester) async {
      final home = await _open(tester, touch: true);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await _tab(tester, 'Downloader');
      expect(home.jobs.appVisible, isTrue);
      expect(home.jobs.visible, isTrue);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        expect(home.jobs.appVisible, isFalse, reason: state.name);
        expect(home.jobs.visible, isFalse, reason: state.name);
      }
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(home.jobs.appVisible, isTrue);
      expect(home.jobs.visible, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('the window shown or hidden in the tray (desktop)', (
      tester,
    ) async {
      final lifecycle = DesktopLifecycle(
        window: _Window(),
        tray: _Tray(),
        stopSync: () async => true,
      );
      final home = await _open(tester, lifecycle: lifecycle);
      await _tab(tester, 'Downloader');
      expect(home.jobs.visible, isTrue);
      await lifecycle.closeRequested();
      expect(lifecycle.visible, isFalse);
      expect(home.jobs.appVisible, isFalse);
      expect(home.jobs.visible, isFalse);
      await lifecycle.open();
      expect(home.jobs.appVisible, isTrue);
      expect(home.jobs.visible, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('a window started hidden is not visible', (tester) async {
      final lifecycle = DesktopLifecycle(
        window: _Window(),
        tray: _Tray(),
        stopSync: () async => true,
        background: true,
      );
      final home = await _open(tester, lifecycle: lifecycle);
      expect(home.jobs.appVisible, isFalse);
    });
  });

  group('rows', () {
    testWidgets('every state has its words, progress and actions', (
      tester,
    ) async {
      await _open(tester, size: const Size(1280, 1400), rows: mixed);
      await _tab(tester, 'Downloader');
      String text(String key) =>
          tester.widget<Text>(find.byKey(ValueKey(key))).data!;
      const labels = {
        'w': 'Waiting',
        'c': 'Checking',
        'd': 'Downloading 42%',
        'p': 'Saving',
        'ok': 'Done',
        'low': 'Done · 480p',
        'f': "Couldn't download",
        'r': 'Not supported',
        'x': 'Cancelled',
        'u': 'In progress',
      };
      for (final MapEntry(key: id, value: label) in labels.entries) {
        expect(text('job-state:$id'), label, reason: id);
        final finished = mixed.firstWhere((job) => job.id == id).isFinished;
        expect(
          find.byKey(ValueKey('job-cancel:$id')),
          finished || id == 'p' ? findsNothing : findsOneWidget,
          reason: 'cancel $id',
        );
        expect(
          find.byKey(ValueKey('job-remove:$id')),
          finished ? findsOneWidget : findsNothing,
          reason: 'remove $id',
        );
        expect(
          find.byKey(ValueKey('job-show:$id')),
          id == 'ok' || id == 'low' ? findsOneWidget : findsNothing,
          reason: 'show $id',
        );
        expect(
          find.byKey(ValueKey('job-progress:$id')),
          id == 'd' ? findsOneWidget : findsNothing,
          reason: 'progress $id',
        );
      }
      // Newest first, as listed.
      final tops = [
        for (final job in mixed)
          tester.getTopLeft(find.byKey(ValueKey('job:${job.id}'))).dy,
      ];
      expect(tops, [...tops]..sort());
      // The link until the title is known.
      expect(text('job-title:w'), _long);
      expect(text('job-title:c'), 'https://media.example.com/clip');
      expect(
        text('job-title:d'),
        'A walk along the coast in early spring, filmed in one take',
      );
      expect(text('job-title:u'), 'Download');
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('job-progress:d')),
            )
            .value,
        closeTo(0.427, 1e-9),
      );
      // A finished row says why, and a placed file where.
      expect(
        text('job-message:f'),
        'The site did not answer. Try again later.',
      );
      expect(text('job-message:r'), 'Live streams are not supported.');
      expect(find.text('Music/Morning songs.m4a'), findsOneWidget);
      expect(find.text('Videos/Harbour at night.mp4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long message is cut after three lines', (tester) async {
      await _open(
        tester,
        size: const Size(360, 800),
        rows: [
          FetchJob(
            id: 'f',
            state: FetchState.failed,
            title: 'Lecture',
            message: 'The site did not answer. ' * 40,
          ),
          const FetchJob(
            id: 'r',
            state: FetchState.rejected,
            message: 'Live streams are not supported.',
          ),
        ],
        touch: true,
      );
      await _tab(tester, 'Downloader');
      final long = find.byKey(const ValueKey('job-message:f'));
      await _reveal(tester, long);
      expect(tester.widget<Text>(long).maxLines, 3);
      expect(tester.widget<Text>(long).overflow, TextOverflow.ellipsis);
      expect(
        tester.renderObject<RenderParagraph>(long).didExceedMaxLines,
        isTrue,
      );
      final short = find.byKey(const ValueKey('job-message:r'));
      await _reveal(tester, short);
      expect(
        tester.renderObject<RenderParagraph>(short).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a state this client does not know, once finished', (
      tester,
    ) async {
      await _open(
        tester,
        rows: [
          FetchJob(
            id: 'u',
            state: FetchState.unknown,
            rawState: 'archived',
            finished: DateTime.utc(2026, 11, 12),
          ),
          const FetchJob(id: 'n', state: FetchState.downloading),
        ],
      );
      await _tab(tester, 'Downloader', settle: false);
      expect(find.text('Finished'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-remove:u')), findsOneWidget);
      expect(find.byKey(const ValueKey('job-cancel:u')), findsNothing);
      // No percent yet: the words alone, and a bar without a value.
      expect(find.text('Downloading'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('job-progress:n')),
            )
            .value,
        isNull,
      );
    });

    testWidgets('Cancel and Remove ask the server', (tester) async {
      final home = await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      await tester.tap(find.byKey(const ValueKey('job-cancel:w')));
      await tester.pumpAndSettle();
      expect(home.fetch.calls, contains('delete w'));
      await _reveal(tester, find.byKey(const ValueKey('job-remove:f')));
      home.fetch.rows = mixed.where((job) => job.id != 'f').toList();
      await tester.tap(find.byKey(const ValueKey('job-remove:f')));
      await tester.pumpAndSettle();
      expect(home.fetch.calls, contains('delete f'));
      expect(find.byKey(const ValueKey('job:f')), findsNothing);
      expect(find.byKey(const ValueKey('job:r')), findsOneWidget);
    });

    testWidgets('a row being saved offers no Cancel; a late Cancel says why', (
      tester,
    ) async {
      final home = await _open(
        tester,
        rows: const [
          FetchJob(id: 'p', state: FetchState.placing, title: 'Saving one'),
          FetchJob(id: 'c', state: FetchState.checking, title: 'Still early'),
        ],
      );
      await _tab(tester, 'Downloader');
      expect(find.text('Saving'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-cancel:p')), findsNothing);
      expect(find.byKey(const ValueKey('job-remove:p')), findsNothing);
      expect(find.byKey(const ValueKey('job-cancel:c')), findsOneWidget);
      // The row moved to Saving after the list was shown: the server refuses.
      home.fetch.actionError = FetchError.saving;
      await tester.tap(find.byKey(const ValueKey('job-cancel:c')));
      await tester.pumpAndSettle();
      expect(
        find.text('This download is already being saved.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused action says why in plain words', (tester) async {
      final home = await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      home.fetch.actionError = FetchError.network;
      await tester.tap(find.byKey(const ValueKey('job-cancel:w')));
      await tester.pumpAndSettle();
      expect(find.text(FetchError.network.message), findsOneWidget);
      expect(find.textContaining(RegExp(r'\b[45]\d\d\b')), findsNothing);
    });

    testWidgets('Show in folder reveals the file on Home', (tester) async {
      final home = await _open(tester, rows: mixed);
      home.controller.entries = [
        ...home.controller.entries,
        {
          'path': 'Music/Morning songs.m4a',
          'kind': 'file',
          'effectiveRetention': 'local',
          'status': 'current local',
          'selectionVersion': '1',
        },
      ];
      await _tab(tester, 'Downloader');
      await _reveal(tester, find.byKey(const ValueKey('job-show:ok')));
      await tester.tap(find.byKey(const ValueKey('job-show:ok')));
      await tester.pumpAndSettle();
      expect(_selectedTab(tester), 0);
      expect(find.byType(DownloaderTab), findsNothing);
      expect(
        find.byKey(const ValueKey('row:Music/Morning songs.m4a')),
        findsOneWidget,
      );
      expect(home.jobs.tabVisible, isFalse);
      // The reveal's highlight ends by itself.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Show in folder before the file has synced says so', (
      tester,
    ) async {
      await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      await _reveal(tester, find.byKey(const ValueKey('job-show:low')));
      await tester.tap(find.byKey(const ValueKey('job-show:low')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That file is not in the library yet. It appears after the next sync.',
        ),
        findsOneWidget,
      );
      expect(find.byType(DownloaderTab), findsOneWidget);
    });

    testWidgets('Clear finished follows the list', (tester) async {
      final home = await _open(
        tester,
        rows: mixed.where((job) => !job.isFinished).toList(),
      );
      await _tab(tester, 'Downloader');
      expect(_enabled(tester, 'downloader-clear'), isFalse);
      home.fetch.rows = mixed;
      await home.jobs.refresh();
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'downloader-clear'), isTrue);
      home.fetch.rows = mixed.where((job) => !job.isFinished).toList();
      await tester.tap(find.byKey(const ValueKey('downloader-clear')));
      await tester.pumpAndSettle();
      expect(home.fetch.calls, contains('clear'));
      expect(find.byKey(const ValueKey('job:f')), findsNothing);
      expect(find.byKey(const ValueKey('job:w')), findsOneWidget);
      expect(_enabled(tester, 'downloader-clear'), isFalse);
    });

    testWidgets('Clear finished refused says why', (tester) async {
      final home = await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      home.fetch.actionError = FetchError.busy;
      await tester.tap(find.byKey(const ValueKey('downloader-clear')));
      await tester.pumpAndSettle();
      expect(find.text(FetchError.busy.message), findsOneWidget);
    });

    testWidgets('Refresh lists again; a failed list keeps the rows', (
      tester,
    ) async {
      final home = await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      final before = home.fetch.calls.where((call) => call == 'list').length;
      home.fetch.listError = FetchError.network;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(
        home.fetch.calls.where((call) => call == 'list').length,
        before + 1,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('downloader-list-error')))
            .data,
        FetchError.network.message,
      );
      expect(find.byKey(const ValueKey('job:w')), findsOneWidget);
      home.fetch.listError = null;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('downloader-list-error')), findsNothing);
    });

    testWidgets('pulling the list down refreshes on touch', (tester) async {
      final home = await _open(
        tester,
        size: const Size(360, 800),
        rows: mixed.take(2).toList(),
        touch: true,
      );
      await _tab(tester, 'Downloader');
      expect(find.byType(RefreshIndicator), findsOneWidget);
      final before = home.fetch.calls.where((call) => call == 'list').length;
      await tester.drag(
        find.byKey(const ValueKey('job:w')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(
        home.fetch.calls.where((call) => call == 'list').length,
        before + 1,
      );
    });

    testWidgets('a desktop has the button only', (tester) async {
      await _open(tester);
      await _tab(tester, 'Downloader');
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(find.byTooltip('Refresh'), findsOneWidget);
    });
  });

  group('submit', () {
    const a = 'https://media.example.com/a';
    const b = 'https://media.example.com/b';

    testWidgets('Download waits for a usable link', (tester) async {
      await _open(tester);
      await _tab(tester, 'Downloader');
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      await _paste(tester, 'not a link\n\nftp://files.example.com/x');
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      await _paste(tester, 'not a link\n$a');
      expect(_enabled(tester, 'downloader-submit'), isTrue);
      await _paste(tester, '   ');
      expect(_enabled(tester, 'downloader-submit'), isFalse);
    });

    testWidgets('success sends the links and clears the field', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      expect(find.text('Saves to Music'), findsOneWidget);
      // Audio has no resolution choice.
      expect(find.byKey(const ValueKey('downloader-1080p')), findsNothing);
      home.fetch.submitted = const [
        FetchJob(id: 'n2', state: FetchState.waiting, url: b),
        FetchJob(id: 'n1', state: FetchState.waiting, url: a),
      ];
      await _paste(tester, '$a\n$b\n$a\n');
      await _download(tester);
      expect(home.fetch.lastSubmit!.urls, [a, b]);
      expect(home.fetch.lastSubmit!.kind, FetchKind.audio);
      expect(home.fetch.lastSubmit!.resolution, isNull);
      expect(_field(tester), isEmpty);
      expect(find.byKey(const ValueKey('downloader-error')), findsNothing);
      expect(find.byKey(const ValueKey('downloader-note')), findsNothing);
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      // The new rows are shown at once.
      expect(find.byKey(const ValueKey('job:n1')), findsOneWidget);
      expect(find.byKey(const ValueKey('job:n2')), findsOneWidget);
      expect(find.byKey(const ValueKey('downloader-empty')), findsNothing);
    });

    testWidgets('Video offers the resolution and sends it', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      await tester.tap(find.byKey(const ValueKey('downloader-video')));
      await tester.pumpAndSettle();
      expect(find.text('Saves to Videos'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('downloader-1080p')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('downloader-720p')));
      await tester.pumpAndSettle();
      expect(home.jobs.resolution, FetchResolution.p720);
      await _paste(tester, a);
      await _download(tester);
      expect(home.fetch.lastSubmit!.kind, FetchKind.video);
      expect(home.fetch.lastSubmit!.resolution, FetchResolution.p720);
      await tester.tap(find.byKey(const ValueKey('downloader-audio')));
      await tester.pumpAndSettle();
      expect(find.text('Saves to Music'), findsOneWidget);
      expect(find.byKey(const ValueKey('downloader-720p')), findsNothing);
    });

    testWidgets('lines that are not links stay, with a note', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      await _paste(tester, 'first note\n$a\n  www.example.com/x  \n$b');
      await _download(tester);
      expect(home.fetch.lastSubmit!.urls, [a, b]);
      expect(_field(tester), 'first note\nwww.example.com/x');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('downloader-note'))).data,
        '2 lines are not links and were left in the box.',
      );
      expect(find.byKey(const ValueKey('downloader-error')), findsNothing);
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      // Typing again removes the note.
      await _paste(tester, 'first note');
      expect(find.byKey(const ValueKey('downloader-note')), findsNothing);
      await _paste(tester, 'x\n$a');
      await _download(tester);
      expect(
        find.text('1 line is not a link and was left in the box.'),
        findsOneWidget,
      );
    });

    testWidgets('too many links: nothing is sent', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      final text = [
        for (var index = 0; index <= fetchLinkLimit; index++)
          'https://media.example.com/$index',
      ].join('\n');
      await _paste(tester, text);
      await _download(tester);
      expect(home.fetch.calls, isNot(contains('submit')));
      final error = tester.widget<Text>(
        find.byKey(const ValueKey('downloader-error')),
      );
      expect(error.data, 'Paste at most 50 links at a time (51 pasted).');
      expect(
        error.style!.color,
        Theme.of(tester.element(find.byType(DownloaderTab))).colorScheme.error,
      );
      expect(_field(tester), text);
    });

    for (final error in FetchError.values.where(
      (error) => error != FetchError.absent && error != FetchError.notFound,
    )) {
      testWidgets('${error.name} appears under the field', (tester) async {
        final home = await _open(tester);
        await _tab(tester, 'Downloader');
        home.fetch.actionError = error;
        await _paste(tester, '$a\nnote');
        await _download(tester);
        final shown = tester.widget<Text>(
          find.byKey(const ValueKey('downloader-error')),
        );
        expect(shown.data, error.message);
        expect(
          shown.style!.color,
          Theme.of(tester.element(find.byType(DownloaderTab)))
              .colorScheme
              .error,
        );
        // Never a status code, and nothing is lost.
        expect(find.textContaining(RegExp(r'\b[45]\d\d\b')), findsNothing);
        expect(_field(tester), '$a\nnote');
        expect(find.byKey(const ValueKey('downloader-note')), findsNothing);
        expect(_enabled(tester, 'downloader-submit'), isTrue);
        // The next try succeeds and the error goes.
        home.fetch.actionError = null;
        await _download(tester);
        expect(find.byKey(const ValueKey('downloader-error')), findsNothing);
        expect(_field(tester), 'note');
      });
    }

    testWidgets('a server that no longer offers downloads: the tab goes', (
      tester,
    ) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      home.fetch.actionError = FetchError.absent;
      await _paste(tester, a);
      await _download(tester);
      expect(find.byType(Tab), findsNWidgets(3));
      expect(find.byType(DownloaderTab), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Download waits while a submit is under way', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      await _paste(tester, a);
      home.jobs.submitting = true;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      home.jobs.notifyListeners();
      await tester.pump();
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      home.jobs.submitting = false;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      home.jobs.notifyListeners();
      await tester.pump();
      expect(_enabled(tester, 'downloader-submit'), isTrue);
    });

    for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
      testWidgets('Ctrl or Cmd+Enter in the field submits', (tester) async {
        final home = await _open(tester);
        await _tab(tester, 'Downloader');
        await _paste(tester, a);
        final modifier = platform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        expect(home.fetch.lastSubmit!.urls, [a]);
        expect(_field(tester), isEmpty);
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets('the field cannot be typed in during a submit', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      TextField field() => tester.widget<TextField>(
        find.byKey(const ValueKey('downloader-links')),
      );
      expect(field().readOnly, isFalse);
      await _paste(tester, a);
      home.fetch.submitGate = Completer<void>();
      await _download(tester);
      expect(home.jobs.submitting, isTrue);
      expect(field().readOnly, isTrue);
      // Typing now changes nothing, so the answer cannot overwrite it.
      await tester.enterText(
        find.byKey(const ValueKey('downloader-links')),
        '$a\n$b',
      );
      await tester.pump();
      expect(_field(tester), a);
      home.fetch.submitGate!.complete();
      await tester.pumpAndSettle();
      expect(home.fetch.lastSubmit!.urls, [a]);
      expect(_field(tester), isEmpty);
      expect(field().readOnly, isFalse);
      await _paste(tester, b);
      expect(_field(tester), b);
    });

    testWidgets('leaving the tab during a submit still clears the field', (
      tester,
    ) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      await _paste(tester, 'a note\n$a');
      home.fetch.submitGate = Completer<void>();
      await _download(tester);
      await _tab(tester, 'Home');
      expect(find.byType(DownloaderTab), findsNothing);
      home.fetch.submitGate!.complete();
      home.fetch.submitGate = null;
      await tester.pumpAndSettle();
      await _tab(tester, 'Downloader');
      // Only the line that was not a link is left: nothing to send twice.
      expect(_field(tester), 'a note');
      expect(_enabled(tester, 'downloader-submit'), isFalse);
      expect(home.fetch.calls.where((call) => call == 'submit').length, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed submit left behind keeps the links', (tester) async {
      final home = await _open(tester);
      await _tab(tester, 'Downloader');
      await _paste(tester, a);
      home.fetch
        ..submitGate = Completer<void>()
        ..actionError = FetchError.busy;
      await _download(tester);
      await _tab(tester, 'Home');
      home.fetch.submitGate!.complete();
      await tester.pumpAndSettle();
      await _tab(tester, 'Downloader');
      expect(_field(tester), a);
      expect(_enabled(tester, 'downloader-submit'), isTrue);
    });

    testWidgets('the field survives a visit to another tab', (tester) async {
      await _open(tester);
      await _tab(tester, 'Downloader');
      await _paste(tester, a);
      await _tab(tester, 'Home');
      await _tab(tester, 'Downloader');
      expect(_field(tester), a);
      expect(_enabled(tester, 'downloader-submit'), isTrue);
    });
  });

  group('layout', () {
    const sizes = {
      'phone-360x800': Size(360, 800),
      'phone-412x915': Size(412, 915),
      'phone-800x360': Size(800, 360),
      'desktop-640x720': Size(640, 720),
      'desktop-1280x720': Size(1280, 720),
    };
    for (final MapEntry(key: name, value: size) in sizes.entries) {
      final phone = name.startsWith('phone');
      for (final scale in phone ? [1.0, 1.3] : [1.0]) {
        final at = scale == 1.0 ? name : '$name@${scale}x';
        testWidgets(
          'nothing overflows at $at',
          (tester) async {
            final handle = tester.ensureSemantics();
            final home = await _open(
              tester,
              size: size,
              scale: scale,
              touch: phone,
            );
            await _check(tester, '$at-0-home');
            await _tab(tester, 'Downloader');
            expect(
              find.byKey(const ValueKey('downloader-empty')),
              findsOneWidget,
            );
            await _check(tester, '$at-1-empty');

            home.fetch.rows = mixed;
            await home.jobs.refresh();
            await tester.pumpAndSettle();
            await _check(tester, '$at-2-list');
            // A long link is cut, never wrapped or pushed off the row.
            final title = find.byKey(const ValueKey('job-title:w'));
            await _reveal(tester, title);
            expect(tester.getSize(title).width, lessThan(size.width));
            expect(
              tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
              isTrue,
            );
            for (final job in mixed) {
              await _reveal(tester, find.byKey(ValueKey('job:${job.id}')));
              expect(tester.takeException(), isNull, reason: job.id);
            }
            await _check(tester, '$at-3-list-end');

            await _top(tester);
            await tester.tap(find.byKey(const ValueKey('downloader-video')));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('downloader-720p')),
              findsOneWidget,
            );
            await _check(tester, '$at-4-video');

            home.fetch.actionError = FetchError.storageFull;
            await _paste(
              tester,
              'https://media.example.com/a\nhttps://media.example.com/b',
            );
            await _download(tester);
            expect(
              find.byKey(const ValueKey('downloader-error')),
              findsOneWidget,
            );
            await _check(tester, '$at-5-error');
            if (phone) {
              await expectLater(
                tester,
                meetsGuideline(androidTapTargetGuideline),
              );
            }
            handle.dispose();
          },
          variant: TargetPlatformVariant.only(
            phone ? TargetPlatform.android : TargetPlatform.linux,
          ),
        );
      }
    }

    testWidgets('controls have labels and readable contrast', (tester) async {
      final handle = tester.ensureSemantics();
      await _open(tester, rows: mixed);
      await _tab(tester, 'Downloader');
      expect(find.byTooltip('Refresh'), findsOneWidget);
      // The row reads as its title and state; the bar adds nothing to it.
      expect(
        tester.getSemantics(find.byKey(const ValueKey('job-state:d'))).label,
        contains('Downloading 42%'),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  test('the words for lines left in the box', () {
    expect(
      ignoredLinesNote(1),
      '1 line is not a link and was left in the box.',
    );
    expect(
      ignoredLinesNote(3),
      '3 lines are not links and were left in the box.',
    );
  });
}
