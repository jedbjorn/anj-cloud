// Spec #28 A6 (acceptance row 16): the shared UI on phone sizes. Every screen
// at 360x800 and 412x915 in portrait and landscape, at font scale 1.0 and
// 1.3, with no overflow, no control outside the screen and 48 dp touch
// targets; the Admin section for an admin with the desktop's confirmations,
// none for a non-admin, and a 403 not-admin closing it.
//
// With ANJ_UI_FONT_DIR (the SDK's material_fonts) and ANJ_A6_PREVIEWS (a
// directory) set, each screen is also written as a readable PNG preview.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/pairing_inputs.dart';
import 'package:anj_cloud/core/sync/first_sync.dart';
import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admin_section_test.dart' show FakeAdmin, amyDevice, pendingId;
import 'layout_fixtures.dart';

const android = PairingOptions(
  liveScan: true,
  firstSync: FirstSyncDefault.cloud,
);

const sizes = {
  '360x800': Size(360, 800),
  '412x915': Size(412, 915),
  '800x360': Size(800, 360),
  '915x412': Size(915, 412),
};
const scales = [1.0, 1.3];

final _boundary = GlobalKey();
final _previews = Platform.environment['ANJ_A6_PREVIEWS'];

class _Phone {
  _Phone(this.controller, this.api);
  final LayoutController controller;
  final FakeAdmin api;
}

