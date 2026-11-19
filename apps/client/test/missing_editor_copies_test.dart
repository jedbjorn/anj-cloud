import 'dart:io';
import 'dart:isolate';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/open_documents.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/mapped_root_fs.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/library_entry_card.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';
import 'test_platform.dart';

const _path = 'Music/example.mp3';
const _original = 'anonymous synchronized original';

String _digest(File file) => sha256.convert(file.readAsBytesSync()).toString();

Future<FakeCloud> _cloud() async {
  final cloud = FakeCloud();
  for (final top in phoneFolderNames.keys) {
    await cloud.mkdir(top);
  }
  cloud.put(_path, _original);
  return cloud;
}

/// The real controller starts a real WorkerLoop isolate. Only the gateway
/// transport and the shared storage volume are fixtures.
Future<void> _worker(Map<String, Object?> initial) async {
  final output = initial['output'] as SendPort;
  final input = ReceivePort();
  final profile = Directory(initial['profile'] as String);
  final store = Manifest(profile);
  final routing = MappedRootFs(
    PhoneFolderLayout.fromJson(initial['phoneFolders'])!,
    initial['nativeLibrary'] as String?,
  );
  final tree = RootTree(
    Directory(store.setting('root')!),
    Directory(store.setting('staging')!),
    routing,
  );
  final cloud = await _cloud();
  final initialVersion = cloud.counter;
  final engine = SyncEngine(store, tree, cloud);
  output.send({'event': 'ready', 'input': input.sendPort});
  try {
    await WorkerLoop(engine, (event) {
      if ((event as Map)['event'] == 'stopped') {
        File('${profile.path}/cloud-mutations').writeAsStringSync(
          '${cloud.counter - initialVersion},${cloud.uploadAttempts},${cloud.deletes}',
        );
      }
      output.send(event);
    }, interval: const Duration(hours: 1)).run(input);
  } finally {
    input.close();
    routing.setPaused(true);
  }
}

class _Access implements PhoneFolderAccess {
  _Access(this.base);
  final String base;
  bool granted = true;
  String get staging => '$base/Android/media/cloud.anj.fixture/anj-staging';
  PhoneFolderLayout get layout =>
      PhoneFolderLayout(base: base, staging: staging, paused: !granted);

  @override
  Future<PhoneFolderLayout> check() async => layout;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> scan(List<String> paths) async {}
}

class _Fixture {
  final dir = Directory.systemTemp.createTempSync('anj-missing-editor-');
  late final access = _Access('${dir.path}/shared');
  late final profile = Directory('${dir.path}/profile');
  late final original = File('${access.base}/$_path');
  late final parkedCopy = File('${dir.path}/parked-editor-copy');
  late final controller = ClientController(
    profile,
    secrets: MemorySecrets(),
    nativeLibrary: testNativeLibrary,
    workerEntry: _worker,
    phoneFolders: access,
  );
  final absent = <(String id, String owner, File file)>[];
  (String id, String owner, File file)? present;
  String editorResult = '';

