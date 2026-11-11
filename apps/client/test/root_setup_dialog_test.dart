// The root setup dialog while it works and after the root was saved, and the
// parent checks of configureRoot (a file, a path through one).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/app.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// A controller whose root setup waits for the test, then fails as told.
class _ScriptedController extends ClientController {
  _ScriptedController(super.profile, {this.saveRoot})
    : super(secrets: MemorySecrets(), nativeLibrary: testNativeLibrary);
  final String? saveRoot;
  final release = Completer<void>();
  int attempts = 0;

  @override
  Future<void> configureRoot(
    String parent, {
    List<String> knownRoots = const [],
    bool automatic = false,
  }) async {
    attempts++;
    await release.future;
    if (saveRoot != null) root = saveRoot; // saved, then the start failed
    throw FileSystemException(
      saveRoot == null ? 'The folder is refused' : 'sync did not start',
      parent,
    );
  }
}

void main() {
  late Directory fixture;
  setUp(() => fixture = Directory.systemTemp.createTempSync('anj-setup-'));
  tearDown(() => fixture.deleteSync(recursive: true));

  Future<void> openAndSubmit(WidgetTester tester, ClientController c) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CloudApp(controller: c));
    await tester.tap(find.text('Choose root'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Parent directory'),
      fixture.path,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this root'));
    await tester.pump();
  }

  testWidgets('Escape and a click outside do not close it while setting up, '
      'and the refusal then lands in it', (tester) async {
    final controller = _ScriptedController(
      Directory(p.join(fixture.path, 'profile')),
    );
    addTearDown(controller.dispose);
    await openAndSubmit(tester, controller);
    expect(find.text('Setting up…'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // the barrier
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(controller.attempts, 1);

    controller.release.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('root-setup-error')),
          )
          .data,
      contains('The folder is refused'),
    );
    expect(find.text('Use this root'), findsOneWidget);
    // Idle again, Escape closes it as before.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a root saved before the failure gets an accurate message and '
      'a way out, not a retry', (tester) async {
    final controller = _ScriptedController(
      Directory(p.join(fixture.path, 'profile')),
      saveRoot: '/saved/anj-cloud',
    );
    addTearDown(controller.dispose);
    await openAndSubmit(tester, controller);
    controller.release.complete();
    await tester.pumpAndSettle();
    final text = tester
        .widget<SelectableText>(find.byKey(const ValueKey('root-setup-error')))
        .data!;
    expect(text, contains('set up at /saved/anj-cloud'));
    expect(text, contains('sync did not start'));
    expect(find.text('Use this root'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.attempts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  group('configureRoot checks the parent', () {
    late ClientController controller;
    setUp(() {
      controller = ClientController(
        Directory(p.join(fixture.path, 'profile')),
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
    });
    tearDown(() => controller.dispose());

    Matcher refusal(String text) => throwsA(
      isA<FileSystemException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );

    test('a regular file is not a folder', () async {
      final file = File(p.join(fixture.path, 'a-file'))..writeAsStringSync('x');
      await expectLater(
        controller.configureRoot(file.path),
        refusal('is a file, not a folder'),
      );
    });

    test('a path through a file is not a folder, nor "missing"', () async {
      final file = File(p.join(fixture.path, 'a-file'))..writeAsStringSync('x');
      await expectLater(
        controller.configureRoot(p.join(file.path, 'child')),
        refusal('is not a folder'),
      );
    }, skip: Platform.isLinux || Platform.isMacOS ? null : 'POSIX error codes');

    test('a parent that cannot be read says so', () async {
      final locked = Directory(p.join(fixture.path, 'locked'))..createSync();
      final inner = Directory(p.join(locked.path, 'inner'))..createSync();
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['700', locked.path]));
      if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
        return; // root reads everything
      }
      await expectLater(
        controller.configureRoot(inner.path),
        refusal('cannot be read'),
      );
    }, skip: Platform.isLinux || Platform.isMacOS ? null : 'POSIX permissions');
  });
}
