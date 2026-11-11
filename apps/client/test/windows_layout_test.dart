import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/shortcuts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admin_section_test.dart' show FakeAdmin;
import 'fakes.dart';

/// On Linux: the shared shortcut table per
/// desktop platform, and the shared desktop layout at the logical sizes of
/// common Windows screens at 100, 125 and 150 % display scaling, with no
/// overflow and no control cut off at the sides. Input follows the platform,
/// never the window size.
void main() {
  // Maximized client area: the screen in logical pixels, less the taskbar
  // (40) and the title bar (31) at that scale.
  const screens = [
    ('1366x768 at 100%', 1366.0, 768.0, 1.0),
    ('1920x1080 at 125%', 1920.0, 1080.0, 1.25),
    ('1920x1080 at 150%', 1920.0, 1080.0, 1.5),
    ('1366x768 at 125%', 1366.0, 768.0, 1.25),
    ('1366x768 at 150%', 1366.0, 768.0, 1.5),
    ('2560x1440 at 150%', 2560.0, 1440.0, 1.5),
  ];

  ClientController library({bool admin = false}) {
    final controller =
        ClientController(
            Directory('/unused-w6-profile'),
            secrets: MemorySecrets(),
          )
          ..root = r'C:\Users\Public\anj-cloud'
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
              ('Budget 2026.xlsx', 'file', fileBusyStatus),
              ('CON', 'file', nameNotAllowedStatus),
              ('Photos', 'directory', 'cloud-only'),
              ('notes.txt', 'file', 'pending: upload'),
              ('a.txt', 'file', serverNameClashStatus),
              ('deep.txt', 'file', 'current local'),
            ])
              {
                'path': path,
                'kind': kind,
                'status': status,
                'selectionVersion': '1',
                'effectiveRetention': status == 'cloud-only'
                    ? 'cloud'
                    : 'local',
                'expectedPresent': status != 'cloud-only',
                'size': 123456789,
                // Each held or busy row carries its amber reason, and the
                // local name refusal its Rename button.
                'presentationErrors': [
                  if (isServerNameHold(status) ||
                      isBusyStatus(status) ||
                      isNameRefusal(status))
                    status,
                ],
                'nameRefused': isNameRefusal(status),
                'presentationNotes': [if (path == 'deep.txt') longPathNote],
              },
          ];
    return controller;
  }

  void clean(WidgetTester tester, String what) {
    expect(tester.takeException(), isNull, reason: what);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final type in [
      ButtonStyleButton,
      IconButton,
      PopupMenuButton,
      TextField,
      Checkbox,
    ]) {
      for (final element
          in find
              .byWidgetPredicate(
                (widget) => type == ButtonStyleButton
                    ? widget is ButtonStyleButton
                    : widget.runtimeType.toString().startsWith(type.toString()),
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
  }

  Future<void> sized(WidgetTester tester, double w, double h, double s) async {
    tester.view.devicePixelRatio = s;
    tester.view.physicalSize = Size(w, (h / s - 71) * s);
    addTearDown(tester.view.reset);
  }

  group('shortcut table', () {
    testWidgets(
      'the platform command modifier focuses search; the other does not',
      (tester) async {
        final controller = library();
        await tester.pumpWidget(CloudApp(controller: controller));
        await tester.pump();
        final search = find.byKey(const ValueKey('library-search'));
        bool focused() => tester.widget<TextField>(search).focusNode!.hasFocus;
        final mac = defaultTargetPlatform == TargetPlatform.macOS;
        expect(AppShortcuts.primaryLabel, mac ? 'Cmd' : 'Ctrl');
        final wrong = mac
            ? LogicalKeyboardKey.controlLeft
            : LogicalKeyboardKey.metaLeft;
        await tester.sendKeyDownEvent(wrong);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(wrong);
        await tester.pump();
        expect(focused(), isFalse);
        final right = mac
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(right);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(right);
        await tester.pump();
        expect(focused(), isTrue);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
      variant: TargetPlatformVariant.desktop(),
    );

    test('Windows and Linux resolve to Ctrl, macOS to Cmd', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final (platform, control) in [
        (TargetPlatform.windows, true),
        (TargetPlatform.linux, true),
        (TargetPlatform.macOS, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final search = AppShortcuts.search;
        expect(search.control, control, reason: '$platform');
        expect(search.meta, !control, reason: '$platform');
        expect(
          AppShortcuts.cancel.control || AppShortcuts.cancel.meta,
          isFalse,
        );
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  for (final (name, w, h, s) in screens) {
    testWidgets('library, Select mode, row menu and delete fit: $name', (
      tester,
    ) async {
      await sized(tester, w, h, s);
      final controller = library(admin: true);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      clean(tester, '$name home');
      expect(find.byKey(const ValueKey('open-admin')), findsOneWidget);

      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      clean(tester, '$name row menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-button')));
      await tester.pump();
      // Not Documents: the top folders are never deleted. On a short screen
      // the row is below the fold, so it is scrolled into view first.
      await tester.ensureVisible(
        find.byKey(const ValueKey('select-card:Photos')),
      );
      await tester.pump();
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('pairing fits: $name', (tester) async {
      await sized(tester, w, h, s);
      final controller = ClientController(
        Directory('/unused-w6-profile'),
        secrets: MemorySecrets(),
      );
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Pair device'), findsOneWidget);
      clean(tester, '$name pairing');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('every Admin section and the revoke confirmation fit: $name', (
      tester,
    ) async {
      await sized(tester, w, h, s);
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
      // Devices live under their user: open alex's list.
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  // A window shorter than the Admin rail's five destinations: the rail must
  // scroll, or the last view cannot be opened. 1366x768 at 200 % and
  // 1280x720 at 175 % leave about 257 and 284 logical pixels under the app
  // bar; the rail needs about 330.
  for (final (name, w, h, s) in const [
    ('1366x768 at 200%', 1366.0, 768.0, 2.0),
    ('1280x720 at 175%', 1280.0, 720.0, 1.75),
  ]) {
    testWidgets('the Admin rail scrolls to its last view: $name', (
      tester,
    ) async {
      // A tap that lands on nothing is a failure here, not a warning.
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      await sized(tester, w, h, s);
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
      expect(tester.takeException(), isNull, reason: 'no overflow');
      final rail = find.byType(NavigationRail);
      final last = find.descendant(
        of: rail,
        matching: find.text(AdminView.values.last.label),
      );
      // The window really is shorter than the rail: its last destination
      // starts below the bottom edge.
      final height =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(tester.getRect(rail).height, greaterThan(height - 56));
      expect(tester.getTopLeft(last.first).dy, greaterThan(height - 24));
      await tester.ensureVisible(last.first);
      await tester.pumpAndSettle();
      await tester.tap(last.first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationRail>(rail).selectedIndex,
        AdminView.values.length - 1,
      );
      clean(tester, '$name Admin ${AdminView.values.last.label}');
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
