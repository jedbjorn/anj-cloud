// A root the picker cannot set up is said so, and the saying stays on screen
// (it used to close the dialog and leave a snackbar that was gone in seconds).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/root_setup_dialog.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  late Directory fixture;
  late ClientController controller;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-picker-');
    controller = ClientController(
      Directory(p.join(fixture.path, 'profile')),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
  });
  tearDown(() {
    controller.dispose();
    fixture.deleteSync(recursive: true);
  });

  test(
    'configureRoot names a missing parent before touching anything',
    () async {
      final missing = p.join(fixture.path, 'no', 'such', 'parent');
      await expectLater(
        controller.configureRoot(missing),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e.message, 'message', contains('does not exist'))
              .having((e) => e.path, 'path', missing),
        ),
      );
      expect(controller.root, isNull);
      expect(Directory(p.join(fixture.path, 'profile')).existsSync(), isFalse);
      expect(Directory(p.join(fixture.path, 'no')).existsSync(), isFalse);
    },
  );

  test('describeRootError reads a file error as its message and path', () {
    expect(
      describeRootError(const FileSystemException('Not allowed', r'C:\x')),
      r'Not allowed (C:\x)',
    );
    expect(
      describeRootError(const FileSystemException(r'C:\x is taken', r'C:\x')),
      r'C:\x is taken',
    );
    expect(describeRootError(StateError('boom')), 'Bad state: boom');
  });

  testWidgets('a parent that does not exist is reported in the dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.tap(find.text('Choose root'));
    await tester.pumpAndSettle();
    final missing = p.join(fixture.path, 'no', 'such', 'parent');
    await tester.enterText(
      find.widgetWithText(TextField, 'Parent directory'),
      missing,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this root'));
    await tester.pumpAndSettle();
    // Still open, with the reason on screen and no snackbar to expire.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final reason = tester.widget<SelectableText>(
      find.byKey(const ValueKey('root-setup-error')),
    );
    expect(reason.data, contains('The parent folder does not exist'));
    expect(reason.data, contains(missing));
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const ValueKey('root-setup-error')), findsOneWidget);
    // Editing the path clears the stale reason; Cancel closes without errors
    // (the fields' controllers are released with the route).
    await tester.enterText(
      find.widgetWithText(TextField, 'Parent directory'),
      fixture.path,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('root-setup-error')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
