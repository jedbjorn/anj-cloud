// Spec #43 A1, A4-A6 in the UI: the folder ⋮ menu's Add files… and Add
// folder… (AC6: disabled with the reason; AC10: absent without the
// platform's picker), the confirmation before copying, progress and the
// summary, one add at a time, and Save to AnJ Cloud for shares.
import 'dart:async';
import 'dart:io';

import 'package:anj_cloud/core/app/add_files.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/sync/file_adder.dart';
import 'package:anj_cloud/ui/add_files_flow.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

class _Controller extends ClientController {
  _Controller()
    : super(Directory('/unused-add-files'), secrets: MemorySecrets());
  bool ready = true;
  @override
  bool get canCreateFolder => ready;
  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) {}
}

class _Port implements AddFilesPort {
  List<AddSource>? picked;
  String? folder;
  List<AddSource>? listing;
  final unreadable = <String>{};
  int? free = 1 << 40;
  SharedItems? share;
  int left = 0;
  final arrived = StreamController<void>.broadcast();
  Completer<void>? gate;

  @override
  Future<List<AddSource>?> pickFiles() async => picked;
  @override
  Future<String?> pickFolder() async => folder;
  @override
  Future<List<AddSource>?> listFolder() async => listing;
  @override
  void cancelListing() {}
  @override
  Future<String> open(AddSource source, {required int limit}) async {
    await gate?.future;
    if (unreadable.contains(source.path)) {
      throw const AddSourceFailure('unreadable');
    }
    return '/phone/${source.path}';
  }

  @override
  void cancelOpen() {}
  @override
  Future<void> release(String path) async {}
  @override
  Future<int?> freeBytes(String path) async => free;
  @override
  Future<SharedItems?> takeShare() async {
    final taken = share;
    share = null;
    return taken;
  }

  @override
  Stream<void> get shareArrived => arrived.stream;
  @override
  Future<void> leaveShare() async => left++;
}

/// The worker's add commands over a set of existing names.
class _Worker {
  _Worker([Set<String>? existing]) : existing = existing ?? {};
  final Set<String> existing;
  final calls = <String>[];
  int limit = 64 << 20;

  Future<Map<String, Object?>> call(
    String op,
    Map<String, Object?> args,
  ) async {
    calls.add('$op ${args['name'] ?? args['destination'] ?? ''}'.trim());
    switch (op) {
      case 'addCheck':
        final destination = args['destination'] as String;
        return FileAdder.plan(
          (args['items'] as List).cast<Map>(),
          siblings: {
            for (final path in existing)
              if (p.posix.dirname(path) == destination) p.posix.basename(path),
          },
          limit: limit,
          free: args['free'] as int?,
        );
      case 'addFolder':
      case 'addFile':
        final parent = args['parent'] as String;
        final name = args['number'] == true
            ? FileAdder.freeName(args['name'] as String, {
                for (final path in existing)
                  if (p.posix.dirname(path) == parent) p.posix.basename(path),
              }, directory: op == 'addFolder')
            : args['name'] as String;
        final path = '$parent/$name';
        existing.add(path);
        return {'path': path};
    }
    return const {};
  }
}

