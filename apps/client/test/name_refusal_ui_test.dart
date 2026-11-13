import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final residual = cantSyncNameStatus(CloudNameProblem.forbiddenName);

Map<String, dynamic> _row(
  String path, {
  String? cloudPath,
  String kind = 'file',
  String status = 'current local',
  bool refused = false,
}) => {
  'path': path,
  'cloudPath': ?cloudPath,
  'kind': kind,
  'selectionVersion': '1',
  'status': status,
  'effectiveRetention': 'local',
  'cantSyncName': refused,
  'presentationErrors': refused ? [residual] : <String>[],
  'syncPending': refused,
};

class _Controller extends ClientController {
  _Controller(super.profile);
  final renames = <String>[];
  final creates = <String>[];
  Object? failure;

  /// This device's spelling of a typed name (a Windows device, spec #49 R3).
  static String _spelled(String name) =>
      const {'aux.txt': 'aux_.txt', 'aux': 'aux_'}[name] ?? name;

  @override
  Future<String> renameLocal(String path, String name) async {
    renames.add('$path -> $name');
    if (failure case final error?) throw error;
    return '${path.substring(0, path.lastIndexOf('/') + 1)}${_spelled(name)}';
  }

  @override
  bool get canCreateFolder => true;

  @override
  Future<String> createFolder({
    required String parent,
    required String name,
    required Retention retention,
  }) async {
    creates.add('$parent -> $name');
    return '$parent/${_spelled(name)}';
  }
}

