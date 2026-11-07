import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/platform/macos/macos_edit_menu.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/shortcuts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admin_section_test.dart' show FakeAdmin;
import 'fakes.dart';

/// Spec #31 M5 (acceptance row 16) on the VM host, with the macOS platform
/// override: the shared desktop layout at common Mac window sizes with no
/// overflow and no control cut off at the sides, the Cmd shortcuts of the
/// shared table (lib/ui/shortcuts.dart), text-field copy and paste by key
/// and through the Edit menu bridge (lib/platform/macos/macos_edit_menu.dart),
/// and admin gating. The real app on mac-test is
/// integration_test/macos_ui_test.dart.
/// A widget test under the macOS platform override (set and reset by the
/// variant, so the binding's invariant check sees it unset).
void macWidgets(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  // Logical window content sizes. A zoomed window fills the screen less the
  // menu bar (37 points under the notch, 24 without), the Dock (62, shown
  // at the bottom) and the title bar (28). MacBook Air defaults: 13-inch
  // 1470x956 (1440x900 before the notch), 15-inch 1710x1112.
  const windows = [
    ('13-inch zoomed', 1470.0, 829.0),
    ('15-inch zoomed', 1710.0, 985.0),
    ('13-inch 1440x900 zoomed', 1440.0, 786.0),
    ('default window 1280x720', 1280.0, 720.0),
    ('13-inch top half (short)', 1470.0, 431.0),
    ('13-inch left half (narrow)', 735.0, 829.0),
  ];

  ClientController library({bool admin = false}) =>
      ClientController(
          Directory('/unused-m5-profile'),
          secrets: MemorySecrets(),
        )
        ..root = '/Users/sam/anj-cloud'
        ..server = 'https://cloud.example.org'
        ..fingerprint = 'ab' * 32
        ..isAdmin = admin
        ..entries = [
          for (final (path, kind, status) in [
            ('Documents', 'directory', 'current local'),
            (
              'A very long file name a household scanner saved on 2026-11-04 final final copy.pdf',
              'file',
              'current local',
            ),
            ('Budget 2026.numbers', 'file', 'current local'),
            ('CON', 'file', nameNotAllowedStatus),
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
              'presentationErrors': [if (isNameRefusal(status)) status],
            },
        ];

  void clean(WidgetTester tester, String what) {
    expect(tester.takeException(), isNull, reason: what);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final element
        in find
            .byWidgetPredicate(
              (widget) =>
                  widget is ButtonStyleButton ||
                  widget is IconButton ||
                  widget is PopupMenuButton ||
                  widget is TextField ||
                  widget is Checkbox,
            )
            .evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(
        rect.left >= -0.5 && rect.right <= width + 0.5,
        isTrue,
        reason: '$what: ${element.widget.runtimeType} at $rect, width $width',
      );
    }
  }

  // Retina: two physical pixels per point.
  Future<void> sized(WidgetTester tester, double w, double h) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = Size(w * 2, h * 2);
    addTearDown(tester.view.reset);
  }

  Future<void> command(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  // The system clipboard, as the engine serves it.
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return clipboard == null ? null : {'text': clipboard};
            case 'Clipboard.hasStrings':
              return {'value': clipboard?.isNotEmpty ?? false};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('Cmd shortcuts on macOS', () {
    macWidgets('Cmd+F focuses search; Ctrl+F does not', (tester) async {
      final controller = library();
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pump();
      final search = find.byKey(const ValueKey('library-search'));
      bool focused() => tester.widget<TextField>(search).focusNode!.hasFocus;
      expect(AppShortcuts.primaryLabel, 'Cmd');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(focused(), isFalse);
      await command(tester, LogicalKeyboardKey.keyF);
      expect(focused(), isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    macWidgets('Esc leaves Select mode', (tester) async {
      final controller = library();
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('select-card:Documents')), findsOne);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('select-card:Documents')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    // macOS hands a focused text field's unhandled keys to the platform
    // (DefaultTextEditingShortcuts); the search field's own Esc binding
    // comes first, so Esc behaves as on Linux. The platform's answer to an
    // unhandled Esc (cancelOperation:) changes nothing more.
    macWidgets('Esc in the search field clears it, and leaves Select mode', (
      tester,
    ) async {
      final controller = library();
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pump();
      final search = find.byKey(const ValueKey('library-search'));
      String text() => tester.widget<TextField>(search).controller!.text;
      Future<void> escape() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        tester
            .state<EditableTextState>(
              find.descendant(of: search, matching: find.byType(EditableText)),
            )
            .performSelector('cancelOperation:');
        await tester.pump();
      }

      await tester.enterText(search, 'Budget');
      await tester.pump();
      await escape();
      expect(text(), isEmpty);
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pump();
      await tester.tap(search);
      await tester.pump();
      expect(find.byKey(const ValueKey('select-card:Documents')), findsOne);
      await escape();
      expect(find.byKey(const ValueKey('select-card:Documents')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    macWidgets('Cmd+A, Cmd+C, Cmd+X and Cmd+V edit the search field', (
      tester,
    ) async {
      final controller = library();
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pump();
      final search = find.byKey(const ValueKey('library-search'));
      await tester.enterText(search, 'Budget');
      await tester.pump();
      String text() => tester.widget<TextField>(search).controller!.text;
      await command(tester, LogicalKeyboardKey.keyA);
      await command(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, 'Budget');
      await command(tester, LogicalKeyboardKey.keyX);
      expect(text(), isEmpty);
      await command(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(text(), 'Budget');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    test('macOS resolves to Cmd, Linux and Windows to Ctrl', () {
      for (final (platform, control) in [
        (TargetPlatform.macOS, false),
        (TargetPlatform.linux, true),
        (TargetPlatform.windows, true),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(AppShortcuts.search.control, control, reason: '$platform');
        expect(AppShortcuts.search.meta, !control, reason: '$platform');
        expect(AppShortcuts.primaryLabel, control ? 'Ctrl' : 'Cmd');
        // Keys without a modifier are the same on every desktop.
        for (final key in [
          AppShortcuts.cancel,
          ...AppShortcuts.activate,
          ...AppShortcuts.rowMenu,
        ]) {
          expect(key.control || key.meta, isFalse, reason: '$platform $key');
        }
      }
    });
  });

  group('Edit menu bridge', () {
    Future<Object?> perform(String command) async {
      final codec = const StandardMethodCodec();
      Object? reply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'cloud.anj/edit',
            codec.encodeMethodCall(MethodCall('perform', command)),
            (data) => reply = codec.decodeEnvelope(data!),
          );
      return reply;
    }

    macWidgets('each command acts on the focused text field as its keys do; '
        'focus is reported to the runner', (tester) async {
      final reports = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('cloud.anj/edit'), (
            call,
          ) async {
            if (call.method == 'focus') reports.add(call.arguments);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('cloud.anj/edit'),
              null,
            ),
      );
      final menu = MacosEditMenu();
      final text = TextEditingController();
      final field = FocusNode();
      final other = FocusNode();
      addTearDown(() {
        menu.stop();
        text.dispose();
        field.dispose();
        other.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: text, focusNode: field),
                Focus(focusNode: other, child: const Text('not a field')),
              ],
            ),
          ),
        ),
      );
      menu.start();
      await tester.pump();
      expect(menu.textFocused, isFalse);
      expect(await perform('paste'), isFalse, reason: 'no text field focused');

      await tester.enterText(find.byType(TextField), 'Invoices 2026');
      await tester.pump();
      expect(menu.textFocused, isTrue);
      expect(await perform('selectAll'), isTrue);
      await tester.pump();
      expect(
        text.selection,
        const TextSelection(baseOffset: 0, extentOffset: 13),
      );
      expect(await perform('copy'), isTrue);
      await tester.pump();
      expect(clipboard, 'Invoices 2026');
      // The undo history records a change once typing pauses.
      await tester.pump(const Duration(seconds: 1));
      expect(await perform('cut'), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(text.text, isEmpty);
      expect(await perform('paste'), isTrue);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(text.text, 'Invoices 2026');
      expect(await perform('undo'), isTrue);
      await tester.pumpAndSettle();
      expect(text.text, isEmpty);
      expect(await perform('redo'), isTrue);
      await tester.pumpAndSettle();
      expect(text.text, 'Invoices 2026');
      expect(await perform('bogus'), isFalse);

      other.requestFocus();
      await tester.pump();
      expect(menu.textFocused, isFalse);
      expect(await perform('cut'), isFalse);
      expect(text.text, 'Invoices 2026', reason: 'nothing changed');
      // The runner hears each change once: not focused, focused, not.
      expect(reports, [false, true, false]);
      expect(MacosEditMenu.intentFor('paste'), isA<PasteTextIntent>());
    });
  });

  group('admin gating on macOS', () {
    macWidgets('only an admin account sees the Admin section', (tester) async {
      for (final admin in [false, true]) {
        final controller = library(admin: admin);
        await tester.pumpWidget(CloudApp(controller: controller));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('open-admin')),
          admin ? findsOneWidget : findsNothing,
          reason: 'admin $admin',
        );
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });

    macWidgets('a 403 not-admin closes Admin', (tester) async {
      final api = FakeAdmin()..notAdmin = true;
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AdminPage(
            call: api.call,
            onNotAdmin: () => closed++,
            server: 'https://gateway.example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(closed, 1);
    });
  });

  for (final (name, w, h) in windows) {
    macWidgets('library, row menu, Select bar and delete fit: $name', (
      tester,
    ) async {
      await sized(tester, w, h);
      final controller = library(admin: true);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      clean(tester, '$name home');
      expect(find.byKey(const ValueKey('open-admin')), findsOneWidget);
      // Desktop-only controls stay: the ⋮ menu's root picker, Start at
      // login (with a manager) and Quit (with a lifecycle) are shared.
      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      clean(tester, '$name row menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pump();
      // Not Documents: the top folders are never deleted (spec #34 P7).
      await tester.tap(find.byKey(const ValueKey('select-card:Photos')));
      await tester.pump();
      clean(tester, '$name select bar');
      await tester.tap(find.byKey(const ValueKey('bulk-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete selected items everywhere?'), findsOneWidget);
      clean(tester, '$name delete confirmation');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    macWidgets('pairing fits: $name', (tester) async {
      await sized(tester, w, h);
      final controller = ClientController(
        Directory('/unused-m5-profile'),
        secrets: MemorySecrets(),
      );
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Pair device'), findsOneWidget);
      clean(tester, '$name pairing');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    macWidgets('every Admin view and its confirmations fit: $name', (
      tester,
    ) async {
      await sized(tester, w, h);
      final api = FakeAdmin();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminPage(
            call: api.call,
            onNotAdmin: () {},
            server: 'https://gateway.example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final view in AdminView.values) {
        await tester.tap(find.text(view.label).first);
        await tester.pumpAndSettle();
        clean(tester, '$name Admin ${view.label}');
      }
      // Devices live under their user (spec #34 P8): open alex's list.
      await tester.tap(find.text(AdminView.users.label).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin-user-expand:alex')));
      await tester.pumpAndSettle();
      clean(tester, '$name Admin user devices');
      await tester.tap(
        find.byKey(
          const ValueKey('admin-revoke:22222222-2222-4222-8222-222222222222'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Revoke the VM host (sam)?'), findsOneWidget);
      clean(tester, '$name revoke confirmation');
      await tester.tap(find.byKey(const ValueKey('admin-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.mutations().where((r) => r.$3?['confirm'] != null), isEmpty);
    });
  }
}