  Future<void> seed({
    bool mixed = false,
    bool paused = false,
    bool parkFirstCopy = false,
    bool legacy = false,
  }) async {
    final root = Directory('${dir.path}/root')..createSync();
    final staging = Directory('${dir.path}/private-stage');
    for (final folder in phoneFolderNames.values) {
      Directory('${access.base}/$folder').createSync(recursive: true);
    }
    original.writeAsStringSync(_original);
    final store = Manifest(profile)
      ..setSetting('root', root.path)
      ..setSetting('staging', staging.path)
      ..setSetting('accountUid', 'anonymous-fixture')
      ..setSetting('accountOrigin', 'https://fixture.invalid');
    final routing = MappedRootFs(access.layout, testNativeLibrary);
    final engine = SyncEngine(
      store,
      RootTree(root, staging, routing),
      await _cloud(),
    );
    try {
      await engine.tick();
      store.entries[_path]!.override = Retention.local;
      Future<(String, String, File)> handOut() async {
        final staged = await engine.openFile(_path, providerTracked: true);
        final name = p.basename(staged);
        final work = store
            .operationsAt(_path)
            .singleWhere((op) => op.kind == 'working' && op.staged == staged);
        final artifact = store
            .operationsAt(_path)
            .singleWhere((op) => op.kind == 'artifact' && op.staged == staged);
        if (legacy) {
          // Build 177 recorded the private directory for shared copies and
          // kept provider hand-outs in memory.
          artifact.data.remove('sharedDirectoryIdentity');
          work.data.remove(providerOpenTokensKey);
        }
        return (work.id, artifact.id, File('${access.staging}/$name'));
      }

      absent.add(await handOut());
      // Move the first copy out of staging so Open makes a second copy.
      // Keeping the first inode alive ensures their identities differ.
      absent.first.$3.renameSync(parkedCopy.path);
      absent.add(await handOut());
      absent.last.$3.deleteSync();
      if (!parkFirstCopy) parkedCopy.deleteSync();
      await engine.tick();
      expect(
        store.operationsAt(_path).where((op) => op.kind == 'working'),
        hasLength(2),
      );
      if (mixed) {
        present = await handOut();
        present!.$3.writeAsStringSync('unsynced editor changes');
        final unrelated = File('${access.base}/Documents/pending.txt')
          ..writeAsStringSync('unrelated pending content');
        store.entries['Documents/pending.txt'] = Entry(
          'Documents/pending.txt',
          ItemKind.file,
        )..expectedPresent = true;
        store.operations['unrelated-upload'] = Operation(
          'unrelated-upload',
          'upload',
          'Documents/pending.txt',
          hash: _digest(unrelated),
        );
      }
      if (paused || mixed) store.setSetting('paused', '1');
      if (legacy) {
        store.entries[_path]!.status =
            'Working copy missing; root/cloud retained';
      }
      store.save();
    } finally {
      engine.close();
      routing.setPaused(true);
    }
  }

  Map<String, dynamic> get row =>
      controller.entries.singleWhere((row) => row['path'] == _path);

  Future<void> start() async {
    controller.addListener(() {
      editorResult = controller.editorCopyNotice ?? editorResult;
    });
    await controller.initialize();
    await until(() => controller.entries.any((row) => row['path'] == _path));
    final pass = await controller.backgroundRun(
      timeout: const Duration(seconds: 5),
    );
    expect(pass['timedOut'], isNot(true));
  }

  static Future<void> until(bool Function() ready) async {
    final time = Stopwatch()..start();
    while (!ready() && time.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue, reason: 'Timed out waiting for worker state');
  }

  void read(void Function(Manifest) inspect) {
    final stored = Manifest(profile);
    try {
      inspect(stored);
    } finally {
      stored.close();
    }
  }

