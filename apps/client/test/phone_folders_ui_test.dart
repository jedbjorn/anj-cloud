// Spec #52 Permission and Paused States, Settings Text: the All files access
// explanation, the paused attention line, the phone folders' place in
// settings and the first line of "Apps with access" (widget tests, H).
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/ui/apps_access_page.dart';
import 'package:anj_cloud/ui/phone_folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apps_access_page_test.dart' show FakeAccess;
import 'fakes.dart';
import 'test_platform.dart';

class _Access implements PhoneFolderAccess {
  bool granted = false;
  int opened = 0;
  final scans = <List<String>>[];
  @override
  Future<PhoneFolderLayout> check() async => PhoneFolderLayout(
    base: '/storage/emulated/0',
    staging: '/storage/emulated/0/Android/media/x/anj-staging',
    paused: !granted,
  );
  @override
  Future<void> openSettings() async => opened++;
  @override
  Future<void> scan(List<String> paths) async => scans.add(paths);
}

void main() {
  late Directory profile;
  late _Access access;
  late ClientController controller;

  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-phone-ui-');
    access = _Access();
    controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
      phoneFolders: access,
    );
  });
  tearDown(() => profile.deleteSync(recursive: true));

  Widget host(Widget Function() child) => MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => child(),
      ),
    ),
  );

  testWidgets('the explanation screen: Allow opens the setting; either '
      'answer is remembered', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: PhoneFoldersScreen(controller: controller)),
    );
    expect(find.text(phoneFoldersExplanation), findsOneWidget);
    expect(
      phoneFoldersExplanation,
      "AnJ Cloud keeps Music, Videos and Documents in your phone's own "
      'folders so every app can use them. Android calls this All files access.',
    );
    await tester.tap(find.byKey(const ValueKey('phone-folders-allow')));
    await tester.pump();
    expect(access.opened, 1);
    expect(controller.phoneFoldersAsked, isTrue);
  });

  testWidgets('paused: one attention line with an action; nothing when '
      'access is there', (tester) async {
    await controller.checkPhoneFolders();
    expect(controller.phoneFoldersPaused, isTrue);
    await tester.pumpWidget(
      host(() => PhoneFoldersNotice(controller: controller)),
    );
    expect(
      find.text(
        'Music, Videos and Documents are paused: allow All files access',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('phone-folders-open-settings')));
    expect(access.opened, 1);
    access.granted = true;
    await controller.checkPhoneFolders();
    await tester.pump();
    expect(controller.phoneFoldersPaused, isFalse);
    expect(find.byKey(const ValueKey('phone-folders-paused')), findsNothing);
  });

  testWidgets('settings show each phone folder\'s place', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: PhoneFoldersPage(controller: controller)),
    );
    expect(find.text('Internal storage › Music'), findsOneWidget);
    expect(find.text('Internal storage › Movies'), findsOneWidget);
    expect(find.text('Internal storage › Documents'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);
  });

  testWidgets('"Apps with access" starts with the phone folders line', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppsAccessPage(access: FakeAccess(), phoneFolders: true),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        "Music, Videos and Documents are in your phone's own folders. Apps "
        'with media or file access can use them. The approvals below cover '
        'your other folders.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(
      MaterialApp(home: AppsAccessPage(access: FakeAccess())),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('apps-access-phone-folders')),
      findsNothing,
    );
  });

  test('the explanation is due once: paired, paused, not answered', () async {
    await controller.checkPhoneFolders();
    expect(controller.phoneFoldersScreenDue, isFalse, reason: 'not paired');
    controller.pairingState = 'paired';
    expect(controller.phoneFoldersScreenDue, isTrue);
    controller.phoneFoldersAsked = true;
    expect(controller.phoneFoldersScreenDue, isFalse);
  });
}
