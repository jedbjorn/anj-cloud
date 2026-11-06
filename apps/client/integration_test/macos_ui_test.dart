// Spec #31 M5 (acceptance row 16) on mac-test, inside the real app with its
// Swift runner (never on the VM host). tool/macos/check_m5.sh runs it from a
// gui/<uid> job (the system pasteboard and the window server of the
// console session); deploy/macos_admin_fixture.py drives the Admin part.
//
//   --dart-define=ANJ_M5_OUT=<dir>       evidence: progress.json and
//                                        in-app screenshots (required)
//   --dart-define=ANJ_M5_CONFIG=<file>   the Admin run's JSON, written by
//                                        the fixture: {"origin",
//                                        "code_alice", "work" (absent)};
//                                        without it the Admin test is
//                                        skipped
//
// 1. macOS conventions: the native title bar and traffic lights; the
//    standard app menu (About, Hide, Hide Others, Show All, Quit), File >
//    Close Window (Cmd-W) and an Edit menu whose Select All, Copy, Cut and
//    Paste act on a Flutter text field with the real pasteboard; Cmd keys
//    sent through AppKit's own key handling; screenshots of home, the row
//    menu, the Select bar, the delete confirmation, the app menu, the root
//    chooser and pairing, with no overflow.
// 2. Admin against a review stack through the reverse forward: Alice
//    (paired by her code alone and made admin by the driver) invites Bob in
//    the UI; Bob pairs by typing only that code (spec #35: the CA is
//    fetched and checked against the code, the server approves at once);
//    his device appears under his user (spec #34 P8). Alice changes his
//    role both ways with Cancel first and revokes him from his device list;
//    Bob, not an admin, sees no Admin section and gets 403. Screenshots of
//    each Admin view and every dialog.
//
// Device keys stay in memory here, as in the Linux Admin test
// (integration_test/admin_flow_test.dart): key custody in the login
// keychain is M3's (integration_test/macos_adapters_test.dart), so this run
// leaves no keychain item. Pairing codes never reach the evidence.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/lifecycle.dart';
import 'package:anj_cloud/core/ports/autostart.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/platform/macos/macos_edit_menu.dart';
import 'package:anj_cloud/platform/macos/macos_window.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

const outPath = String.fromEnvironment('ANJ_M5_OUT');
const configPath = String.fromEnvironment('ANJ_M5_CONFIG');

class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _StillWindow implements WindowControl {
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> exit() async {}
}

class _Autostart implements AutostartControl {
  var enabled = true;
  @override
  Future<AutostartState> status() async =>
      AutostartState(enabled: enabled, source: 'user');
  @override
  Future<AutostartState> set(bool value) async =>
      AutostartState(enabled: enabled = value, source: 'user');
}

/// Evidence for one test: progress.json (claims, codes redacted) and PNGs.
class Evidence {
  Evidence(this.tester, this.prefix) {
    if (outPath.isEmpty) throw StateError('Build with ANJ_M5_OUT=<dir>.');
    dir = Directory(outPath)..createSync(recursive: true);
  }

  final WidgetTester tester;
  final String prefix;
  late final Directory dir;
  final events = <Map<String, Object?>>[];
  final codes = <String>{};
  // Anything shaped like a pairing code: 32 symbols of its alphabet,
  // grouped or not.
  static final codeShape = RegExp(
    r'(?:[0-9A-HJKMNP-TV-Z][\s-]?){31}[0-9A-HJKMNP-TV-Z]',
  );

  String redact(String text) {
    for (final code in codes) {
      if (code.isNotEmpty) text = text.replaceAll(code, '[code]');
    }
    return text.replaceAll(codeShape, '[code]');
  }

  void record(String claim, [Map<String, Object?> facts = const {}]) {
    events.add({'claim': claim, ...facts});
    File(p.join(dir.path, '$prefix-progress.json')).writeAsStringSync(
      redact(const JsonEncoder.withIndent('  ').convert(events)),
      flush: true,
    );
    // ignore: avoid_print
    print('M5 claim: ${redact(claim)}');
  }