Future<_Phone> _open(
  WidgetTester tester,
  Size size,
  double scale, {
  bool admin = true,
  bool firstSync = false,
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
  final api = FakeAdmin();
  final controller = layoutController(admin: admin, pairingOptions: android)
    ..adminCall = api.call
    ..firstSyncPending = firstSync;
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: CloudApp(
        controller: controller,
        rootPicker: false,
        touchInput: true,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Phone(controller, api);
}

bool _isControl(Widget widget) =>
    widget is ButtonStyleButton ||
    widget is IconButton ||
    widget is ChipAttributes ||
    widget is PopupMenuButton ||
    widget is TextField ||
    widget is CheckboxListTile;

/// No overflow, every control on screen horizontally and within the screen
/// vertically unless it scrolled away, and Android's 48 dp tap targets.
Future<void> _check(WidgetTester tester, String screen) async {
  expect(tester.takeException(), isNull, reason: screen);
  final view = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final element in find.byWidgetPredicate(_isControl).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    // Scrolled out of view vertically is fine; a list scrolls.
    if (rect.bottom <= 0 || rect.top >= view.height) continue;
    // The chip row and the Admin tabs scroll sideways by design.
    if (Scrollable.maybeOf(element, axis: Axis.horizontal) != null) continue;
    expect(
      rect.left >= -0.5 && rect.right <= view.width + 0.5,
      isTrue,
      reason:
          '$screen: ${element.widget.runtimeType} at $rect leaves the screen',
    );
  }
  await expectLater(
    tester,
    meetsGuideline(androidTapTargetGuideline),
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
    final name = screen.replaceAll(RegExp('[^a-z0-9.-]+'), '-');
    File('$directory/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Scrolls [within]'s first scrollable until [target] is on screen; on a
/// phone in landscape the list starts below the status and toolbar.
Future<void> _reveal(WidgetTester tester, Finder target, Finder within) async {
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      80,
      scrollable: find
          .descendant(of: within, matching: find.byType(Scrollable))
          .first,
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _adminTab(WidgetTester tester, AdminView view) async {
  final tab = find.byKey(ValueKey('admin-tab:${view.name}'));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadPreviewFonts);

  for (final MapEntry(key: name, value: size) in sizes.entries) {
    for (final scale in scales) {
      final at = '$name@${scale}x';

      testWidgets('home, tabs, menus and Select mode at $at', (tester) async {
        final handle = tester.ensureSemantics();
        await _open(tester, size, scale);
        // Android has no root picker; the status leads.
        expect(find.text('/home/demo/anj-cloud'), findsNothing);
        expect(find.text('Choose root'), findsNothing);
        expect(find.byKey(const ValueKey('sync-status')), findsOneWidget);
        await _check(tester, '$at-01-home');

        await _tapTab(tester, 'Editing');
        expect(find.byKey(const ValueKey('finish:notes.txt')), findsOneWidget);
        await _check(tester, '$at-02-editing');

        await _tapTab(tester, 'Conflict');
        expect(find.byKey(const ValueKey('row:budget.ods')), findsOneWidget);
        await _check(tester, '$at-03-conflict');
        await tester.tap(find.byTooltip('File actions').first);
        await tester.pumpAndSettle();
        expect(find.text('Keep both versions'), findsOneWidget);
        await _check(tester, '$at-04-row-menu');
        await tester.tap(find.text('Details and preserved copies'));
        await tester.pumpAndSettle();
        await _check(tester, '$at-05-details');
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        await _tapTab(tester, 'Home');
        await tester.tap(find.byTooltip('AnJ Cloud menu'));
        await tester.pumpAndSettle();
        expect(find.text('Pause sync'), findsOneWidget);
        // Desktop-only entries stay hidden: no Start at login, no Quit.
        expect(find.text('Start at login'), findsNothing);
        expect(find.text('Quit AnJ Cloud'), findsNothing);
        await _check(tester, '$at-06-app-menu');
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('select-button')));
        await tester.pumpAndSettle();
        // Photos: Documents, Music and Videos can be neither Cloud-only nor
        // deleted (spec #34 P7), so their bulk actions are disabled.
        final card = find.byKey(const ValueKey('select-card:Photos'));
        // Landscape: the header first scrolls away until the list shows.
        final first = find.byKey(const ValueKey('select-card:Documents'));
        await _reveal(tester, first, find.byType(Scaffold).first);
        if (card.hitTestable().evaluate().isEmpty) {
          // Below the fold on small or landscape screens: scroll the list
          // that holds the first card (Documents) until Photos is built.
          await tester.scrollUntilVisible(
            card,
            80,
            scrollable: find
                .ancestor(
                  of: find.byKey(const ValueKey('select-card:Documents')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        for (final action in ['bulk-local', 'bulk-cloud', 'bulk-delete']) {
          final rect = tester.getRect(find.byKey(ValueKey(action)));
          expect(rect.bottom, lessThanOrEqualTo(size.height), reason: action);
        }
        await _check(tester, '$at-07-select');
        await tester.tap(find.byKey(const ValueKey('bulk-delete')));
        await tester.pumpAndSettle();
        expect(find.text('Delete selected items everywhere?'), findsOneWidget);
        await _check(tester, '$at-08-delete-confirm');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        handle.dispose();
      });

      testWidgets('rows open on tap and long-press chooses the colour at $at', (
        tester,
      ) async {
        final phone = await _open(tester, size, scale);
        await _tapTab(tester, 'Editing');
        await tester.tap(find.byKey(const ValueKey('content:notes.txt')));
        await tester.pumpAndSettle();
        expect(phone.controller.commands, ['open:notes.txt']);
        await tester.longPress(find.byKey(const ValueKey('content:notes.txt')));
        await tester.pumpAndSettle();
        expect(find.text('Icon colour · this device'), findsOneWidget);
        await tester.ensureVisible(find.text('Teal'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Teal'));
        await tester.pumpAndSettle();
        expect(phone.controller.colours, {'notes.txt': 0xff007c83});
        expect(phone.controller.commands, ['open:notes.txt']);
      });

      testWidgets('pairing page at $at', (tester) async {
        final handle = tester.ensureSemantics();
        await _open(tester, size, scale);
        await tester.tap(find.byKey(const ValueKey('open-pairing')));
        await tester.pumpAndSettle();
        // A page on a phone in either orientation, never a squeezed dialog.
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.widgetWithText(AppBar, 'Pair this device'), findsOneWidget);
        await _check(tester, '$at-09-pairing');
        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();
        handle.dispose();
      });

      testWidgets('first-sync folder screen at $at', (tester) async {
        final handle = tester.ensureSemantics();
        await _open(tester, size, scale, firstSync: true);
        expect(find.text('Choose what stays on this device'), findsOneWidget);
        await _check(tester, '$at-10-first-sync');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('first-sync-confirm')),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await _check(tester, '$at-11-first-sync-end');
        handle.dispose();
      });

      testWidgets('Admin: every view, revoke, role change and approve with '
          'the desktop confirmations at $at', (tester) async {
        final handle = tester.ensureSemantics();
        final phone = await _open(tester, size, scale);
        final api = phone.api;
        await tester.tap(find.byKey(const ValueKey('open-admin')));
        await tester.pumpAndSettle();
        // The rail's views, order and words, as tabs on a phone.
        expect(find.byType(NavigationRail), findsNothing);
        final tabs = tester
            .widgetList<Tab>(
              find.descendant(
                of: find.byKey(const ValueKey('admin-tabs')),
                matching: find.byType(Tab),
              ),
            )
            .map((tab) => (tab.key! as ValueKey<String>).value)
            .toList();
        expect(tabs, [
          for (final view in AdminView.values) 'admin-tab:${view.name}',
        ]);
        for (final view in AdminView.values) {
          await _adminTab(tester, view);
          expect(find.text(view.label), findsWidgets, reason: view.label);
          await _check(tester, '$at-${12 + view.index}-admin-${view.name}');
        }
        expect(api.mutations(), isEmpty);

        // Revoke, from Alex's devices under her user row (spec #34 P8): the
        // server's text; Cancel sends nothing more.
        await _adminTab(tester, AdminView.users);
        final expand = find.byKey(const ValueKey('admin-user-expand:alex'));
        await _reveal(tester, expand, find.byType(UsersView));
        await tester.tap(expand);
        await tester.pumpAndSettle();
        await _check(tester, '$at-17b-admin-user-devices');
        final revoke = find.byKey(const ValueKey('admin-revoke:$amyDevice'));
        await _reveal(tester, revoke, find.byType(UsersView));
        await tester.tap(revoke);
        await tester.pumpAndSettle();
        expect(find.text('Revoke the VM host (sam)?'), findsOneWidget);
        expect(
          find.text(
            'This device stops syncing at once and must be paired again to return.',
          ),
          findsOneWidget,
        );
        await _check(tester, '$at-18-admin-revoke-confirm');
        await tester.tap(find.byKey(const ValueKey('admin-confirm-cancel')));
        await tester.pumpAndSettle();
        expect(api.mutations().toList(), hasLength(1));
        // Confirm resends with the token.
        await _reveal(tester, revoke, find.byType(UsersView));
        await tester.tap(revoke);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('admin-confirm-ok')));
        await tester.pumpAndSettle();
        expect(api.mutations().last.$3, {'expect': 'd2', 'confirm': 'token-1'});

        // Role change: Make admin, confirmed by the server's prompt.
        await _adminTab(tester, AdminView.users);
        final alex = find.byTooltip('Actions for Alex');
        await _reveal(tester, alex, find.byType(UsersView));
        await tester.tap(alex);
        await tester.pumpAndSettle();
        await _check(tester, '$at-19-admin-user-menu');
        await tester.tap(find.text('Make admin'));
        await tester.pumpAndSettle();
        expect(find.text('Server effect text.'), findsOneWidget);
        await _check(tester, '$at-20-admin-role-confirm');
        await tester.tap(find.byKey(const ValueKey('admin-confirm-ok')));
        await tester.pumpAndSettle();
        expect(api.mutations().last.$2, '/v1/admin/users/alex/admin');
        expect(api.mutations().last.$3, {
          'admin': true,
          'expect': 'u2',
          'confirm': 'token-1',
        });

        // Approve: the fingerprint typed, never pre-filled.
        await _adminTab(tester, AdminView.invitations);
        final approve = find.byKey(const ValueKey('admin-approve:$pendingId'));
        await _reveal(tester, approve, find.byType(InvitationsView));
        await tester.tap(approve);
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('admin-fingerprint'));
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        await tester.enterText(field, 'ab' * 32);
        await tester.pumpAndSettle();
        await _check(tester, '$at-21-admin-approve');
        await tester.tap(
          find.byKey(const ValueKey('admin-fingerprint-approve')),
        );
        await tester.pumpAndSettle();
        expect(
          api.mutations().last.$2,
          '/v1/admin/invitations/$pendingId/approve',
        );
        expect(api.mutations().last.$3, {
          'fingerprint': 'ab' * 32,
          'expect': 'i1',
        });
        handle.dispose();
      });
    }
  }

  testWidgets('a non-admin sees no Admin section; a 403 not-admin closes it', (
    tester,
  ) async {
    final phone = await _open(tester, sizes['360x800']!, 1.0, admin: false);
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    expect(find.byTooltip('Admin'), findsNothing);
    await _preview(tester, 'non-admin-home');

    // The role goes while Admin is open: the gateway's 403 closes it.
    phone.controller.isAdmin = true;
    phone.controller.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-admin')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminPage), findsOneWidget);
    phone.api.notAdmin = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminPage), findsNothing);
    expect(find.byKey(const ValueKey('open-admin')), findsNothing);
    expect(find.text('Your admin role was removed.'), findsOneWidget);
    expect(phone.api.mutations(), isEmpty);
  });

  // #70 review: gestures follow the platform's input, never the window size.
  // A small desktop window keeps double-click and the desktop hint.
  for (final size in const [Size(560, 700), Size(1000, 440)]) {
    testWidgets('a small desktop window (${size.width.toInt()}x'
        '${size.height.toInt()}) keeps double-click to open', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.reset);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = layoutController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tapTab(tester, 'Editing');
      final content = find.byKey(const ValueKey('content:notes.txt'));
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: content, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('Double-click to open file'));
      expect(tooltip.message, isNot(contains('Tap to open')));
      // One click opens nothing.
      await tester.tap(content);
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(controller.commands, isEmpty);
      // A double-click opens exactly once.
      await tester.tap(content);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(content);
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(controller.commands, ['open:notes.txt']);
      // A long press is not the colour menu with a mouse; right-click is.
      await tester.longPress(content);
      await tester.pumpAndSettle();
      expect(find.text('Icon colour · this device'), findsNothing);
      expect(controller.commands, ['open:notes.txt']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }

  testWidgets(
    'Android before its root is set says nothing about choosing one',
    (tester) async {
      final phone = await _open(tester, sizes['360x800']!, 1.0);
      phone.controller
        ..root = null
        ..entries = []
        ..syncing = {};
      phone.controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('Choose a root'), findsNothing);
      expect(
        find.text('Files will appear here after a complete scan.'),
        findsOneWidget,
      );
    },
  );

  // #70 review: a revealed row on a landscape phone sits in the
  // NestedScrollView's body; scrolling up brings the rows above it and then
  // the status, tabs and toolbar back, and scrolling down hides them again.
  testWidgets('landscape: reveal from search, then scroll up and down', (
    tester,
  ) async {
    final phone = await _open(tester, sizes['915x412']!, 1.0);
    final controller = phone.controller;
    controller.entries = [
      ...controller.entries,
      for (var i = 0; i < 40; i++)
        {
          'path': 'Documents/Archive/file-${i.toString().padLeft(2, '0')}.txt',
          'kind': 'file',
          'effectiveRetention': 'local',
          'status': 'current local',
          'selectionVersion': '1',
        },
      {
        'path': 'Documents/Archive/needle.txt',
        'kind': 'file',
        'effectiveRetention': 'local',
        'status': 'current local',
        'selectionVersion': '1',
      },
    ];
    controller.notifyListeners();
    await tester.pumpAndSettle();
    final status = find.byKey(const ValueKey('sync-status'));
    expect(status.hitTestable(), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      'needle',
    );
    await tester.pumpAndSettle();
    final show = find.byKey(
      const ValueKey('show-in-folder:Documents/Archive/needle.txt'),
    );
    await _reveal(tester, show, find.byType(Scaffold).first);
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final target = find.byKey(
      const ValueKey('row:Documents/Archive/needle.txt'),
    );
    expect(target.hitTestable(), findsOneWidget, reason: 'revealed row shown');

    // Scroll up: the rows above the target, then the header.
    final list = find.byType(NestedScrollView);
    final documents = find.byKey(const ValueKey('row:Documents'));
    // The list scrolls first, through every row above the target, and only
    // then the header; lazily estimated row heights can bring the header back
    // a drag before the list's exact top, so drag until both show.
    bool atTop() =>
        status.hitTestable().evaluate().isNotEmpty &&
        documents.hitTestable().evaluate().isNotEmpty;
    for (var i = 0; i < 40 && !atTop(); i++) {
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
    }
    // One more drag changes nothing: both scroll views are at their top.
    final before = tester.getRect(documents);
    await tester.drag(list, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getRect(documents), before);
    expect(tester.takeException(), isNull);
    expect(status.hitTestable(), findsOneWidget, reason: 'header is back');
    expect(documents.hitTestable(), findsOneWidget, reason: 'list at its top');
    expect(find.widgetWithText(Tab, 'Home').hitTestable(), findsOneWidget);

    // Scroll down: the header goes again and the list reaches the target.
    for (var i = 0; i < 40 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();
    }
    expect(target.hitTestable(), findsOneWidget, reason: 'target reachable');
    expect(status.hitTestable(), findsNothing, reason: 'header scrolled away');
    expect(tester.takeException(), isNull);
  });
}
