import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/ui/manage_sharing_dialog.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake gateway behind the Manage sharing modal (spec #26).
class FakeGateway {
  FakeGateway({
    List<Map<String, Object?>>? users,
    List<Map<String, Object?>>? shares,
  }) : users =
           users ??
           [
             {'id': 'alice', 'display_name': 'Alice'},
             {'id': 'bob', 'display_name': 'Bob'},
             {'id': 'carol', 'display_name': 'Carol'},
           ],
       shares =
           shares ??
           [
             {
               'share_id': '1',
               'path': 'Family',
               'recipient_id': 'alice',
               'recipient_display_name': 'Alice',
               'permission': 'edit',
             },
             {
               'share_id': '2',
               'path': 'Family',
               'recipient_id': 'bob',
               'recipient_display_name': 'Bob',
               // A View only share made before decision #155.
               'permission': 'view',
             },
             {
               'share_id': '3',
               'path': 'Other',
               'recipient_id': 'carol',
               'recipient_display_name': 'Carol',
               'permission': 'view',
             },
           ];
  final List<Map<String, Object?>> users;
  final List<Map<String, Object?>> shares;
  final calls = <String>[];
  final failing = <String, String>{};
  String? failLoad;

  /// While set, `load` waits for it: the progress indicator is observable.
  Completer<void>? gate;
  var next = 10;

  Future<Object?> call(
    String op, {
    String? path,
    String? recipient,
    String? permission,
    String? share,
  }) async {
    final label = [op, ?share, ?recipient, ?permission].join(' ');
    calls.add(label);
    if (op == 'load') {
      await gate?.future;
      if (failLoad case final message?) throw CloudFailure(message);
      return {'users': users, 'shares': shares};
    }
    if (failing[label] case final message?) {
      throw CloudFailure(message, status: 502);
    }
    switch (op) {
      case 'remove':
        shares.removeWhere((s) => s['share_id'] == share);
      case 'update':
        shares.firstWhere((s) => s['share_id'] == share)['permission'] =
            permission;
      case 'create':
        final user = users.firstWhere((u) => u['id'] == recipient);
        shares.add({
          'share_id': '${next++}',
          'path': path,
          'recipient_id': recipient,
          'recipient_display_name': user['display_name'],
          'permission': permission,
        });
    }
    return null;
  }
}

class _Controller extends ClientController {
  _Controller(super.profile);
  String? unavailable;
  FakeGateway gateway = FakeGateway();
  @override
  String? get sharingUnavailable => unavailable;
  @override
  Future<Object?> sharing(
    String op, {
    String? path,
    String? recipient,
    String? permission,
    String? share,
  }) => gateway.call(
    op,
    path: path,
    recipient: recipient,
    permission: permission,
    share: share,
  );
  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {}
}

Map<String, dynamic> _row(
  String path, {
  String kind = 'directory',
  String? etag = '"e"',
  Map<String, Object?> extra = const {},
}) => {
  'path': path,
  'kind': kind,
  'etag': etag,
  'selectionVersion': '1',
  'status': 'current local',
  'effectiveRetention': 'local',
  'expectedPresent': true,
  ...extra,
};

List<Map<String, dynamic>> _library() => [
  _row(
    'Family',
    extra: {
      'sharedOut': true,
      'sharedWith': ['Alice', 'Bob'],
    },
  ),
  _row('Family/notes.txt', kind: 'file'),
  _row('Local only', etag: null),
  _row('Shared', extra: {'inSharedFolder': true}),
  _row(
    'Shared/Photos',
    extra: {
      'inSharedFolder': true,
      'viewOnly': true,
      'incomingShare': {
        'share_id': '7',
        'path': 'Shared/Photos',
        'owner_display_name': 'Alice',
        'permission': 'view',
        'owner_unavailable': false,
      },
    },
  ),
  _row(
    'Shared/Photos/a.jpg',
    kind: 'file',
    extra: {'inSharedFolder': true, 'viewOnly': true},
  ),
  // An incoming mount before the incoming list has loaded (review L2).
  _row('Shared/Pending', extra: {'inSharedFolder': true}),
  // The recipient's own folder under Shared/: not a mount (follow-up L-c).
  _row('Shared/Mine', extra: {'inSharedFolder': true, 'incomingMount': false}),
  _row(
    'Shared/Docs',
    extra: {
      'inSharedFolder': true,
      'status': "The owner's account is disabled",
      'incomingShare': {
        'share_id': '8',
        'path': 'Shared/Docs',
        'owner_display_name': 'Bob',
        'permission': 'edit',
        'owner_unavailable': true,
      },
    },
  ),
];

void main() {
  setUpAll(() async {
    final fonts = Platform.environment['ANJ_UI_FONT_DIR'];
    if (fonts == null) return;
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File('$fonts/${font.value}')
                .readAsBytes()
                .then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });

  group('menu rules', () {
    test('offered only on owned, uploaded folders; reasons pass through', () {
      final rows = {for (final row in _library()) row['path'] as String: row};
      expect(manageSharingItem(rows['Family']!, null), (
        offered: true,
        disabledReason: null,
      ));
      expect(
        manageSharingItem(
          rows['Family']!,
          'Resume sync to manage sharing',
        ).disabledReason,
        'Resume sync to manage sharing',
      );
      expect(
        manageSharingItem(
          rows['Family']!,
          'This device can only view',
        ).disabledReason,
        'This device can only view',
      );
      expect(
        manageSharingItem(rows['Local only']!, null).disabledReason,
        'Upload this folder first',
      );
      for (final path in [
        'Family/notes.txt',
        'Shared',
        'Shared/Photos',
        'Shared/Pending',
        'Shared/Docs',
      ]) {
        expect(
          manageSharingItem(rows[path]!, null).offered,
          isFalse,
          reason: path,
        );
      }
      expect(
        manageSharingItem({..._row('Gone'), 'status': 'deleted'}, null).offered,
        isFalse,
      );
      expect(
        manageSharingItem({
          ..._row('Synthetic'),
          'synthetic': true,
        }, null).offered,
        isFalse,
      );
      expect(manageSharingItem(_row(''), null).offered, isFalse);
      // Spec #34 P4: not on Documents, Music, Videos themselves; inside them
      // and elsewhere as before. An existing share stays manageable.
      for (final path in ['Documents', 'Music', 'Videos']) {
        expect(manageSharingItem(_row(path), null).offered, isFalse);
        expect(
          manageSharingItem({..._row(path), 'sharedOut': true}, null).offered,
          isTrue,
          reason: path,
        );
      }
      for (final path in [
        'Documents/Taxes',
        'Music/Live',
        'Videos/x',
        'Docs',
      ]) {
        expect(manageSharingItem(_row(path), null).offered, isTrue);
      }
      expect(offersDeleteEverywhere(rows['Shared/Photos']!), isFalse);
      expect(offersDeleteEverywhere(rows['Shared/Photos/a.jpg']!), isFalse);
      expect(offersDeleteEverywhere(rows['Family']!), isTrue);
      // Review L2: a top folder under Shared/ before the incoming list loads.
      expect(offersDeleteEverywhere(rows['Shared/Pending']!), isFalse);
      expect(offersDeleteEverywhere(rows['Shared/Mine']!), isTrue);
      expect(
        offersDeleteEverywhere({..._row('Shared/X'), 'incomingMount': true}),
        isFalse,
      );
    });
  });

  group('modal', () {
    late FakeGateway gateway;
    Future<void> open(WidgetTester tester, {GlobalKey? boundary}) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showManageSharing(
                  context,
                  path: 'Family',
                  call: gateway.call,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        boundary == null ? app : RepaintBoundary(key: boundary, child: app),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    setUp(() => gateway = FakeGateway());

    testWidgets(
      'spec #34 P4: a private folder with an earlier share can only remove it',
      (tester) async {
        gateway = FakeGateway(
          shares: [
            {
              'share_id': '9',
              'path': 'Documents',
              'recipient_id': 'alice',
              'recipient_display_name': 'Alice',
              'permission': 'edit',
            },
          ],
        );
        tester.view.physicalSize = const Size(1000, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showManageSharing(
                  context,
                  path: 'Documents',
                  call: gateway.call,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('share-row:alice')), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const ValueKey('share-add')))
              .onPressed,
          isNull,
        );
        expect(
          find.byTooltip('Documents, Music and Videos are private'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('share-remove:alice')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'loads with progress, lists recipients of this folder only, Save disabled until a change',
      (tester) async {
        final semantics = tester.ensureSemantics();
        gateway.gate = Completer<void>();
        await open(tester);
        await tester.pump();
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .semanticsLabel,
          'Loading sharing',
        );
        gateway.gate!.complete();
        await tester.pumpAndSettle();
        semantics.dispose();
        expect(find.text('Manage sharing — Family'), findsOneWidget);
        expect(find.byKey(const ValueKey('share-row:alice')), findsOneWidget);
        expect(find.byKey(const ValueKey('share-row:bob')), findsOneWidget);
        expect(find.byKey(const ValueKey('share-row:carol')), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('share-save')))
              .onPressed,
          isNull,
        );
        expect(gateway.calls, ['load']);
      },
    );

    testWidgets(
      'add, raise to full access, remove: Save applies removals, then changes, then additions',
      (tester) async {
        await open(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-add-user:carol')));
        await tester.pumpAndSettle();
        // One access level (decision #155): no choice is offered.
        expect(
          find.byKey(const ValueKey('share-permission:carol')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('share-row:carol')),
            matching: find.text('Full access'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('share-row:bob')),
            matching: find.text('View only'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('share-upgrade:bob')));
        await tester.pumpAndSettle();
        expect(find.text('Full access on Save'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('share-remove:alice')));
        await tester.pumpAndSettle();
        expect(find.text('Removed on Save'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('share-save')));
        await tester.pumpAndSettle();
        expect(gateway.calls, [
          'load',
          'remove 1',
          'update 2 edit',
          'create carol edit',
        ]);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets(
      'a partial failure keeps the dialog open with per-row reasons and the unsaved intent',
      (tester) async {
        gateway.failing['create carol edit'] =
            'The server refused this sharing change';
        await open(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-add-user:carol')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-remove:bob')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('share-save')));
        await tester.pumpAndSettle();
        expect(gateway.calls, [
          'load',
          'remove 2',
          'create carol edit',
          'load',
        ]);
        expect(find.byType(AlertDialog), findsOneWidget);
        // Bob's removal applied (reloaded from the server); Carol's add failed and is kept.
        expect(find.byKey(const ValueKey('share-row:bob')), findsNothing);
        expect(find.byKey(const ValueKey('share-error:carol')), findsOneWidget);
        expect(
          find.text('The server refused this sharing change'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('share-row:carol')),
            matching: find.text('Full access'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('share-save')))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('Cancel and Escape discard without any request', (
      tester,
    ) async {
      await open(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-remove:alice')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('share-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-remove:bob')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(gateway.calls, ['load', 'load']);
    });

    testWidgets('load failure shows the reason and Retry', (tester) async {
      gateway.failLoad = 'Server did not respond.';
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('Server did not respond.'), findsOneWidget);
      gateway.failLoad = null;
      await tester.tap(find.byKey(const ValueKey('share-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-row:alice')), findsOneWidget);
    });

    testWidgets('nobody left to add: Add person is disabled with the reason', (
      tester,
    ) async {
      gateway = FakeGateway(
        users: [
          {'id': 'alice', 'display_name': 'Alice'},
        ],
      );
      await open(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('share-add')))
            .onPressed,
        isNull,
      );
      expect(
        find.byTooltip('Everyone in the household already has access'),
        findsOneWidget,
      );
      gateway = FakeGateway(users: [], shares: []);
      await tester.tap(find.byKey(const ValueKey('share-cancel')));
      await tester.pumpAndSettle();
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.byTooltip('No other household users yet'), findsOneWidget);
    });

    testWidgets('keyboard only: add a person and save', (tester) async {
      await open(tester);
      await tester.pumpAndSettle();
      Future<void> focusAndPress(Finder target) async {
        for (
          var i = 0;
          i < 20 && !Focus.of(tester.element(target)).hasFocus;
          i++
        ) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(Focus.of(tester.element(target)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      await focusAndPress(
        find
            .descendant(
              of: find.byKey(const ValueKey('share-add')),
              matching: find.byType(Text),
            )
            .first,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-row:carol')), findsOneWidget);
      await focusAndPress(
        find.descendant(
          of: find.byKey(const ValueKey('share-save')),
          matching: find.byType(Text),
        ),
      );
      expect(gateway.calls, ['load', 'create carol edit']);
    });

    testWidgets('evidence: harness render of the modal', (tester) async {
      final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
      final boundary = GlobalKey();
      gateway.failing['create carol edit'] =
          'The server refused this sharing change';
      await open(tester, boundary: boundary);
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        if (evidence == null) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(evidence).createSync(recursive: true);
          File('$evidence/$name.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('manage-sharing-loaded');
      await tester.tap(find.byKey(const ValueKey('share-add')));
      await tester.pumpAndSettle();
      await capture('manage-sharing-add-person');
      await tester.tap(find.byKey(const ValueKey('share-add-user:carol')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-remove:bob')));
      await tester.pump();
      await capture('manage-sharing-pending-changes');
      await tester.tap(find.byKey(const ValueKey('share-save')));
      await tester.pumpAndSettle();
      await capture('manage-sharing-partial-failure');
      expect(find.byKey(const ValueKey('share-error:carol')), findsOneWidget);
    });
  });

  group('library', () {
    late Directory profile;
    late _Controller controller;
    setUp(() {
      profile = Directory.systemTemp.createTempSync('anj-sharing-ui-');
      controller = _Controller(profile)
        ..root = '/synthetic/files'
        ..entries = _library();
    });
    tearDown(() {
      controller.dispose();
      profile.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester, {GlobalKey? boundary}) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = CloudApp(controller: controller);
      await tester.pumpWidget(
        boundary == null ? app : RepaintBoundary(key: boundary, child: app),
      );
      await tester.pumpAndSettle();
      // Folders start collapsed on the home tab.
      for (final folder in ['Family', 'Shared', 'Shared/Photos']) {
        final toggle = find.byKey(ValueKey('toggle:$folder'));
        if (tester.widget<IconButton>(toggle).tooltip!.startsWith('Expand')) {
          await tester.tap(toggle);
          await tester.pumpAndSettle();
        }
      }
    }

    Finder menuOf(String path) => find.descendant(
      of: find.byKey(ValueKey('row:$path')),
      matching: find.byType(PopupMenuButton<String>),
    );
    Future<void> openMenu(WidgetTester tester, String path) async {
      await tester.ensureVisible(menuOf(path));
      await tester.tap(menuOf(path));
      await tester.pumpAndSettle();
    }

    Future<void> closeMenu(WidgetTester tester) async {
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Manage sharing appears only on owned folders and opens the modal',
      (tester) async {
        await pump(tester);
        for (final row in controller.entries) {
          final path = row['path'] as String;
          await openMenu(tester, path);
          expect(
            find.byKey(ValueKey('manage-sharing:$path')),
            const {'Family', 'Local only'}.contains(path)
                ? findsOneWidget
                : findsNothing,
            reason: path,
          );
          expect(
            find.text('Delete everywhere'),
            const {
                  'Shared/Photos',
                  'Shared/Photos/a.jpg',
                  'Shared/Pending',
                  'Shared/Docs',
                }.contains(path)
                ? findsNothing
                : findsOneWidget,
            reason: path,
          );
          await closeMenu(tester);
        }
        await openMenu(tester, 'Local only');
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.byKey(const ValueKey('manage-sharing:Local only')),
              )
              .enabled,
          isFalse,
        );
        expect(find.byTooltip('Upload this folder first'), findsOneWidget);
        await closeMenu(tester);
        await openMenu(tester, 'Family');
        await tester.tap(find.byKey(const ValueKey('manage-sharing:Family')));
        await tester.pumpAndSettle();
        expect(find.text('Manage sharing — Family'), findsOneWidget);
      },
    );

    testWidgets(
      'disabled with its reason while paused or on a read-grant device',
      (tester) async {
        final semantics = tester.ensureSemantics();
        for (final reason in [
          'Resume sync to manage sharing',
          'This device can only view',
        ]) {
          controller.unavailable = reason;
          await pump(tester);
          await openMenu(tester, 'Family');
          expect(
            tester
                .widget<PopupMenuItem<String>>(
                  find.byKey(const ValueKey('manage-sharing:Family')),
                )
                .enabled,
            isFalse,
          );
          expect(find.byTooltip(reason), findsOneWidget);
          expect(
            find.bySemanticsLabel(
              RegExp('Manage sharing… unavailable: ${RegExp.escape(reason)}'),
            ),
            findsOneWidget,
          );
          await closeMenu(tester);
        }
        expect(controller.gateway.calls, isEmpty);
        semantics.dispose();
      },
    );

    testWidgets('Shared badge on shared-out folders with the names; Shared by, View only; '
        'no badge means private; status badges unchanged', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      expect(find.byKey(const ValueKey('shared-badge:Family')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('shared-badge:Family')),
          matching: find.text('Shared'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Shared with Alice, Bob'), findsOneWidget);
      for (final path in ['Local only', 'Family/notes.txt']) {
        expect(find.byKey(ValueKey('shared-badge:$path')), findsNothing);
        expect(find.byKey(ValueKey('shared-icon:$path')), findsNothing);
      }
      expect(find.byKey(const ValueKey('shared-icon:Family')), findsNothing);
      final node = tester
          .getSemantics(find.byKey(const ValueKey('shared-badge:Family')))
          .getSemanticsData();
      expect(
        '${node.label} ${node.tooltip}',
        contains('Shared with Alice, Bob'),
      );
      expect(find.text('Shared by Alice · View only'), findsOneWidget);
      expect(find.text('Shared by Bob'), findsOneWidget);
      expect(find.text("The owner's account is disabled"), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shared-icon:Shared/Photos')),
        findsOneWidget,
      );
      // The status badge is separate: shared rows keep their ordinary one.
      for (final path in ['Family', 'Shared/Photos']) {
        final chip = tester.widget<Chip>(find.byKey(ValueKey('badge:$path')));
        expect((chip.label as Text).data, 'Local', reason: path);
      }
      final icon = tester.widget<Icon>(
        find.byKey(const ValueKey('shared-icon:Shared/Photos')),
      );
      final context = tester.element(
        find.byKey(const ValueKey('shared-icon:Shared/Photos')),
      );
      expect(icon.color, Theme.of(context).colorScheme.onSurfaceVariant);
      semantics.dispose();
    });

    testWidgets('spec #34 P4: Documents, Music and Videos are private (no '
        'badge, no Manage sharing); a shared folder inside one is badged', (
      tester,
    ) async {
      controller.entries = [
        _row('Documents'),
        _row(
          'Documents/Taxes',
          extra: {
            'sharedOut': true,
            'sharedWith': ['Alex'],
          },
        ),
        _row('Music'),
        _row('Videos'),
      ];
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle:Documents')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('shared-badge:Documents/Taxes')),
        findsOneWidget,
      );
      expect(find.byTooltip('Shared with Alex'), findsOneWidget);
      for (final path in ['Documents', 'Music', 'Videos']) {
        expect(find.byKey(ValueKey('shared-badge:$path')), findsNothing);
        await openMenu(tester, path);
        expect(find.byKey(ValueKey('manage-sharing:$path')), findsNothing);
        await closeMenu(tester);
      }
      await openMenu(tester, 'Documents/Taxes');
      expect(
        find.byKey(const ValueKey('manage-sharing:Documents/Taxes')),
        findsOneWidget,
      );
      await closeMenu(tester);
    });

    testWidgets('spec #34 P6: a share placed in the recipient\'s Documents '
        'shows Shared by the owner and offers neither sharing nor Delete '
        'everywhere, inside it neither', (tester) async {
      final semantics = tester.ensureSemantics();
      controller.entries = [
        _row('Documents'),
        _row(
          'Documents/Taxes',
          extra: {
            'incomingShare': {
              'share_id': '7',
              'path': 'Documents/Taxes',
              'owner_display_name': 'Sam',
              'permission': 'edit',
              'owner_unavailable': false,
            },
            'incomingMount': true,
            'inIncomingShare': true,
            // The listing marks a mount like a share: never the owner badge.
            'sharedOut': true,
          },
        ),
        _row(
          'Documents/Taxes/2025',
          extra: {'inIncomingShare': true, 'sharedOut': true},
        ),
        _row('Documents/Own'),
      ];
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle:Documents')));
      await tester.pumpAndSettle();
      expect(find.text('Shared by Sam'), findsOneWidget);
      expect(find.byTooltip('Shared by Sam'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shared-icon:Documents/Taxes')),
        findsOneWidget,
      );
      for (final path in ['Documents/Taxes', 'Documents/Taxes/2025']) {
        expect(find.byKey(ValueKey('shared-badge:$path')), findsNothing);
      }
      final rows = {
        for (final row in controller.entries) row['path'] as String: row,
      };
      for (final path in ['Documents/Taxes', 'Documents/Taxes/2025']) {
        expect(manageSharingItem(rows[path]!, null).offered, isFalse);
      }
      expect(manageSharingItem(rows['Documents/Own']!, null).offered, isTrue);
      expect(offersDeleteEverywhere(rows['Documents/Taxes']!), isFalse);
      expect(offersDeleteEverywhere(rows['Documents/Own']!), isTrue);
      await openMenu(tester, 'Documents/Taxes');
      expect(
        find.byKey(const ValueKey('manage-sharing:Documents/Taxes')),
        findsNothing,
      );
      expect(find.text('Delete everywhere'), findsNothing);
      await closeMenu(tester);
      semantics.dispose();
    });

    testWidgets('evidence: library rows and the folder menu', (tester) async {
      final evidence = Platform.environment['ANJ_UI_EVIDENCE_DIR'];
      final boundary = GlobalKey();
      await pump(tester, boundary: boundary);
      Future<void> capture(String name) async {
        if (evidence == null) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(evidence).createSync(recursive: true);
          File('$evidence/$name.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('library-shared-rows');
      await openMenu(tester, 'Family');
      await capture('folder-menu-manage-sharing');
      expect(
        find.byKey(const ValueKey('manage-sharing:Family')),
        findsOneWidget,
      );
    });
  });
}
