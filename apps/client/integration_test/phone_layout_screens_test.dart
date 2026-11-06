// Spec #28 A6 emulator screenshot session (seat E): the phone layout of every
// shared screen on the real Android renderer, fonts and display metrics,
// with the layout fixtures and a fake Admin gateway (no account data).
//
// Built into the QA APK (tool/android/build_apk.sh <n> -t <this file>) and
// driven by tool/android/emu_layout.sh, which sets the display size, density,
// font scale and rotation, then captures the screen at each step: this test
// prints `ANJ-A6 SHOT <name>` and waits until the payload writes
// `files/ack-<name>` (adb run-as), so every capture shows a settled frame.
import 'dart:io';

import 'package:anj_cloud/ui/admin_section.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/admin_section_test.dart' show FakeAdmin, amyDevice, pendingId;
import '../test/layout_fixtures.dart';
import '../test/phone_layout_test.dart' show android;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('A6 phone layout screens', (tester) async {
    final files = await tester.runAsync(getApplicationSupportDirectory);
    var step = 0;
    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      final label = '${(++step).toString().padLeft(2, '0')}-$name';
      // ignore: avoid_print
      print('ANJ-A6 SHOT $label');
      final ack = File('${files!.path}/ack-$label');
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!ack.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (ack.existsSync()) ack.deleteSync();
      });
    }

    // [within]'s list scrolls first when [finder] is not built yet (a phone
    // in landscape starts with the status and toolbar on screen).
    Future<void> tap(Finder finder, {Finder? within, double delta = 80}) async {
      if (within != null && finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          delta,
          scrollable: find
              .descendant(of: within, matching: find.byType(Scrollable))
              .first,
        );
      }
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> adminTab(AdminView view) =>
        tap(find.byKey(ValueKey('admin-tab:${view.name}')));

    // The syncing icon turns forever otherwise.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    final api = FakeAdmin();
    final controller = layoutController(pairingOptions: android)
      ..adminCall = api.call;
    await tester.pumpWidget(
      CloudApp(controller: controller, rootPicker: false, touchInput: true),
    );
    // The app bar logo is an asset; give it a frame to decode.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await shot('home');
    await tap(find.widgetWithText(Tab, 'Editing'));
    await shot('editing');
    await tap(find.widgetWithText(Tab, 'Conflict'));
    await shot('conflict');
    await tap(find.byTooltip('File actions').first);
    await shot('row-menu');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tap(
      find.widgetWithText(Tab, 'Home'),
      within: find.byType(Scaffold).first,
      delta: -80,
    );
    await tap(find.byTooltip('AnJ Cloud menu'));
    await shot('app-menu');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tap(find.byKey(const ValueKey('select-button')));
    await tap(
      find.byKey(const ValueKey('select-card:Documents')),
      within: find.byType(Scaffold).first,
    );
    await shot('select');
    await tap(
      find.byKey(const ValueKey('select-button')),
      within: find.byType(Scaffold).first,
      delta: -80,
    );

    await tap(find.byKey(const ValueKey('open-pairing')));
    await shot('pairing');
    await tap(find.byType(CloseButton));

    await tap(find.byKey(const ValueKey('open-admin')));
    for (final view in AdminView.values) {
      await adminTab(view);
      await shot('admin-${view.name}');
    }
    await adminTab(AdminView.users);
    await tap(
      find.byKey(const ValueKey('admin-user-expand:alex')),
      within: find.byType(UsersView),
    );
    await shot('admin-user-devices');
    await tap(
      find.byKey(const ValueKey('admin-revoke:$amyDevice')),
      within: find.byType(UsersView),
    );
    await shot('admin-revoke-confirm');
    await tap(find.byKey(const ValueKey('admin-confirm-cancel')));
    await adminTab(AdminView.users);
    await tap(
      find.byTooltip('Actions for Alex'),
      within: find.byType(UsersView),
    );
    await shot('admin-user-menu');
    await tap(find.text('Make admin'));
    await shot('admin-role-confirm');
    await tap(find.byKey(const ValueKey('admin-confirm-cancel')));
    await adminTab(AdminView.invitations);
    await tap(
      find.byKey(const ValueKey('admin-approve:$pendingId')),
      within: find.byType(InvitationsView),
    );
    await shot('admin-approve');
    await tap(find.text('Cancel'));
    await tester.pageBack();
    await tester.pumpAndSettle();

    // A non-admin account: no Admin entry.
    controller.isAdmin = false;
    controller.notifyListeners();
    await shot('non-admin-home');

    // The first-sync folder screen, as after a first approval.
    controller.firstSyncPending = true;
    controller.notifyListeners();
    await shot('first-sync');
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