Map<String, dynamic> _folder(
  String path, {
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': 'directory',
  'effectiveRetention': 'local',
  'status': 'current local',
  'localDirectoryAvailable': true,
  ...extra,
};

List<Map<String, dynamic>> _library() => [
  _folder('Documents'),
  _folder('Documents/Receipts'),
  // Cloud only and not on this device.
  _folder(
    'Archive',
    extra: {'localDirectoryAvailable': false, 'effectiveRetention': 'cloud'},
  ),
  _folder('Shared'),
  _folder('Shared/Photos', extra: {'viewOnly': true, 'inIncomingShare': true}),
  _folder('Shared/Team', extra: {'inIncomingShare': true}),
  // Top-level rows (the library starts with folders collapsed).
  _folder('Projects'),
  _folder('Photos', extra: {'viewOnly': true, 'inIncomingShare': true}),
  {
    'path': 'Documents/a.txt',
    'kind': 'file',
    'effectiveRetention': 'local',
    'status': 'current local',
  },
];

Finder _menuOf(String path) => find.descendant(
  of: find.byKey(ValueKey('row:$path')),
  matching: find.byTooltip('Folder actions'),
);

Future<void> _openMenu(WidgetTester tester, String path) async {
  await tester.ensureVisible(_menuOf(path));
  await tester.tap(_menuOf(path));
  await tester.pumpAndSettle();
}

PopupMenuItem<String> _item(WidgetTester tester, String key) =>
    tester.widget<PopupMenuItem<String>>(find.byKey(ValueKey(key)));

void main() {
  late _Controller controller;
  late _Port port;
  late _Worker worker;
  late AddFiles adds;

  setUp(() {
    controller = _Controller()
      ..root = '/synthetic/anj-cloud'
      ..pairingState = 'paired'
      ..stateReceived = true
      ..entries = _library();
    port = _Port();
    worker = _Worker({'Documents/a.txt'});
    adds = AddFiles(
      port,
      command: worker.call,
      cancelWorker: (_) {},
      root: () => controller.root,
    );
  });

  Future<void> pumpApp(WidgetTester tester, {bool withAdds = true}) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CloudApp(controller: controller, addFiles: withAdds ? adds : null),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  group('AC6: eligible destinations', () {
    test('the reasons', () {
      final rows = {for (final row in _library()) row['path'] as String: row};
      String? problem(String path, {bool paused = false, bool ready = true}) =>
          addDestinationProblem(rows[path]!, ready: ready, paused: paused);
      expect(problem('Documents'), isNull);
      expect(problem('Shared/Team'), isNull);
      expect(problem('Archive'), 'Not available on this device');
      expect(problem('Shared/Photos'), 'View-only share');
      expect(problem('Documents', paused: true), 'Sync is paused');
      expect(
        problem('Documents', ready: false),
        'Not available on this device',
      );
      expect(
        addDestinationProblem(
          {...rows['Documents']!, 'conflict': 'x'},
          ready: true,
          paused: false,
        ),
        'Not available on this device',
      );
      expect(addOffered(rows['Documents/a.txt']!), isFalse);
      expect(addOffered({...rows['Documents']!, 'synthetic': true}), isFalse);
    });

    testWidgets('entries are disabled with the reason in the folder menu', (
      tester,
    ) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Documents');
      expect(_item(tester, 'addFiles:Documents').enabled, isTrue);
      expect(_item(tester, 'addFolder:Documents').enabled, isTrue);
      expect(find.text('Add files…'), findsOneWidget);
      expect(find.text('Add folder…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      for (final (path, reason) in [
        ('Photos', 'View-only share'),
        ('Archive', 'Not available on this device'),
      ]) {
        await _openMenu(tester, path);
        expect(_item(tester, 'addFiles:$path').enabled, isFalse, reason: path);
        expect(_item(tester, 'addFolder:$path').enabled, isFalse, reason: path);
        expect(find.byKey(ValueKey('addFiles-reason:$path')), findsOneWidget);
        expect(find.text(reason), findsNWidgets(2), reason: path);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }

      controller.paused = true;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      await _openMenu(tester, 'Documents');
      expect(_item(tester, 'addFiles:Documents').enabled, isFalse);
      expect(find.text('Sync is paused'), findsNWidgets(2));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await close(tester);
    });

    testWidgets('the Share screen lists only eligible folders', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SaveToCloudScreen(
            adds: adds,
            controller: controller,
            share: const SharedItems([
              AddSource(path: 'p.jpg', size: 3, reference: 'p'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final path in [
        'Documents',
        'Documents/Receipts',
        'Shared',
        'Shared/Team',
      ]) {
        expect(
          find.byKey(ValueKey('share-folder:$path')),
          findsOneWidget,
          reason: path,
        );
      }
      for (final path in [
        'Archive',
        'Shared/Photos',
        'Photos',
        'Documents/a.txt',
      ]) {
        expect(
          find.byKey(ValueKey('share-folder:$path')),
          findsNothing,
          reason: path,
        );
      }
      controller.paused = true;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('share-folder:Documents')),
        findsNothing,
      );
      expect(find.textContaining('Sync is paused'), findsOneWidget);
      await close(tester);
    });
  });

  testWidgets('AC10: without the platform picker the entries are absent', (
    tester,
  ) async {
    await pumpApp(tester, withAdds: false);
    await _openMenu(tester, 'Documents');
    expect(find.text('Add files…'), findsNothing);
    expect(find.text('Add folder…'), findsNothing);
    expect(find.text('Local and cloud'), findsNothing); // a top folder's menu
    expect(
      find.text('Keep new and loose files on this device'),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('Add files: confirmation lists skips, then the summary shows '
      'added, renamed and skipped', (tester) async {
    port.picked = const [
      AddSource(path: 'a.txt', size: 10, reference: 'a'),
      AddSource(path: 'b.txt', size: 20, reference: 'b'),
      AddSource(path: 'movie.mp4', size: 100 << 20, reference: 'm'),
      AddSource(path: 'CON.txt', size: 1, reference: 'c'),
    ];
    await pumpApp(tester);
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFiles:Documents')));
    await tester.pumpAndSettle();
    expect(find.text('Add to Documents'), findsOneWidget);
    expect(find.textContaining('2 files'), findsOneWidget);
    expect(
      find.text('movie.mp4 — Larger than the 64 MB upload limit'),
      findsOneWidget,
    );
    expect(
      find.text('CON.txt — Name not allowed on other devices'),
      findsOneWidget,
    );
    expect(worker.calls.where((c) => c.startsWith('addFile')), isEmpty);
    await tester.tap(find.byKey(const ValueKey('add-confirm')));
    await tester.pumpAndSettle();
    expect(
      worker.calls,
      containsAllInOrder(['addFile a.txt', 'addFile b.txt']),
    );
    expect(find.text('Added 2 files to Documents'), findsOneWidget);
    expect(find.text('a.txt — Added as a (2).txt'), findsOneWidget);
    expect(
      find.text('movie.mp4 — Larger than the 64 MB upload limit'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('add-result-close')));
    await tester.pumpAndSettle();
    expect(adds.busy, isFalse);
    await close(tester);
  });

  testWidgets(
    'a clean add is a snackbar; Cancel at the confirmation writes nothing',
    (tester) async {
      port.picked = const [AddSource(path: 'n.txt', size: 1, reference: 'n')];
      await pumpApp(tester);
      await _openMenu(tester, 'Projects');
      await tester.tap(find.byKey(const ValueKey('addFiles:Projects')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-cancel')));
      await tester.pumpAndSettle();
      expect(worker.calls.where((c) => c.startsWith('addFile')), isEmpty);
      await _openMenu(tester, 'Projects');
      await tester.tap(find.byKey(const ValueKey('addFiles:Projects')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Added 1 file to Projects'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await close(tester);
    },
  );

  testWidgets('Add folder walks the tree and reports the folder', (
    tester,
  ) async {
    port
      ..folder = 'Trip'
      ..listing = const [
        AddSource(path: 'Trip', directory: true),
        AddSource(path: 'Trip/Empty', directory: true),
        AddSource(path: 'Trip/Day', directory: true),
        AddSource(path: 'Trip/Day/x.jpg', size: 5, reference: 'x'),
      ];
    await pumpApp(tester);
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFolder:Documents')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 folders and 1 file'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-confirm')));
    await tester.pumpAndSettle();
    expect(
      worker.existing,
      containsAll([
        'Documents/Trip',
        'Documents/Trip/Empty',
        'Documents/Trip/Day/x.jpg',
      ]),
    );
    expect(
      find.text('Added 3 folders and 1 file to Documents'),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('nothing to add, and not enough space, offer only Close', (
    tester,
  ) async {
    port.picked = const [AddSource(path: '.DS_Store', size: 1, reference: 'd')];
    await pumpApp(tester);
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFiles:Documents')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-nothing')), findsOneWidget);
    expect(
      find.text('.DS_Store — Not synchronized by AnJ Cloud'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('add-confirm')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-close')));
    await tester.pumpAndSettle();

    port
      ..picked = const [
        AddSource(path: 'big.bin', size: 60 << 20, reference: 'b'),
      ]
      ..free = addFreeSpaceReserve + (10 << 20);
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFiles:Documents')));
    await tester.pumpAndSettle();
    expect(find.text('Not enough space on this phone'), findsOneWidget);
    expect(
      find.textContaining(
        'Adding needs 60 MB. 266 MB is free, and 256 MB is kept free',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('add-confirm')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-close')));
    await tester.pumpAndSettle();
    expect(worker.calls.where((c) => c.startsWith('addFile')), isEmpty);
    await close(tester);
  });

  testWidgets('one add at a time; progress shows while copying', (
    tester,
  ) async {
    port
      ..picked = const [
        AddSource(path: 'one.txt', size: 1, reference: '1'),
        AddSource(path: 'bad.txt', size: 1, reference: '2'),
      ]
      ..unreadable.add('bad.txt')
      ..gate = Completer<void>();
    await pumpApp(tester);
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFiles:Documents')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-confirm')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Adding 1 of 2 to Documents'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-progress-cancel')), findsOneWidget);
    expect(adds.begin(), isFalse);
    port.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('bad.txt — Could not read this file'), findsOneWidget);
    expect(find.text('Added 1 file to Documents'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-result-close')));
    await tester.pumpAndSettle();

    expect(adds.begin(), isTrue); // someone else's add
    await _openMenu(tester, 'Documents');
    await tester.tap(find.byKey(const ValueKey('addFiles:Documents')));
    await tester.pumpAndSettle();
    expect(find.text('Another add is in progress'), findsOneWidget);
    adds.end();
    await close(tester);
  });

  group('Save to AnJ Cloud', () {
    testWidgets(
      'a share opens the screen on top; Save copies; leaving returns to the sharing app',
      (tester) async {
        await pumpApp(tester);
        port.share = const SharedItems([
          AddSource(path: 'photo.jpg', size: 3, reference: 'p'),
          AddSource(path: 'clip.mp4', size: 4, reference: 'v'),
        ]);
        port.arrived.add(null);
        await tester.pumpAndSettle();
        expect(find.text('Save to AnJ Cloud'), findsOneWidget);
        expect(find.text('Choose a folder for 2 files.'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('share-save')))
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('share-folder:Documents/Receipts')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('share-save')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('add-confirm')));
        await tester.pumpAndSettle();
        expect(
          worker.existing,
          containsAll([
            'Documents/Receipts/photo.jpg',
            'Documents/Receipts/clip.mp4',
          ]),
        );
        expect(find.text('Save to AnJ Cloud'), findsNothing);
        // The library is still there underneath.
        expect(find.byKey(const ValueKey('row:Documents')), findsOneWidget);
        expect(port.left, 1);
        await close(tester);
      },
    );

    testWidgets('text only, unpaired: a clear message and nothing copied', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SaveToCloudScreen(
            adds: adds,
            controller: controller,
            share: const SharedItems([]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Only files can be added to AnJ Cloud.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('share-save')), findsNothing);
      controller.pairingState = 'unpaired';
      await tester.pumpWidget(
        MaterialApp(
          home: SaveToCloudScreen(
            adds: adds,
            controller: controller,
            share: const SharedItems([AddSource(path: 'x', reference: 'x')]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Pair this phone with AnJ Cloud first.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('share-save')), findsNothing);
      expect(worker.calls, isEmpty);
      await close(tester);
    });
  });
}