  Future<void> close() async {
    await controller.stop();
    controller.dispose();
    dir.deleteSync(recursive: true);
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 1000);
  addTearDown(tester.view.reset);
  await tester.runAsync(fixture.start);
  await tester.pumpWidget(
    CloudApp(controller: fixture.controller, touchInput: true),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Expand Music'));
  await tester.pumpAndSettle();
}

Future<void> _openClear(WidgetTester tester) async {
  await tester.tap(
    find.widgetWithText(TextButton, 'Clear missing editor copies'),
  );
  await tester.pumpAndSettle();
}

Future<void> _confirmClear(WidgetTester tester) async {
  await tester.tap(find.text('Clear copies'));
  await tester.pumpAndSettle();
}

Future<void> _openDismiss(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Dismiss warning'));
  await tester.pumpAndSettle();
}

Future<void> _confirmDismiss(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('row:$_path')),
      matching: find.byTooltip('File actions'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Details and preserved copies'));
  await tester.pumpAndSettle();
}

bool _attention(WidgetTester tester, String path) => tester
    .widget<LibraryEntryCard>(find.byKey(ValueKey('row:$path')))
    .row
    .attention;

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  testWidgets('verified sessions: cancel, clear, restart and replay', (
    tester,
  ) async {
    await tester.runAsync(fixture.seed);
    final before = _digest(fixture.original);
    await _mount(tester, fixture);
    final claims = missingEditorClaims(fixture.row);
    expect(claims, hasLength(2));
    expect(find.text('Finish editing'), findsNothing);
    expect(_attention(tester, 'Music'), isTrue);
    expect(_attention(tester, _path), isTrue);

    await _openClear(tester);
    expect(
      find.textContaining('2 missing editor copies for $_path'),
      findsOneWidget,
    );
    expect(
      find.textContaining('cannot recover the missing temporary bytes'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Your synced file stays in place.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    fixture.read((store) {
      for (final (id, owner, _) in fixture.absent) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
      }
    });

    await _openClear(tester);
    await _confirmClear(tester);
    await tester.runAsync(
      () =>
          _Fixture.until(() => (fixture.row['workingCopies'] as List).isEmpty),
    );
    await tester.pumpAndSettle();
    expect(_attention(tester, 'Music'), isFalse);
    expect(_attention(tester, _path), isFalse);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('badge:$_path')),
        matching: find.text('Local'),
      ),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await fixture.controller.stop();
      expect(
        File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
        '0,0,0',
      );
      fixture.read((store) {
        final row = store.entries[_path]!;
        expect(row.workingCopy, isNull);
        expect(row.override, Retention.local);
        expect(row.expectedPresent, isTrue);
        for (final (id, owner, _) in fixture.absent) {
          expect(store.operations[id], isNull);
          expect(store.operations[owner], isNull);
        }
      });
      await fixture.controller.start();
      final pass = await fixture.controller.backgroundRun(
        timeout: const Duration(seconds: 5),
      );
      expect(pass['timedOut'], isNot(true));
      fixture.controller.command(
        'clearMissingEditorCopies',
        _path,
        sessions: claims,
      );
      await _Fixture.until(
        () => fixture.editorResult.contains('already cleared'),
      );
    });
    await tester.pumpAndSettle();
    expect(_digest(fixture.original), before);
    expect(fixture.row['effectiveRetention'], 'local');
    expect(_attention(tester, 'Music'), isFalse);
  });

  testWidgets('build 177 warnings dismiss and undo in Details after restart', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(legacy: true));
    final before = _digest(fixture.original);
    await _mount(tester, fixture);
    final claims = editorWarningClaims(fixture.row);
    expect(claims, hasLength(2));
    expect(missingEditorClaims(fixture.row), isEmpty);
    expect(find.text('Finish editing'), findsNothing);
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
    final originalRecords = <String, Map<String, Object?>>{};
    fixture.read((store) {
      for (final (id, owner, _) in fixture.absent) {
        originalRecords[id] = store.operations[id]!.toJson();
        originalRecords[owner] = store.operations[owner]!.toJson();
      }
    });

    await _openDismiss(tester);
    expect(
      find.textContaining('2 missing editor copy warnings for $_path'),
      findsOneWidget,
    );
    expect(find.textContaining('Details and preserved copies'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(editorWarningClaims(fixture.row), claims);
    expect(_attention(tester, 'Music'), isTrue);
    fixture.read((store) {
      for (final entry in originalRecords.entries) {
        expect(store.operations[entry.key]!.toJson(), entry.value);
      }
    });

    await _openDismiss(tester);
    await _confirmDismiss(tester);
    await tester.runAsync(() async {
      await _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).length == 2,
      );
      await fixture.controller.stop();
      expect(
        File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
        '0,0,0',
      );
      await fixture.controller.start();
      await fixture.controller.backgroundRun(
        timeout: const Duration(seconds: 5),
      );
      await _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).length == 2,
      );
    });
    await tester.pumpAndSettle();
    expect(_attention(tester, _path), isFalse);
    expect(_attention(tester, 'Music'), isFalse);
    expect(fileBadge(fixture.row), 'Local');
    expect(_digest(fixture.original), before);
    fixture.read((store) {
      final row = store.entries[_path]!;
      expect(row.override, Retention.local);
      expect(row.workingCopy, isNotNull);
      for (final (id, owner, _) in fixture.absent) {
        final current = store.operations[id]!.toJson();
        final original = originalRecords[id]!;
        expect(
          (current['data'] as Map)..remove('missingEditorNotice'),
          (original['data'] as Map)..remove('missingEditorNotice'),
        );
        expect(store.operations[owner]!.toJson(), originalRecords[owner]);
      }
    });

    await _openDetails(tester);
    expect(
      find.textContaining('Warning dismissed', findRichText: true),
      findsOneWidget,
    );
    for (final (_, _, file) in fixture.absent) {
      expect(
        find.textContaining(p.basename(file.path), findRichText: true),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await _Fixture.until(() => editorWarningClaims(fixture.row).length == 2);
      fixture.controller.command(
        'dismissEditorWarnings',
        _path,
        sessions: claims,
      );
      await _Fixture.until(
        () => fixture.editorResult.contains('editor warning changed'),
      );
    });
    await tester.pumpAndSettle();
    expect(editorWarningClaims(fixture.row), hasLength(2));
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
  });

  testWidgets(
    'dismiss rechecks a returning legacy copy after confirmation opens',
    (tester) async {
      await tester.runAsync(
        () => fixture.seed(legacy: true, paused: true, parkFirstCopy: true),
      );
      await _mount(tester, fixture);
      final (id, owner, file) = fixture.absent.first;
      await _openDismiss(tester);
      fixture.parkedCopy.renameSync(file.path);
      file.writeAsStringSync('returned editor changes');
      await _confirmDismiss(tester);
      await tester.runAsync(
        () => _Fixture.until(
          () => fixture.editorResult.contains('The editor copy is present.'),
        ),
      );
      expect(fixture.editorResult, contains('Dismissed 1 editor warning.'));
      await tester.pumpAndSettle();
      expect(find.text('Finish editing'), findsOneWidget);
      expect(
        editorWarningClaims(
          fixture.row,
          undo: true,
        ).map((claim) => claim['id']),
        [fixture.absent.last.$1],
      );
      fixture.read((store) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
      });
      expect(file.readAsStringSync(), 'returned editor changes');
      expect(fixture.original.readAsStringSync(), _original);
    },
  );

  testWidgets('dismissed warnings leave new work and loss of access visible', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(legacy: true, paused: true));
    await _mount(tester, fixture);
    final claims = editorWarningClaims(fixture.row);
    await _openDismiss(tester);
    await _confirmDismiss(tester);
    await tester.runAsync(() async {
      await _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).length == 2,
      );
      await fixture.controller.stop();
      fixture.read((store) {
        store.operations['pending-upload'] = Operation(
          'pending-upload',
          'upload',
          _path,
        );
        store.operations['new-legacy-session'] = Operation(
          'new-legacy-session',
          'working',
          _path,
          staged: p.join(store.setting('staging')!, 'phone-working-new'),
        );
        store.save();
      });
      await fixture.controller.start();
      await _Fixture.until(
        () =>
            editorWarningClaims(fixture.row)
                .any((claim) => claim['id'] == 'new-legacy-session'),
      );
      fixture.controller.command(
        'dismissEditorWarnings',
        _path,
        sessions: claims,
      );
      await _Fixture.until(
        () => fixture.editorResult.contains('editor warning changed'),
      );
    });
    await tester.pumpAndSettle();
    expect(editorWarningClaims(fixture.row).map((claim) => claim['id']), [
      'new-legacy-session',
    ]);
    expect(
      fixture.row['presentationErrors'],
      contains('Sync work is pending.'),
    );
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
    fixture.access.granted = false;
    await tester.runAsync(() async {
      await fixture.controller.checkPhoneFolders();
      await _Fixture.until(
        () => (fixture.row['presentationErrors'] as List).any(
          (line) => '$line'.contains('All files access'),
        ),
      );
    });
    await tester.pumpAndSettle();
    expect(_attention(tester, 'Music'), isTrue);
    expect(editorWarningClaims(fixture.row), isEmpty);
    expect(editorWarningClaims(fixture.row, undo: true), hasLength(2));
    fixture.read((store) {
      expect(store.operations['pending-upload'], isNotNull);
      expect(store.operations['new-legacy-session'], isNotNull);
    });
  });

  testWidgets('Finish editing confirms only the present sibling', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(mixed: true));
    await _mount(tester, fixture);
    final (id, owner, edit) = fixture.present!;
    expect(missingEditorClaims(fixture.row), hasLength(2));
    await tester.tap(find.text('Finish editing'));
    await tester.pumpAndSettle();
    expect(find.textContaining(edit.uri.pathSegments.last), findsOneWidget);
    expect(find.textContaining('size unavailable'), findsNothing);
    await tester.tap(find.text('Editors closed — finish'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => _Fixture.until(() => fixture.controller.finishingEdits),
    );
    await _openClear(tester);
    await _confirmClear(tester);
    await tester.runAsync(
      () => _Fixture.until(() => missingEditorClaims(fixture.row).isEmpty),
    );
    fixture.read((store) {
      final completion = store
          .operationsAt(_path)
          .singleWhere((op) => op.kind == 'finish-editing');
      expect(completion.data['sessions'], [id]);
      expect(completion.data['artifacts'], contains(owner));
      expect(store.operations[id], isNotNull);
      expect(store.operations[owner], isNotNull);
      expect(store.operations['unrelated-upload'], isNotNull);
    });
    expect(edit.readAsStringSync(), 'unsynced editor changes');
    expect(fixture.original.readAsStringSync(), _original);
    expect(
      File('${fixture.access.base}/Documents/pending.txt').readAsStringSync(),
      'unrelated pending content',
    );
  });

  testWidgets('lost All files access after preview keeps both sessions', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(paused: true));
    await _mount(tester, fixture);
    await _openClear(tester);
    fixture.access.granted = false;
    await tester.runAsync(() async {
      await fixture.controller.checkPhoneFolders();
      await _Fixture.until(
        () => (fixture.row['presentationErrors'] as List).any(
          (line) => '$line'.contains('All files access'),
        ),
      );
    });
    await _confirmClear(tester);
    await tester.runAsync(
      () => _Fixture.until(() => fixture.editorResult.startsWith('Kept ')),
    );
    expect(fixture.editorResult, contains('All files access'));
    expect(missingEditorClaims(fixture.row), isEmpty);
    expect(find.text('Finish editing'), findsNothing);
    fixture.read((store) {
      for (final (id, owner, _) in fixture.absent) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
      }
    });
  });

  testWidgets('a returning edit is kept while its absent sibling clears', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(paused: true));
    await _mount(tester, fixture);
    final (id, owner, file) = fixture.absent.first;
    late Operation sibling;
    late Operation siblingArtifact;
    fixture.read((store) {
      sibling = store.operations[fixture.absent.last.$1]!;
      siblingArtifact = store.operations[fixture.absent.last.$2]!;
    });
    final claims = missingEditorClaims(fixture.row);
    await _openClear(tester);
    file.writeAsStringSync('returned editor changes');
    await _confirmClear(tester);
    await tester.runAsync(
      () => _Fixture.until(
        () => fixture.editorResult.contains('The editor copy is present.'),
      ),
    );
    expect(fixture.editorResult, contains('Cleared 1 missing editor copy.'));
    expect(file.readAsStringSync(), 'returned editor changes');
    fixture.read((store) {
      expect(store.operations[id], isNotNull);
      expect(store.operations[owner], isNotNull);
      expect(store.operations[fixture.absent.last.$1], isNull);
      expect(store.operations[fixture.absent.last.$2], isNull);
    });
    await tester.pumpAndSettle();
    expect(find.text('Finish editing'), findsOneWidget);
    expect(find.text('Clear missing editor copies'), findsNothing);

    await tester.runAsync(() async {
      await fixture.controller.stop();
      fixture.read((store) {
        store.operations[siblingArtifact.id] = siblingArtifact;
        store.operations['new-session'] = Operation(
          'new-session',
          'working',
          _path,
          staged: sibling.staged,
        )..data = sibling.data;
        store.save();
      });
      await fixture.controller.start();
      await _Fixture.until(
        () =>
            missingEditorClaims(fixture.row)
                .any((copy) => copy['id'] == 'new-session'),
      );
      fixture.controller.command(
        'clearMissingEditorCopies',
        _path,
        sessions: claims,
      );
      await _Fixture.until(() => fixture.editorResult.startsWith('Kept '));
      fixture.read(
        (store) => expect(store.operations['new-session'], isNotNull),
      );
    });
  });

  testWidgets('a substituted staging directory is refused even after restart', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(paused: true));
    await _mount(tester, fixture);
    await _openClear(tester);
    final stage = fixture.access.staging;
    Directory(stage).renameSync('$stage-original');
    final replacement = Directory(stage)..createSync();
    File('${replacement.path}/.nomedia').createSync();
    await _confirmClear(tester);
    await tester.runAsync(() async {
      await _Fixture.until(
        () => fixture.editorResult.contains(
          'staging folder is unavailable or has changed',
        ),
      );
      await fixture.controller.stop();
      await fixture.controller.start();
      await _Fixture.until(
        () => (fixture.row['presentationErrors'] as List).contains(
          'The editor staging folder has changed.',
        ),
      );
    });
    expect(missingEditorClaims(fixture.row), isEmpty);
    fixture.read((store) {
      for (final (id, owner, _) in fixture.absent) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
      }
    });
  });

  testWidgets('build 177 sessions survive a marked replacement on upgrade', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(legacy: true, mixed: true));
    final (id, owner, edit) = fixture.present!;
    final stage = fixture.access.staging;
    final originalStage = Directory(stage).renameSync('$stage-original');
    Directory(stage).createSync();
    File('$stage/.nomedia').createSync();
    await _mount(tester, fixture);
    expect(missingEditorClaims(fixture.row), isEmpty);
    expect(find.text('Clear missing editor copies'), findsNothing);
    expect(
      fixture.row['presentationErrors'],
      contains('The original editor staging folder could not be verified.'),
    );
    final claims = editorWarningClaims(fixture.row);
    expect(claims, hasLength(3));
    await _openDismiss(tester);
    await _confirmDismiss(tester);
    await tester.runAsync(
      () => _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).length == 3,
      ),
    );
    expect(
      File(p.join(originalStage.path, p.basename(edit.path)))
          .readAsStringSync(),
      'unsynced editor changes',
    );
    fixture.read((store) {
      for (final (workId, artifactId) in [
        (id, owner),
        for (final (workId, artifactId, _) in fixture.absent)
          (workId, artifactId),
      ]) {
        expect(store.operations[workId], isNotNull);
        expect(store.operations[artifactId], isNotNull);
      }
    });
    await tester.runAsync(() async {
      await fixture.controller.stop();
      Directory(stage).deleteSync(recursive: true);
      originalStage.renameSync(stage);
      await fixture.controller.start();
      await _Fixture.until(
        () => (fixture.row['presentationErrors'] as List).contains(
          'An editor copy has returned. Review its changes.',
        ),
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('Finish editing'), findsOneWidget);
    expect(_attention(tester, 'Music'), isTrue);
    expect(edit.readAsStringSync(), 'unsynced editor changes');
  });

  testWidgets('a legacy directory alone does not prove editor closure', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(legacy: true));
    final native = NativeRootFs(testNativeLibrary);
    final stage = native.openRoot(fixture.access.staging);
    try {
      // Isolate closure from the separate lack of directory evidence.
      fixture.read((store) {
        for (final (_, owner, _) in fixture.absent) {
          store.operations[owner]!.data['sharedDirectoryIdentity'] = native
              .identity(stage);
        }
        store.save();
      });
    } finally {
      native.closeFd(stage);
    }
    await _mount(tester, fixture);
    expect(missingEditorClaims(fixture.row), isEmpty);
    expect(
      fixture.row['presentationErrors'],
      contains('Could not verify that all apps closed this editor copy.'),
    );
  });

  testWidgets('a provider handle keeps an unlinked editor copy registered', (
    tester,
  ) async {
    await tester.runAsync(
      () => fixture.seed(paused: true, parkFirstCopy: true),
    );
    await _mount(tester, fixture);
    await _openClear(tester);
    final (id, owner, file) = fixture.absent.first;
    fixture.parkedCopy.renameSync(file.path);
    final opened = await tester.runAsync(
      () => fixture.controller.documentsCommand('open', {
        'working': p.basename(file.path),
        'token': 'open-editor-fixture',
      }),
    );
    try {
      file.deleteSync();
      await _confirmClear(tester);
      await tester.runAsync(
        () => _Fixture.until(
          () => fixture.editorResult.contains('still has the editor copy open'),
        ),
      );
      expect(fixture.editorResult, contains('Cleared 1 missing editor copy.'));
      fixture.read((store) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
        expect(store.operations[fixture.absent.last.$1], isNull);
        expect(store.operations[fixture.absent.last.$2], isNull);
      });
    } finally {
      NativeRootFs(testNativeLibrary).closeFd(opened!['fd'] as int);
      await tester.runAsync(
        () => fixture.controller.documentsCommand('closed', {
          'token': 'open-editor-fixture',
        }),
      );
    }
  });

  testWidgets('a provider-held editor copy survives a worker restart', (
    tester,
  ) async {
    await tester.runAsync(
      () => fixture.seed(paused: true, parkFirstCopy: true),
    );
    await _mount(tester, fixture);
    final (id, owner, file) = fixture.absent.first;
    fixture.parkedCopy.renameSync(file.path);
    const token = 'restart-held-open';
    final opened = await tester.runAsync(
      () => fixture.controller.documentsCommand('open', {
        'working': p.basename(file.path),
        'token': token,
      }),
    );
    final fd = opened!['fd'] as int;
    try {
      file.deleteSync();
      await tester.runAsync(() async {
        await fixture.controller.stop();
        await fixture.controller.start();
        await _Fixture.until(
          () => (fixture.row['presentationErrors'] as List).contains(
            'An app may still have the editor copy open.',
          ),
        );
      });
      await tester.pumpAndSettle();
      expect(missingEditorClaims(fixture.row).map((claim) => claim['id']), [
        fixture.absent.last.$1,
      ]);
      expect(editorWarningClaims(fixture.row), isEmpty);
      await _openClear(tester);
      await _confirmClear(tester);
      await tester.runAsync(
        () => _Fixture.until(
          () => fixture.editorResult == 'Cleared 1 missing editor copy.',
        ),
      );
      expect(File('/proc/self/fd/$fd').readAsStringSync(), _original);
      fixture.read((store) {
        expect(store.operations[id]!.data[providerOpenTokensKey], [token]);
        expect(store.operations[owner], isNotNull);
        expect(store.operations[fixture.absent.last.$1], isNull);
        expect(store.operations[fixture.absent.last.$2], isNull);
      });
    } finally {
      NativeRootFs(testNativeLibrary).closeFd(fd);
    }
    await tester.runAsync(() async {
      await fixture.controller.documentsCommand('closed', {'token': token});
      await _Fixture.until(
        () =>
            missingEditorClaims(fixture.row).any((claim) => claim['id'] == id),
      );
    });
    await tester.pumpAndSettle();
    await _openClear(tester);
    await _confirmClear(tester);
    await tester.runAsync(
      () =>
          _Fixture.until(() => (fixture.row['workingCopies'] as List).isEmpty),
    );
    fixture.read((store) {
      expect(store.operations[id], isNull);
      expect(store.operations[owner], isNull);
    });
  });
}