void main() {
  late Directory profile;
  late _Controller controller;
  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-name-refusal-ui-');
    controller = _Controller(profile)
      ..root = '/synthetic/files'
      ..entries = [
        _row('Documents', kind: 'directory'),
        _row('Documents/.htaccess', status: residual, refused: true),
        _row(
          'Documents/.well-known',
          kind: 'directory',
          status: residual,
          refused: true,
        ),
        _row('Documents/readme.txt'),
        // Held here under local aliases of their cloud names (spec #49 R3).
        _row('Documents/report (2).pdf', cloudPath: 'Documents/report.pdf'),
        {
          ..._row(
            'Documents/CON_',
            cloudPath: 'Documents/CON',
            kind: 'directory',
          ),
          'localDirectoryAvailable': true,
        },
        _row('Documents/.bashrc'),
        _row('Documents/old.txt', status: 'removed locally'),
        // A cloud item no local name fits (spec #49 R3, decision #198).
        {
          ..._row('Documents/a.txt', status: unplaceableStatus),
          'presentationErrors': [unplaceableStatus],
          'effectiveRetention': 'cloud',
        },
        // A full path over 259 characters on Windows: information only.
        {
          ..._row('Documents/deep.txt'),
          'presentationNotes': [longPathNote],
        },
      ];
  });
  tearDown(() {
    controller.dispose();
    profile.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle:Documents')));
    await tester.pumpAndSettle();
  }

  Finder inCard(String path, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('card:$path')),
    matching: matching,
  );

  testWidgets('the row reads the refusal, is amber, and offers Rename only '
      'there', (tester) async {
    await open(tester);
    expect(inCard('Documents/.htaccess', find.text(residual)), findsOneWidget);
    expect(
      inCard(
        'Documents/.htaccess',
        find.widgetWithText(Chip, 'Needs attention'),
      ),
      findsOneWidget,
    );
    final container = tester.widget<Container>(
      find.byKey(const ValueKey('attention:Documents/.htaccess')),
    );
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.left.color, Colors.amber);
    expect(
      find.byKey(const ValueKey('rename:Documents/.htaccess')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('rename:Documents/readme.txt')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('rename:Documents/.bashrc')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unplaceable cloud item is amber with its reason and no '
      'Rename; '
      'a long path shows its note without amber', (tester) async {
    await open(tester);
    expect(
      inCard('Documents/a.txt', find.text(unplaceableStatus)),
      findsOneWidget,
    );
    expect(
      inCard('Documents/a.txt', find.widgetWithText(Chip, 'Needs attention')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rename:Documents/a.txt')), findsNothing);
    expect(
      inCard('Documents/deep.txt', find.text(longPathNote)),
      findsOneWidget,
    );
    expect(
      inCard(
        'Documents/deep.txt',
        find.widgetWithText(Chip, 'Needs attention'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Rename explains and refuses only an empty name, a path '
      'separator, a name R2 cannot fix, or a name taken here (spec #49)', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('rename:Documents/.htaccess')));
    await tester.pumpAndSettle();
    expect(find.text('Rename .htaccess'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rename-reason'))).data,
      contains('the cloud does not allow this name'),
    );
    final field = find.byKey(const ValueKey('rename-name'));
    for (final (name, message) in [
      ('', 'Enter a name'),
      ('a/b', 'path separators'),
      ('x.part', 'temporary downloads'),
      ('.HTAccess', 'cloud does not allow this name.'),
      ('readme.txt', 'already uses'),
      ('.htaccess', 'different name'),
    ]) {
      await tester.enterText(field, name);
      await tester.tap(find.byKey(const ValueKey('confirm-rename')));
      await tester.pumpAndSettle();
      expect(find.textContaining(message), findsWidgets, reason: name);
    }
    expect(controller.renames, isEmpty);
    // A name used only by a hidden, completed deletion is free.
    await tester.enterText(field, 'old.txt');
    await tester.pumpAndSettle();
    expect(find.textContaining('already uses'), findsNothing);
    // Names decision #120 refused are cleaned by the rule, not refused.
    for (final name in ['aux.txt', 'notes.', 'a:b', 'README.TXT']) {
      await tester.enterText(field, name);
      await tester.pumpAndSettle();
      // Only the explanation above the field.
      expect(find.textContaining("can't sync:"), findsOneWidget, reason: name);
    }
    await tester.enterText(field, 'htaccess.txt');
    await tester.tap(find.byKey(const ValueKey('confirm-rename')));
    await tester.pumpAndSettle();
    expect(controller.renames, ['Documents/.htaccess -> htaccess.txt']);
    expect(find.text('Rename .htaccess'), findsNothing);
    expect(find.text('Renamed to htaccess.txt'), findsOneWidget);
  });

  testWidgets('a residual folder takes a name R2 cleans for folders: '
      '`.part` is accepted (decision #195)', (tester) async {
    await open(tester);
    await tester.tap(
      find.byKey(const ValueKey('rename:Documents/.well-known')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rename-name')),
      'Site.part',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary downloads'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('confirm-rename')));
    await tester.pumpAndSettle();
    expect(controller.renames, ['Documents/.well-known -> Site.part']);
  });

  testWidgets('a refused rename keeps the dialog open with the reason', (
    tester,
  ) async {
    controller.failure = const FileSystemException(
      'Could not rename: The item changed or is gone.',
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('rename:Documents/.htaccess')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rename-name')), 'x.txt');
    await tester.tap(find.byKey(const ValueKey('confirm-rename')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rename-error')), findsOneWidget);
    expect(find.textContaining('changed or is gone'), findsOneWidget);
    expect(find.text('Rename .htaccess'), findsOneWidget);
  });

  group('no prompt or confirmation shows a local alias (decision #193)', () {
    testWidgets('Details is titled with the cloud path', (tester) async {
      await open(tester);
      await tester.tap(
        inCard('Documents/report (2).pdf', find.byTooltip('File actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details and preserved copies'));
      await tester.pumpAndSettle();
      final details = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: details,
          matching: find.text('Documents/report.pdf'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: details,
          matching: find.textContaining('report (2)'),
        ),
        findsNothing,
      );
    });

    testWidgets('Rename confirms the typed cloud name, checked against the '
        'cloud names beside it', (tester) async {
      await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('rename:Documents/.htaccess')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('rename-name'));
      await tester.enterText(field, 'report.pdf');
      await tester.pumpAndSettle();
      expect(find.textContaining('already uses'), findsOneWidget);
      // A local alias is not a cloud name: it is free.
      await tester.enterText(field, 'report (2).pdf');
      await tester.pumpAndSettle();
      expect(find.textContaining('already uses'), findsNothing);
      await tester.enterText(field, 'aux.txt');
      await tester.tap(find.byKey(const ValueKey('confirm-rename')));
      await tester.pumpAndSettle();
      expect(controller.renames, ['Documents/.htaccess -> aux.txt']);
      expect(find.text('Renamed to aux.txt'), findsOneWidget);
      expect(find.textContaining('aux_'), findsNothing);
    });

    testWidgets('Create folder lists parents and confirms under their cloud '
        'path; the local path stays the command key', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('create-folder-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-parent')));
      await tester.pumpAndSettle();
      final menu = find.byType(DropdownMenuItem<String>);
      expect(
        find.descendant(of: menu, matching: find.text('Documents/CON')),
        findsWidgets,
      );
      expect(
        find.descendant(of: menu, matching: find.textContaining('CON_')),
        findsNothing,
      );
      await tester.tap(find.text('Documents/CON').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('folder-name')), 'aux');
      await tester.tap(find.byKey(const ValueKey('confirm-create-folder')));
      await tester.pumpAndSettle();
      expect(controller.creates, ['Documents/CON_ -> aux']);
      expect(find.text('Created folder: Documents/CON/aux'), findsOneWidget);
      expect(find.textContaining('_'), findsNothing);
    });
  });
}