  List<String> visibleTexts() => [
    for (final t in tester.widgetList<Text>(find.byType(Text)))
      if (t.data != null && t.data!.trim().isNotEmpty) redact(t.data!),
  ].take(80).toList();

  /// No overflow (the binding reports one as an exception) and no control
  /// cut off at the sides.
  void clean(String what) {
    expect(tester.takeException(), isNull, reason: what);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final element
        in find
            .byWidgetPredicate(
              (w) =>
                  w is ButtonStyleButton ||
                  w is IconButton ||
                  w is PopupMenuButton ||
                  w is TextField,
            )
            .evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(
        rect.left >= -0.5 && rect.right <= width + 0.5,
        isTrue,
        reason: '$what: ${element.widget.runtimeType} at $rect of $width',
      );
    }
  }

  Future<void> screenshot(String name) async {
    await tester.pump(const Duration(milliseconds: 300));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(dir.path, '$prefix-$name.png'))
          .writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
    });
  }
}

const _window = MethodChannel('cloud.anj/window');

Future<T?> desk<T>(WidgetTester tester, String action) async =>
    (await tester.runAsync(
      () => _window.invokeMethod<Object?>('debugPerform', action),
    )) as T?;

Future<void> until(
  WidgetTester tester,
  bool Function() done, {
  int seconds = 30,
  String? what,
}) async {
  for (var i = 0; i < seconds * 5; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (!done()) throw StateError('Timed out waiting for ${what ?? 'state'}');
}

Future<void> untilFound(
  WidgetTester tester,
  Finder finder, {
  int seconds = 60,
}) => until(
  tester,
  () => finder.evaluate().isNotEmpty,
  seconds: seconds,
  what: '$finder',
);

ClientController sampleLibrary(Directory profile) =>
    ClientController(profile, secrets: _MemorySecrets())
      ..root = '${Platform.environment['HOME']}/anj-cloud'
      ..server = 'https://cloud.example.org'
      ..fingerprint = 'ab' * 32
      ..isAdmin = true
      ..entries = [
        for (final (path, kind, status) in [
          ('Documents', 'directory', 'current local'),
          ('Documents/Budget 2026.numbers', 'file', 'current local'),
          (
            'A very long file name a household scanner saved on 2026-11-04 final final copy.pdf',
            'file',
            'current local',
          ),
          ('Photos', 'directory', 'cloud-only'),
          ('notes.txt', 'file', 'pending: upload'),
        ])
          {
            'path': path,
            'kind': kind,
            'status': status,
            'selectionVersion': '1',
            'effectiveRetention': status == 'cloud-only' ? 'cloud' : 'local',
            'expectedPresent': status != 'cloud-only',
            'size': 123456789,
            'presentationErrors': const [],
          },
      ];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final run = DateTime.now().millisecondsSinceEpoch;

  testWidgets('macOS conventions in the real app', (tester) async {
    final evidence = Evidence(tester, 'ui');
    final fixture = Directory.systemTemp.createTempSync('anj-m5-ui-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    addTearDown(() {
      if (evidence.events.isEmpty || evidence.events.last['claim'] != 'done') {
        evidence.record('stopped', {'texts': evidence.visibleTexts()});
      }
    });

    // ---- the native title bar ------------------------------------------
    final window = Map<String, Object?>.from(
      (await desk<Map<Object?, Object?>>(tester, 'window'))!,
    );
    expect(window['title'], 'AnJ Cloud');
    expect(window['titled'], isTrue);
    expect(window['fullSizeContent'], isFalse);
    expect(window['titlebarTransparent'], isFalse);
    expect(window['titleVisible'], isTrue);
    for (final button in ['closeButton', 'miniaturizeButton', 'zoomButton']) {
      expect(window[button], isTrue, reason: button);
    }
    evidence.record('native title bar and traffic lights', window);

    // ---- the main menu ---------------------------------------------------
    Future<Map<String, List<Map<String, Object?>>>> mainMenu() async {
      final menus = (await desk<List<Object?>>(tester, 'mainMenu'))!;
      return {
        for (final menu in menus.cast<Map<Object?, Object?>>())
          menu['title']! as String: [
            for (final item in (menu['items']! as List).cast<Map>())
              Map<String, Object?>.from(item),
          ],
      };
    }

    Map<String, Object?> item(List<Map<String, Object?>> menu, String title) =>
        menu.firstWhere(
          (i) => i['title'] == title,
          orElse: () => fail('no menu item "$title" in $menu'),
        );

    final menus = await mainMenu();
    final names = menus.keys.toList();
    expect(names.take(3), ['AnJ Cloud', 'File', 'Edit'], reason: '$names');
    expect(names, containsAll(['View', 'Window', 'Help']));
    final app = menus['AnJ Cloud']!;
    for (final (title, key) in [
      ('About AnJ Cloud', ''),
      ('Services', ''),
      ('Hide AnJ Cloud', 'h'),
      ('Hide Others', 'h'),
      ('Show All', ''),
      ('Quit AnJ Cloud', 'q'),
    ]) {
      expect(item(app, title)['key'], key, reason: title);
    }
    expect(app.map((i) => i['title']), isNot(contains('Preferences…')));
    final close = item(menus['File']!, 'Close Window');
    expect(
      [close['key'], close['command'], close['id']],
      ['w', true, 'file:close'],
    );
    final edit = menus['Edit']!;
    for (final (title, key, id) in [
      ('Undo', 'z', 'edit:undo'),
      ('Redo', 'Z', 'edit:redo'),
      ('Cut', 'x', 'edit:cut'),
      ('Copy', 'c', 'edit:copy'),
      ('Paste', 'v', 'edit:paste'),
      ('Select All', 'a', 'edit:selectAll'),
    ]) {
      final row = item(edit, title);
      expect([row['key'], row['command'], row['id']], [key, true, id]);
    }
    for (final gone in [
      'Find',
      'Spelling and Grammar',
      'Substitutions',
      'Transformations',
      'Speech',
      'Paste and Match Style',
      'Delete',
    ]) {
      expect(edit.map((i) => i['title']), isNot(contains(gone)));
    }
    evidence.record('main menu', {
      for (final entry in menus.entries)
        entry.key: [for (final i in entry.value) i['title']],
    });

    // ---- the library, as the app shows it -------------------------------
    var closeRequests = 0;
    final macWindow = MacosWindow(
      requestExit: () async {
        closeRequests++;
        return ui.AppExitResponse.cancel;
      },
    );
    final editMenu = MacosEditMenu()..start();
    addTearDown(editMenu.stop);
    final lifecycle = DesktopLifecycle(
      window: _StillWindow(),
      stopSync: () async => true,
    );
    final controller = sampleLibrary(Directory(p.join(fixture.path, 'lib')));
    await tester.pumpWidget(
      CloudApp(
        controller: controller,
        lifecycle: lifecycle,
        autostart: _Autostart(),
      ),
    );
    await untilFound(tester, find.byKey(const ValueKey('library-search')));
    await tester.pump(const Duration(seconds: 1));
    final dpr = tester.view.devicePixelRatio;
    final logical = tester.view.physicalSize / dpr;
    evidence.clean('home');
    await evidence.screenshot('home');
    evidence.record('home shown', {
      'device_pixel_ratio': dpr,
      'logical_size': '${logical.width.round()}x${logical.height.round()}',
    });

    await tester.tap(find.byTooltip('File actions').first);
    await tester.pumpAndSettle();
    evidence.clean('row menu');
    await evidence.screenshot('row-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('select-button')));
    await tester.pump();
    // Not Documents: the top folders are never deleted (spec #34 P7).
    await tester.tap(find.byKey(const ValueKey('select-card:Photos')));
    await tester.pump(const Duration(milliseconds: 500));
    evidence.clean('select bar');
    await evidence.screenshot('select-bar');
    await tester.tap(find.byKey(const ValueKey('bulk-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete selected items everywhere?'), findsOneWidget);
    evidence.clean('delete confirmation');
    await evidence.screenshot('delete-confirmation');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('select-card:Photos')), findsNothing);
    evidence.record('row menu, Select bar and delete confirmation fit');

    // Desktop-only controls stay: Start at login and Quit in the app menu.
    await tester.tap(find.byTooltip('AnJ Cloud menu'));
    await tester.pumpAndSettle();
    expect(find.text('Start at login'), findsOneWidget);
    expect(find.text('Quit AnJ Cloud'), findsOneWidget);
    evidence.clean('app menu');
    await evidence.screenshot('app-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // ---- the Edit menu on a text field, with the real pasteboard --------
    final search = find.byKey(const ValueKey('library-search'));
    String text() => tester.widget<TextField>(search).controller!.text;
    Future<bool> editEnabled(String title) async =>
        item((await mainMenu())['Edit']!, title)['enabled'] == true;
    expect(await editEnabled('Paste'), isFalse, reason: 'no field focused');
    await tester.tap(search);
    await tester.enterText(search, 'Budget 2026');
    await tester.pump(const Duration(seconds: 1));
    expect(await editEnabled('Paste'), isTrue, reason: 'search focused');
    Future<void> menuItem(String id) async {
      expect(await desk<bool>(tester, 'menu:$id'), isTrue, reason: id);
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<String?> pasteboard() async =>
        (await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain)))
            ?.text;

    await menuItem('edit:selectAll');
    await menuItem('edit:copy');
    expect(await pasteboard(), 'Budget 2026');
    await menuItem('edit:cut');
    await until(tester, () => text().isEmpty, what: 'Cut');
    await menuItem('edit:paste');
    await until(tester, () => text() == 'Budget 2026', what: 'Paste');
    evidence.record('Edit menu: Select All, Copy, Cut and Paste in a field');

    // ---- Cmd keys through AppKit (key equivalents, then the window) -----
    final keys = <String, Object?>{};
    Future<bool> cmd(String key) async {
      final reply = Map<String, Object?>.from(
        (await desk<Map<Object?, Object?>>(tester, 'cmdKey:$key'))!,
      );
      await tester.pump(const Duration(milliseconds: 500));
      return reply['sent'] == true && reply['keyWindow'] == true;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    final keyWindow = await cmd('f');
    keys['window_was_key'] = keyWindow;
    // Synthesized key events are evidence only: the VM host's widget tests are the
    // proof of the Cmd shortcuts (row 16). On mac-test run 1 a synthesized
    // Cmd-F did not reach the framework though the window was key.
    Future<bool> within(bool Function() done) async {
      for (var i = 0; i < 15; i++) {
        if (done()) return true;
        await tester.pump(const Duration(milliseconds: 200));
      }
      return done();
    }

    if (keyWindow) {
      final field = tester.widget<TextField>(search).focusNode!;
      keys['cmd_f_focuses_search'] = await within(() => field.hasFocus);
      if (!field.hasFocus) await tester.tap(search);
      await tester.enterText(search, 'Invoices');
      await tester.pump(const Duration(seconds: 1));
      await cmd('a');
      await cmd('c');
      keys['cmd_a_cmd_c_copy'] = await pasteboard() == 'Invoices';
      await cmd('x');
      keys['cmd_x_cuts'] = await within(() => text().isEmpty);
      field.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
      final before = closeRequests;
      await cmd('w');
      keys['cmd_w_asks_to_close'] = await within(() => closeRequests > before);
    }
    evidence.record(
      keyWindow
          ? 'Cmd keys through AppKit'
          : 'Cmd keys not sent: the window was not key (recorded only)',
      keys,
    );

    // File > Close Window asks Dart, exactly as the close button does.
    final before = closeRequests;
    await menuItem('file:close');
    await until(tester, () => closeRequests > before, what: 'Close Window');
    evidence.record('File > Close Window takes the close button path');

    // ---- the root chooser and pairing (desktop-only controls) ----------
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    final fresh = ClientController(
      Directory(p.join(fixture.path, 'fresh')),
      secrets: _MemorySecrets(),
    );
    await tester.pumpWidget(CloudApp(controller: fresh));
    await tester.pump(const Duration(seconds: 1));
    Future<void> dialog(String name) async {
      await untilFound(tester, find.byType(AlertDialog));
      await tester.pump(const Duration(milliseconds: 500));
      evidence.clean(name);
      await evidence.screenshot(name);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Choose root'));
    await untilFound(tester, find.text('Choose your anj-cloud root'));
    // The folder button opens the system panel (NSOpenPanel); not pressed.
    expect(find.byTooltip('Choose parent'), findsOneWidget);
    await dialog('root-chooser');
    await tester.tap(find.text('Pair device'));
    await dialog('pairing');
    evidence.record('root chooser and pairing fit');
    await tester.pumpWidget(const SizedBox());
    fresh.dispose();
    macWindow.channel.setMethodCallHandler(null);
    evidence.record('done', {'run': run});
  });

  testWidgets('Admin on macOS against a review stack', (tester) async {
    final evidence = Evidence(tester, 'admin');
    final config =
        jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
    final origin = config['origin'] as String;
    if (!RegExp(r'^https://127\.0\.0\.1:\d+$').hasMatch(origin)) {
      throw StateError('Use the review stack through the reverse forward.');
    }
    final bobLabel = 'Bob M5 ${run % 100000}';
    final work = Directory(config['work'] as String);
    if (work.existsSync()) {
      throw StateError('The work directory must be absent.');
    }
    work.createSync(recursive: true);
    evidence.codes.add(config['code_alice'] as String);
    final secrets = _MemorySecrets();
    addTearDown(() {
      if (evidence.events.isEmpty || evidence.events.last['claim'] != 'done') {
        try {
          evidence.record('stopped', {'texts': evidence.visibleTexts()});
        } catch (_) {}
      }
    });

    Future<ClientController> prepared(String label) async {
      final controller = ClientController(
        Directory(p.join(work.path, 'profile-$label')),
        secrets: secrets,
      );
      await controller.initialize();
      final parent = Directory(p.join(work.path, 'files-$label'))..createSync();
      await controller.configureRoot(parent.path);
      await controller.stop();
      return controller;
    }

    // Code-only pairing (spec #35): one call fetches the CA, checks it
    // against the code and returns once the server has approved the device.
    // A 429 (the shared 127.0.0.1 enrolment limit) is waited out.
    Future<void> paired(ClientController controller, String code) async {
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (true) {
        try {
          await controller.pair(origin, code);
        } catch (error) {
          if (!'$error'.contains('(429)') ||
              DateTime.now().isAfter(deadline)) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(seconds: 7));
          continue;
        }
        // Decision #163 (#97): a new pairing first asks which folders stay
        // local; the empty fixture account has none, so confirm at once.
        if (controller.firstSyncPending) {
          await controller.confirmFirstSync(const [], const {});
        }
        await controller.stop();
        if (controller.pairingState != 'paired') {
          throw StateError('Not paired: ${controller.pairingState}');
        }
        return;
      }
    }

    Future<ClientController> reopened(String label) async {
      final controller = ClientController(
        Directory(p.join(work.path, 'profile-$label')),
        secrets: secrets,
      );
      await controller.initialize();
      await controller.start();
      return controller;
    }

    // ---- Alice: paired here, approved and made admin by the driver ------
    late ClientController alice;
    await tester.runAsync(() async {
      alice = await prepared('alice');
      await paired(alice, config['code_alice'] as String);
      // The driver makes Alice an admin once she is paired.
      File(p.join(evidence.dir.path, 'alice-paired.json'))
          .writeAsStringSync(jsonEncode({'fingerprint': alice.fingerprint}));
      alice.dispose();
      alice = await reopened('alice');
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!alice.isAdmin) {
        if (DateTime.now().isAfter(deadline)) throw StateError('Not admin.');
        await Future<void>.delayed(const Duration(seconds: 3));
        await alice.refreshAdmin();
      }
    });
    evidence.record('alice paired and admin');

    await tester.pumpWidget(CloudApp(controller: alice));
    await untilFound(tester, find.byKey(const ValueKey('open-admin')));
    evidence.clean('admin home');
    await evidence.screenshot('home');
    evidence.record('admin home shown');

    Future<void> openAdmin() async {
      await tester.tap(find.byKey(const ValueKey('open-admin')));
      await untilFound(tester, find.text('Alice (anj-fixture-alice)'));
      // macOS pages slide in from the right (Cupertino transition): wait
      // until the page has arrived before tapping inside it (mac-test run
      // 1 tapped Bob's actions mid-slide at x 1286 of 1280).
      await until(
        tester,
        () => tester.getTopLeft(find.byType(AdminPage)).dx.abs() < 0.5,
        what: 'the Admin page transition',
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> view(AdminView view) async {
      await tester.tap(find.text(view.label).first);
      await tester.pump(const Duration(seconds: 1));
    }

    await openAdmin();
    for (final v in AdminView.values) {
      await view(v);
      await tester.pump(const Duration(seconds: 2));
      evidence.clean('Admin ${v.label}');
      await evidence.screenshot('view-${v.name}');
    }
    evidence.record('every Admin view fits');

    // ---- Bob's device: invited in the UI, paired by the code alone -------
    await view(AdminView.invitations);
    await untilFound(
      tester,
      find.byKey(const ValueKey('admin-create-invitation')),
    );
    await tester.tap(find.byKey(const ValueKey('admin-create-invitation')));
    await untilFound(tester, find.byKey(const ValueKey('admin-invite-user')));
    await tester.tap(find.byKey(const ValueKey('admin-invite-user')));
    await untilFound(tester, find.text('Bob (anj-fixture-bob)'));
    await tester.tap(find.text('Bob (anj-fixture-bob)').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.byKey(const ValueKey('admin-invite-label')),
      bobLabel,
    );
    evidence.clean('invitation dialog');
    await evidence.screenshot('invitation-dialog');
    await tester.tap(find.byKey(const ValueKey('admin-invite-create')));
    await untilFound(tester, find.byKey(const ValueKey('admin-invite-code')));
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('admin-invite-code')))
        .data!;
    evidence.codes.add(code);
    // No screenshot here: the dialog shows the code.
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));

    late ClientController bob;
    await tester.runAsync(() async {
      bob = await prepared('bob');
      await paired(bob, code);
    });
    expect(bob.pairingState, 'paired');
    // Bob's new device is listed under Bob in Users (spec #34 P8), named
    // by the invitation's label; no approval step exists for a new code.
    await view(AdminView.users);
    final bobDevices = find.byKey(
      const ValueKey('admin-user-devices:anj-fixture-bob'),
    );
    final bobDevice = find.descendant(
      of: bobDevices,
      matching: find.text(bobLabel),
    );
    for (var i = 0; i < 10 && bobDevice.evaluate().isEmpty; i++) {
      if (bobDevices.evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const ValueKey('admin-user-expand:anj-fixture-bob')),
        );
      } else {
        await tester.tap(find.byTooltip('Refresh'));
      }
      await tester.pump(const Duration(seconds: 2));
    }
    expect(bobDevice, findsOneWidget);
    evidence.clean('Bob\'s devices');
    await evidence.screenshot('bob-devices');
    evidence.record('Bob invited in the UI and paired by the code alone; '
        'his device is listed under him');

    // ---- Bob is not an admin: no section, and 403 ------------------------
    await tester.runAsync(() async {
      bob.dispose();
      bob = await reopened('bob');
      await Future<void>.delayed(const Duration(seconds: 3));
      await bob.refreshAdmin();
    });
    expect(bob.isAdmin, isFalse);
    final refused = await tester.runAsync(
      () => bob.admin('GET', '/v1/admin/users'),
    );
    expect(refused!.status, 403);
    expect(refused.map['error'], 'not-admin');
    evidence.record('a non-admin gets 403', {'status': refused.status});
    Navigator.of(tester.element(find.byType(AdminPage))).pop();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CloudApp(controller: bob));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    evidence.clean('non-admin home');
    await evidence.screenshot('non-admin-home');
    evidence.record('a non-admin sees no Admin section');

    // ---- role change, Cancel first, then both ways -----------------------
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CloudApp(controller: alice));
    await untilFound(tester, find.byKey(const ValueKey('open-admin')));
    await openAdmin();
    final confirmations = <Map<String, String>>[];
    Future<void> confirm({required bool ok, required String what}) async {
      await untilFound(tester, find.byKey(const ValueKey('admin-confirm-ok')));
      final texts = [
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          ),
        ))
          if (t.data != null) t.data!,
      ];
      confirmations.add({
        'action': what,
        'title': texts.first,
        'effect': texts[1],
      });
      evidence.clean('$what confirmation');
      await evidence.screenshot('confirm-$what-${ok ? 'ok' : 'cancel'}');
      await tester.tap(
        find.byKey(ValueKey(ok ? 'admin-confirm-ok' : 'admin-confirm-cancel')),
      );
      await tester.pump(const Duration(seconds: 2));
    }

    Future<void> role(String choice, {required bool ok}) async {
      await tester.tap(find.byTooltip('Actions for Bob'));
      await untilFound(tester, find.text(choice));
      await tester.tap(find.text(choice).last);
      await confirm(ok: ok, what: choice.toLowerCase().replaceAll(' ', '-'));
    }

    await role('Make admin', ok: false);
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isFalse, reason: 'Cancel sent nothing');
    await role('Make admin', ok: true);
    await untilFound(tester, find.text('anj-fixture-bob is now an admin.'));
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await role('Remove admin', ok: true);
    await untilFound(
      tester,
      find.text('anj-fixture-bob is no longer an admin.'),
    );
    await tester.runAsync(() => bob.refreshAdmin());
    expect(bob.isAdmin, isFalse);
    evidence.record(
      'role change both ways after the server confirmation; Cancel sent '
      'nothing',
    );

    // ---- revoke Bob's device ---------------------------------------------
    await view(AdminView.users);
    if (find
        .byKey(const ValueKey('admin-user-devices:anj-fixture-bob'))
        .evaluate()
        .isEmpty) {
      await tester.tap(
        find.byKey(const ValueKey('admin-user-expand:anj-fixture-bob')),
      );
    }
    final card = find.ancestor(
      of: find.descendant(
        of: find.byKey(const ValueKey('admin-user-devices:anj-fixture-bob')),
        matching: find.text(bobLabel),
      ),
      matching: find.byType(ListTile),
    );
    await until(
      tester,
      () => card.evaluate().isNotEmpty,
      what: 'Bob\'s device under Bob',
    );
    await tester.tap(find.descendant(of: card, matching: find.text('Revoke')));
    await confirm(ok: true, what: 'revoke');
    await untilFound(tester, find.text('Revoked $bobLabel.'));
    final after = await tester.runAsync(() async {
      try {
        return (await bob.admin('GET', '/v1/account')).status;
      } catch (error) {
        return error.runtimeType.toString();
      }
    });
    expect(after, isNot(200));
    evidence.record('Bob\'s device revoked after the confirmation', {
      'bob_after': after,
      'confirmations': confirmations,
    });

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await bob.stop();
      await alice.stop();
    });
    bob.dispose();
    alice.dispose();
    evidence.record('done');
  }, skip: configPath.isEmpty);
}
