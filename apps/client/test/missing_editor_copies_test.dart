import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:anj_cloud/core/access/access_store.dart';
import 'package:anj_cloud/core/access/documents_service.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/editor_diagnostic.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/open_documents.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
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
const _edit = 'unsynced editor changes';

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
  final routing = AndroidPhoneRootFs(
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

  void markLegacyReleaseIntents({Iterable<int> slots = const [0, 1]}) {
    read((store) {
      for (final slot in slots) {
        final (id, owner, _) = absent[slot];
        store.operations[owner]!.data['releasing'] = store.operations[id]!.hash;
      }
      store.save();
    });
  }

  Future<void> seed({
    bool mixed = false,
    bool paused = false,
    bool parkFirstCopy = false,
    bool legacy = false,
    bool keepNamedCopy = false,
    bool fromCloud = false,
  }) async {
    final root = Directory('${dir.path}/root')..createSync();
    final staging = Directory('${dir.path}/private-stage');
    for (final folder in phoneFolderNames.values) {
      Directory('${access.base}/$folder').createSync(recursive: true);
    }
    if (!fromCloud) original.writeAsStringSync(_original);
    final store = Manifest(profile)
      ..setSetting('root', root.path)
      ..setSetting('staging', staging.path)
      ..setSetting('accountUid', 'anonymous-fixture')
      ..setSetting('accountOrigin', 'https://fixture.invalid');
    if (fromCloud) store.setSetting('retention', 'local');
    final routing = fromCloud
        ? AndroidPhoneRootFs(access.layout, testNativeLibrary)
        : MappedRootFs(access.layout, testNativeLibrary);
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
      if (mixed || keepNamedCopy) present = await handOut();
      if (mixed) {
        present!.$3.writeAsStringSync(_edit);
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

  void markInterruptedReclaim(String id, String owner) {
    read((store) {
      final work = store.operations[id]!;
      // The intent is saved before unlink and survives until finalization.
      work.data['reclaiming'] = true;
      store.operations[owner]!.data['releasing'] = work.hash;
      store.save();
    });
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

Future<void> _confirmFinish(WidgetTester tester, _Fixture fixture) async {
  await tester.tap(find.text('Finish editing'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Editors closed — finish'));
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => _Fixture.until(() => fixture.controller.finishingEdits),
  );
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

class _DiagnosticCloud extends FakeCloud {
  int calls = 0;

  @override
  void check() {
    calls++;
    super.check();
  }
}

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  testWidgets('legacy release intents are Details-only on first projection', (
    tester,
  ) async {
    String retainedState() {
      late String snapshot;
      fixture.read((store) {
        final entry = store.entries[_path]!;
        expect(
          entry.workingCopy,
          store.operations[fixture.absent.last.$1]!.staged,
        );
        expect(entry.override, Retention.local);
        snapshot = jsonEncode([
          entry.workingCopy,
          entry.fileId,
          entry.etag,
          for (final (id, owner, file) in fixture.absent) ...[
            store.operations[id]!.toJson(),
            store.operations[owner]!.toJson(),
            file.existsSync(),
          ],
        ]);
      });
      return snapshot;
    }

    await tester.runAsync(() async {
      await fixture.seed(legacy: true, fromCloud: true);
      fixture.markLegacyReleaseIntents();
    });
    final before = retainedState();
    Map<String, dynamic>? first;
    Map<String, dynamic>? beforeRestart;
    fixture.controller.addListener(() {
      for (final row in fixture.controller.entries) {
        if (row['path'] == _path && !identical(row, beforeRestart)) {
          first ??= row;
        }
      }
    });
    await _mount(tester, fixture);

    void expectQuiet(Map<String, dynamic> row) {
      expect(hasProblem(row), isFalse, reason: 'The first row has no warning');
      expect(hasEditing(row), isFalse);
      expect(hasQueuedWork(row), isFalse);
      expect(rowBadge(row), RowBadge.local);
      expect(missingEditorClaims(row), isEmpty);
      expect(editorWarningClaims(row), isEmpty);
      expect(editorWarningClaims(row, undo: true), isEmpty);
      expect(row['localArtifacts'], containsPair('uncertain', false));
      expect(row['localArtifacts'], containsPair('count', 0));
      expect(
        RegExp('Cleanup could not be confirmed')
            .allMatches(workingCopyDetails(row)),
        hasLength(2),
      );
    }

    expectQuiet(first!);
    expectQuiet(fixture.row);
    expect(_attention(tester, _path), isFalse);
    expect(_attention(tester, 'Music'), isFalse);
    expect(find.text('Dismiss warning'), findsNothing);
    expect(find.text('Finish editing'), findsNothing);
    await _openDetails(tester);
    expect(
      find.textContaining('Cleanup could not be confirmed', findRichText: true),
      findsWidgets,
    );
    expect(find.widgetWithText(TextButton, 'Undo'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await fixture.controller.stop();
      expect(
        File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
        '0,0,0',
      );
      expect(retainedState(), before);
      beforeRestart = fixture.row;
      first = null;
      await fixture.controller.start();
      final pass = await fixture.controller.backgroundRun(
        timeout: const Duration(seconds: 5),
      );
      expect(pass['timedOut'], isNot(true));
    });
    await tester.pumpAndSettle();
    expectQuiet(first!);
    expectQuiet(fixture.row);
    expect(_attention(tester, _path), isFalse);
    expect(_attention(tester, 'Music'), isFalse);
    expect(fixture.original.readAsStringSync(), _original);
    await tester.runAsync(fixture.controller.stop);
    expect(
      File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
      '0,0,0',
    );
    expect(retainedState(), before);
  });

  testWidgets('an existing acknowledgement survives Details-only projection', (
    tester,
  ) async {
    await tester.runAsync(
      () => fixture.seed(legacy: true, paused: true, parkFirstCopy: true),
    );
    await _mount(tester, fixture);
    final [first, second] = editorWarningClaims(fixture.row);
    late Map<String, dynamic> undo;
    await tester.runAsync(() async {
      fixture.controller.command(
        'dismissEditorWarnings',
        _path,
        sessions: [first],
      );
      await _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).isNotEmpty,
      );
      undo = editorWarningClaims(fixture.row, undo: true).single;
      await fixture.controller.stop();
      fixture.markLegacyReleaseIntents();
      await fixture.controller.start();
      await _Fixture.until(() => !hasProblem(fixture.row));
      expect(editorWarningClaims(fixture.row, undo: true), [undo]);
      expect(editorWarningClaims(fixture.row), isEmpty);
      fixture.controller.command(
        'dismissEditorWarnings',
        _path,
        sessions: [second],
      );
      await _Fixture.until(
        () => fixture.editorResult.contains('still refers to this copy'),
      );
      expect(editorWarningClaims(fixture.row, undo: true), [undo]);
    });

    await tester.pumpAndSettle();
    await _openDetails(tester);
    expect(
      find.textContaining('Warning dismissed', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await _Fixture.until(
        () => editorWarningClaims(fixture.row, undo: true).isEmpty,
      );
      fixture.controller.command('undoEditorWarnings', _path, sessions: [undo]);
      await _Fixture.until(
        () => fixture.editorResult.contains('editor warning changed'),
      );
      await fixture.controller.stop();
      final (_, _, file) = fixture.absent.first;
      fixture.parkedCopy.renameSync(file.path);
      file.writeAsStringSync(_edit);
      await fixture.controller.start();
      await _Fixture.until(() => finishableCopies(fixture.row).isNotEmpty);
      expect(libraryStatus(fixture.row), contains('available with changes'));
      expect(finishableCopies(fixture.row).single['id'], first['id']);
      expect(
        workingCopyDetails(fixture.row),
        contains('Cleanup could not be confirmed'),
      );
      expect(fixture.original.readAsStringSync(), _original);
    });
    await tester.pumpAndSettle();
    expect(find.text('Finish editing'), findsOneWidget);
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
  });

  testWidgets('Details-only notices leave another artifact and Clear visible', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await fixture.seed(legacy: true, paused: true);
      fixture.markLegacyReleaseIntents(slots: [0]);
      final native = NativeRootFs(testNativeLibrary);
      final stageFd = native.openRoot(fixture.access.staging);
      try {
        fixture.read((store) {
          final (session, owner, _) = fixture.absent.last;
          store.operations[session]!.data[providerOpenTokensKey] = <String>[];
          store.operations[owner]!.data['sharedDirectoryIdentity'] = native
              .identity(stageFd);
          final name = '${sharedStagingTag}download-independent';
          store.operations['independent-download'] = Operation(
            'independent-download',
            'artifact',
            _path,
            phase: 'complete',
            staged: p.join(store.setting('staging')!, name),
          )..data = {'role': 'download', 'name': name};
          store.save();
        });
      } finally {
        native.closeFd(stageFd);
      }
    });
    await _mount(tester, fixture);
    expect(
      missingEditorClaims(fixture.row).single['id'],
      fixture.absent.last.$1,
    );
    await _openClear(tester);
    await _confirmClear(tester);
    await tester.runAsync(
      () => _Fixture.until(() => missingEditorClaims(fixture.row).isEmpty),
    );
    await tester.pumpAndSettle();
    expect(hasEditing(fixture.row), isFalse);
    expect(fixture.row['localArtifacts'], containsPair('uncertain', true));
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
    expect(
      workingCopyDetails(fixture.row),
      contains('Cleanup could not be confirmed'),
    );
    fixture.access.granted = false;
    await tester.runAsync(() async {
      await fixture.controller.checkPhoneFolders();
      await _Fixture.until(
        () => libraryStatus(fixture.row).contains('All files access'),
      );
      await fixture.controller.stop();
      expect(
        File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
        '0,0,0',
      );
    });
    await tester.pumpAndSettle();
    expect(_attention(tester, _path), isTrue);
    expect(_attention(tester, 'Music'), isTrue);
    expect(fixture.original.readAsStringSync(), _original);
    fixture.read((store) {
      final (kept, owner, _) = fixture.absent.first;
      expect(store.operations[kept], isNotNull);
      expect(store.operations[owner]!.data['releasing'], isNotNull);
      expect(store.operations[fixture.absent.last.$1], isNull);
      expect(store.operations['independent-download'], isNotNull);
    });
  });

  for (final action in [
    'delete',
    'move',
    'finish and move',
    'finish a previously uploaded edit and move',
    'cloud move',
  ]) {
    test('mapped $action settles with a sync peer', () async {
      final move = action != 'delete';
      final previouslyUploaded =
          action == 'finish a previously uploaded edit and move';
      final finishEdit = action == 'finish and move' || previouslyUploaded;
      final cloudMove = action == 'cloud move';
      await fixture.seed(
        legacy: true,
        fromCloud: true,
        parkFirstCopy: move && !cloudMove,
      );
      fixture.markLegacyReleaseIntents();
      final cloud = await _cloud();
      final before = cloud.counter;
      final fileId = cloud.fileIds[_path];
      final peerProfile = Directory('${fixture.dir.path}/peer-profile');
      final peerRoot = Directory('${fixture.dir.path}/peer-root')..createSync();
      final peerStage = Directory('${fixture.dir.path}/peer-stage');
      final peerSource = File('${peerRoot.path}/$_path');
      const destination = 'Music/moved.mp3';
      final phoneDestination = File('${fixture.access.base}/$destination');
      final peerDestination = File('${peerRoot.path}/$destination');

      Future<void> sync({bool act = false, bool finish = false}) async {
        final store = Manifest(fixture.profile);
        final routing = AndroidPhoneRootFs(
          fixture.access.layout,
          testNativeLibrary,
        );
        final phone = SyncEngine(
          store,
          RootTree(
            Directory(store.setting('root')!),
            Directory(store.setting('staging')!),
            routing,
          ),
          cloud,
        );
        final peerStore = Manifest(peerProfile)
          ..setSetting('retention', 'local');
        final peer = SyncEngine(
          peerStore,
          RootTree(peerRoot, peerStage, NativeRootFs(testNativeLibrary)),
          cloud,
        );
        try {
          if (act) {
            await phone.tick();
            await peer.tick();
            expect(peerSource.readAsStringSync(), _original);
            expect(fixture.original.readAsStringSync(), _original);
            expect(cloud.counter, before);
            expect(cloud.deletes, 0);
            expect(cloud.moves, isEmpty);
            routing.setPaused(true);
            await phone.tick();
            await peer.tick();
            expect(fixture.original.readAsStringSync(), _original);
            expect(peerSource.readAsStringSync(), _original);
            expect(cloud.counter, before);
            expect(cloud.deletes, 0);
            expect(cloud.moves, isEmpty);
            routing.setPaused(false);
            phone.requestFullVerification();
            if (cloudMove) {
              await cloud.move(
                _path,
                destination,
                etag: cloud.versions[_path]!,
              );
              await peer.tick();
              expect(peerDestination.readAsStringSync(), _original);
            } else if (move) {
              fixture.original.renameSync(phoneDestination.path);
              phone.markDirty(_path);
              phone.markDirty(destination);
              final returned = fixture.absent.first.$3;
              phone.barrier = (phase, _) {
                if (phase == 'move-before-dispatch') {
                  fixture.parkedCopy.renameSync(returned.path);
                  returned.writeAsStringSync(_edit);
                }
              };
              await phone.tick();
              expect(cloud.moves, isEmpty);
              expect(cloud.deletes, 0);
              expect(cloud.files.keys, [_path]);
              expect(returned.readAsStringSync(), _edit);
              final held = await projectEntry(phone, store.entries[_path]!);
              expect(held['status'], contains('editor copy evidence changed'));
              expect(
                finishableCopies(held).single['id'],
                fixture.absent.first.$1,
              );
              phone.barrier = null;
              if (finishEdit) {
                if (previouslyUploaded) {
                  await phone.tick();
                  expect(cloud.files[_path], utf8.encode(_edit));
                  // A client that uploaded before this fix recorded the
                  // new cloud version as the Local baseline at the old name.
                  final edited = _digest(returned);
                  store.entries[_path]!
                    ..etag = cloud.versions[_path]
                    ..baselineHash = edited
                    ..localHash = edited
                    ..recordRemoteVersion(cloud.versions[_path]!, edited);
                  store.save();
                }
                final row = await projectEntry(phone, store.entries[_path]!);
                final copy = finishableCopies(row).single;
                phone.editing.request(_path, [Map<String, dynamic>.from(copy)]);
                expect(phone.editing.requests, hasLength(1));
                expect(returned.readAsStringSync(), _edit);
                expect(phoneDestination.readAsStringSync(), _original);
                return;
              }
              returned.renameSync(fixture.parkedCopy.path);
            } else {
              fixture.original.deleteSync();
              phone.markDirty(_path);
              phone.debugElapsed = () => Duration.zero;
              await phone.tick();
              expect(cloud.deletes, 0);
              phone.debugElapsed = () => const Duration(minutes: 1);
            }
          }
          await phone.tick();
          if (finish) {
            expect(
              phone.editing.requests,
              isEmpty,
              reason: store.entries[_path]?.status,
            );
            expect(fixture.absent.first.$3.existsSync(), isFalse);
            expect(cloud.files[_path], utf8.encode(_edit));
            expect(cloud.moves, isEmpty);
            expect(phoneDestination.readAsStringSync(), _original);
            return;
          }
          await peer.tick();
          final phoneState = {
            for (final entry in store.entries.values.where(
              (e) => e.kind == ItemKind.file,
            ))
              entry.path: await projectEntry(phone, entry),
          };
          final operations = store.operations.values
              .map((op) => '${op.kind}:${op.data['role']}:${op.path}')
              .toList();
          final diagnosis =
              'cloud=${cloud.files.keys}, moves=${cloud.moves}, operations=$operations';
          expect(fixture.original.existsSync(), isFalse);
          expect(cloud.files, isNot(contains(_path)), reason: diagnosis);
          expect(peerSource.existsSync(), isFalse, reason: diagnosis);
          expect(cloud.deletes, move ? 0 : 1);
          expect(cloud.moves, move ? ['$_path -> $destination'] : isEmpty);
          if (move) {
            final content = finishEdit ? _edit : _original;
            expect(cloud.files[destination], utf8.encode(content));
            expect(cloud.fileIds[destination], fileId);
            expect(phoneDestination.readAsStringSync(), content);
            expect(peerDestination.readAsStringSync(), content);
            final moved = phoneState[destination]!;
            if (finishEdit) {
              final entry = store.entries[destination]!;
              expect(phone.editing.requests, isEmpty);
              expect(
                entry.preservedCopies.map(
                  (path) => phone.artifacts.resolve(path).readAsStringSync(),
                ),
                contains(_original),
              );
            } else {
              expect(rowBadge(moved), RowBadge.local);
            }
            expect(
              moved['workingCopy'],
              store.operations[fixture.absent.last.$1]!.staged,
            );
            expect(
              RegExp('Cleanup could not be confirmed')
                  .allMatches(workingCopyDetails(moved)),
              hasLength(finishEdit ? 1 : 2),
            );
          }
          final old = store.entries[_path];
          if (old != null) {
            expect(
              visibleInLibrary(phoneState[_path]!),
              isFalse,
              reason: diagnosis,
            );
          }
          for (final (id, owner, staged) in fixture.absent) {
            if (finishEdit && id == fixture.absent.first.$1) {
              expect(store.operations[id], isNull);
              expect(store.operations[owner], isNull);
              continue;
            }
            expect(store.operations[id]!.path, move ? destination : _path);
            final owned = store.operations[owner]!;
            expect(owned.path, move ? destination : _path);
            expect(owned.data['name'], p.basename(staged.path));
            expect(owned.data['releasing'], owned.hash);
          }
        } finally {
          peer.close();
          phone.close();
          routing.setPaused(true);
        }
      }

      await sync(act: true);
      if (finishEdit) {
        await sync(finish: true);
        await sync();
      }
      await sync();
    });
  }

  for (final replaceAfterListing in [false, true]) {
    test(
      'mapped rename preserves both files and original sessions when the '
      'cloud source is replaced ${replaceAfterListing ? 'after' : 'before'} listing',
      () async {
        await fixture.seed(legacy: true, fromCloud: true);
        fixture.markLegacyReleaseIntents();
        final cloud = await _cloud();
        final originalId = cloud.fileIds[_path]!;
        const replacement = 'different cloud song';
        const destination = 'Music/renamed.mp3';
        final renamed = File('${fixture.access.base}/$destination');
        late int replacementId;
        void replaceSource() {
          cloud.remove(_path);
          cloud.put(_path, replacement);
          replacementId = cloud.fileIds[_path]!;
          expect(replacementId, isNot(originalId));
        }

        for (var launch = 0; launch < 3; launch++) {
          final store = Manifest(fixture.profile);
          final routing = AndroidPhoneRootFs(
            fixture.access.layout,
            testNativeLibrary,
          );
          final phone = SyncEngine(
            store,
            RootTree(
              Directory(store.setting('root')!),
              Directory(store.setting('staging')!),
              routing,
            ),
            cloud,
          );
          try {
            if (launch == 0) {
              await phone.tick();
              fixture.original.renameSync(renamed.path);
              phone.markDirty(_path);
              phone.markDirty(destination);
              if (replaceAfterListing) {
                phone.barrier = (phase, _) {
                  if (phase == 'move-before-dispatch') replaceSource();
                };
              } else {
                replaceSource();
              }
            }
            await phone.tick();
            expect(cloud.files[_path], utf8.encode(replacement));
            expect(cloud.fileIds[_path], replacementId);
            expect(cloud.deletes, 0);
            expect(renamed.readAsStringSync(), _original);
            expect(
              cloud.moves,
              replaceAfterListing ? ['$_path -> $destination'] : isEmpty,
            );
            final source = store.entries[_path]!;
            expect(source.fileId, originalId);
            expect(
              source.workingCopy,
              store.operations[fixture.absent.last.$1]!.staged,
            );
            for (final (id, owner, staged) in fixture.absent) {
              final session = store.operations[id]!;
              final owned = store.operations[owner]!;
              expect(session.path, _path);
              expect(owned.path, _path);
              expect(owned.staged, session.staged);
              expect(owned.data['name'], p.basename(staged.path));
              expect(owned.data['releasing'], session.hash);
              expect(owned.hash, session.hash);
            }
            if (launch == 0 && replaceAfterListing) {
              expect(phone.operation(_path, 'move'), isNotNull);
              expect(cloud.files[destination], isNull);
            } else {
              expect(phone.operation(_path, 'move'), isNull);
              expect(source.conflict, isNotNull);
              expect(cloud.files[destination], utf8.encode(_original));
              expect(store.entries[destination]!.workingCopy, isNull);
              expect(
                store
                    .operationsAt(destination)
                    .where((op) => op.kind == 'working'),
                isEmpty,
              );
            }
          } finally {
            phone.close();
            routing.setPaused(true);
          }
        }
      },
    );
  }

  for (final activeEdit in [true, false]) {
    test(
      'cloud move leaves ${activeEdit ? 'an active edit' : 'conflicting ownership'} with the source records',
      () async {
        await fixture.seed(
          legacy: true,
          fromCloud: true,
          parkFirstCopy: activeEdit,
        );
        fixture.markLegacyReleaseIntents();
        final store = Manifest(fixture.profile);
        final routing = AndroidPhoneRootFs(
          fixture.access.layout,
          testNativeLibrary,
        );
        final cloud = await _cloud();
        final phone = SyncEngine(
          store,
          RootTree(
            Directory(store.setting('root')!),
            Directory(store.setting('staging')!),
            routing,
          ),
          cloud,
        );
        const destination = 'Music/other-name.mp3';
        final (id, owner, staged) = fixture.absent.first;
        try {
          if (activeEdit) {
            fixture.parkedCopy.renameSync(staged.path);
            staged.writeAsStringSync(_edit);
          } else {
            store.operations['conflicting-owner'] = Operation.fromJson({
              ...store.operations[owner]!.toJson(),
              'id': 'conflicting-owner',
              'path': destination,
            });
            store.save();
          }
          await cloud.move(_path, destination, etag: cloud.versions[_path]!);
          await phone.tick();
          await phone.tick();
          final row = await projectEntry(phone, store.entries[destination]!);
          expect(row['workingCopies'], isEmpty);
          expect(store.operations[id]!.path, _path);
          expect(store.operations[owner]!.path, _path);
          if (activeEdit) expect(staged.readAsStringSync(), _edit);
          expect(cloud.files.keys, [destination]);
          expect(cloud.files[destination], utf8.encode(_original));
        } finally {
          phone.close();
          routing.setPaused(true);
        }
      },
    );
  }

  test(
    'diagnostic reports independent relationships without side effects',
    () async {
      await fixture.seed(legacy: true, keepNamedCopy: true);
      final manifest = Manifest(fixture.profile);
      final native = MappedRootFs(fixture.access.layout, testNativeLibrary);
      final tree = RootTree(
        Directory(manifest.setting('root')!),
        Directory(manifest.setting('staging')!),
        native,
      );
      final cloud = _DiagnosticCloud();
      final engine = SyncEngine(manifest, tree, cloud);
      final entry = manifest.entries[_path]!;
      final historical = manifest.operations[fixture.absent.first.$1]!;
      final mixed = manifest.operations[fixture.absent.last.$1]!;
      final present = manifest.operations[fixture.present!.$1]!;
      final owner = manifest.operations[fixture.absent.last.$2]!;
      final token = 'private-provider-token';
      try {
        Operation accept(
          Operation session,
          String id, {
          String? hash,
          String? version,
        }) {
          final upload =
              Operation(
                  id,
                  'artifact',
                  _path,
                  hash: hash ?? session.hash,
                  expectedEtag: version ?? session.expectedEtag,
                  phase: 'complete',
                )
                ..data = {
                  'role': 'working-upload',
                  'workingId': session.id,
                  'sessionBinding': engine.editing.binding,
                  'lineageVersion': 1,
                  'accepted': true,
                  'snapshotHash': hash ?? session.hash,
                  'identity': 'private-snapshot-identity',
                  'snapshotIdentity': 'private-snapshot-identity',
                };
          manifest.operations[id] = upload;
          session.data['uploadTip'] = id;
          return upload;
        }

        final firstUpload = accept(historical, 'private-accepted-first');
        final secondUpload = accept(mixed, 'private-accepted-second');
        manifest.operations['private-recovery'] =
            Operation('private-recovery', 'preserve', _path)
              ..data = {
                'workingId': mixed.id,
                'source': mixed.staged,
                'names': [mixed.staged],
                'artifacts': [owner.id, secondUpload.id],
              };
        manifest.operations['private-finish'] = Operation(
          'private-finish',
          'finish-editing',
          _path,
        )..data['sessions'] = [mixed.id];
        manifest.operations['private-ownership'] = Operation(
          'private-ownership',
          'edit-ownership',
          _path,
          phase: 'authorized',
        )..data = {'session': mixed.id, 'artifact': owner.id};
        mixed.data
          ..['reclaiming'] = true
          ..['presentationError'] = 'private arbitrary exception';
        owner
          ..phase = 'owned'
          ..data['installing'] = _path
          ..data['releasing'] = mixed.hash;
        present.data
          ..['uploadTip'] = 'private-missing-upload'
          ..[providerOpenTokensKey] = [token]
          ..[providerClosureUnknownKey] = true;
        openDocuments.add(
          token,
          OpenDocument(
            _path,
            owner.data['identity'] as String,
            write: true,
            working: p.basename(mixed.staged!),
          ),
        );
        manifest.save();
        String state() => jsonEncode({
          'entries': manifest.entries.values
              .map((row) => row.toJson())
              .toList(),
          'operations': manifest.operations.values
              .map((op) => op.toJson())
              .toList(),
        });
        Object? changes() =>
            manifest.db.select('SELECT total_changes() AS n').single['n'];
        Map<String, Object?> diagnostic({bool paused = false}) {
          final before = state();
          final written = changes();
          final report = readEditorDiagnostic(
            engine,
            _path,
            engine.selectionVersion(entry),
            phoneStoragePaused: paused,
          )!;
          expect(state(), before);
          expect(changes(), written);
          expect(cloud.calls, 0);
          return report;
        }

        final report = diagnostic();
        final slots = (report['sessionSlots'] as List).cast<Map>();
        expect(slots, hasLength(3));
        expect(slots[0]['relationships'], ['historical']);
        expect(
          (slots[0]['acceptedUploads'] as List).single['obligation'],
          'terminal',
        );
        expect(slots[1]['relationships'], ['historical', 'active']);
        expect(
          (slots[1]['acceptedUploads'] as List).single['obligation'],
          'active',
        );
        expect(slots[2]['relationships'], ['unknown']);
        expect(
          slots[0]['staging'],
          containsPair('historicalTargetDirectory', 'unknown'),
        );
        expect(slots[0]['staging'], containsPair('target', 'absent'));
        expect(
          slots[1]['guardPredicates'],
          containsPair('ownerIncomplete', true),
        );
        expect(
          slots[1]['guardPredicates'],
          containsPair('ownerInstalling', true),
        );
        expect(
          slots[1]['guardPredicates'],
          containsPair('ownerReleasing', true),
        );
        expect(slots[1]['guardPredicates'], containsPair('reclaiming', true));
        expect(
          slots[1]['providerClosure'],
          containsPair('inMemoryByName', true),
        );
        expect(
          slots[1]['providerClosure'],
          containsPair('inMemoryByOwnerIdentity', true),
        );
        expect(slots[1]['providerClosure'], containsPair('durable', 'unknown'));
        expect(slots[2]['staging'], containsPair('target', 'present'));
        expect(
          slots[2]['providerClosure'],
          containsPair('durable', 'outstanding'),
        );
        expect(
          (slots[1]['references'] as List).expand(
            (row) => row['relationships'] as List,
          ),
          containsAll([
            'workingId',
            'source',
            'names',
            'artifacts',
            'upload artifact reference',
            'authorized edit ownership',
            'Finish membership',
          ]),
        );
        final dumped = jsonEncode(report);
        for (final private in [
          _path,
          fixture.dir.path,
          historical.id,
          firstUpload.id,
          secondUpload.id,
          historical.hash!,
          historical.expectedEtag!,
          'private-',
          _original,
        ]) {
          expect(dumped, isNot(contains(private)));
        }
        final inaccessible = diagnostic(paused: true);
        final blocked = (inaccessible['sessionSlots'] as List).first as Map;
        expect(blocked['staging'], containsPair('access', 'unavailable'));
        expect(blocked['staging'], containsPair('target', 'unknown'));
        expect(blocked['guardPredicates'], containsPair('uploadTip', true));
        expect(
          readEditorDiagnostic(
            engine,
            _path,
            'old selection',
            phoneStoragePaused: false,
          ),
          isNull,
        );
        expect(cloud.calls, 0);
        expect(fixture.original.readAsStringSync(), _original);
        expect(fixture.present!.$3.existsSync(), isTrue);

        secondUpload.data['snapshotHash'] = 'private-different-snapshot';
        final unreadable = Link(fixture.absent.first.$3.path)
          ..createSync(fixture.original.path);
        manifest.save();
        final changed = diagnostic();
        final changedSlots = (changed['sessionSlots'] as List).cast<Map>();
        expect(
          changedSlots[0]['staging'],
          containsPair('target', 'read error'),
        );
        expect(changedSlots[1]['relationships'], ['active']);
        expect(
          (changedSlots[1]['acceptedUploads'] as List).single,
          containsPair('snapshotHash', 'mismatch'),
        );
        unreadable.deleteSync();

        final beforeRecovery = diagnostic();
        expect(beforeRecovery['entryRecovery'], {
          'presentCount': 0,
          'recoverOffered': false,
          'dismissOffered': false,
        });
        expect(
          beforeRecovery['entryWarnings'],
          isNot(contains('independent recovery copies')),
        );
        final retained = engine.artifacts.reserve(_path, 'preserved')
          ..writeAsStringSync('private-recovery-bytes');
        engine.artifacts.complete(retained, hash: _digest(retained));
        final staged = tree.durablePath(retained);
        entry.preservedCopies.add(staged);
        manifest.operations['private-retained'] = Operation(
          'private-retained',
          'retained',
          _path,
          staged: staged,
        );
        manifest.save();
        final withRecovery = diagnostic();
        expect(
          engine.recovery.describe(_path),
          containsPair('recoverable', true),
        );
        expect(withRecovery['entryRecovery'], {
          'presentCount': 1,
          'recoverOffered': true,
          'dismissOffered': true,
        });
        expect(
          withRecovery['entryWarnings'],
          contains('independent recovery copies'),
        );
        expect(withRecovery['sessionSlots'], beforeRecovery['sessionSlots']);
        expect(jsonEncode(withRecovery), isNot(contains('private-')));
        expect(
          jsonEncode(withRecovery),
          isNot(contains(p.basename(retained.path))),
        );
        expect(retained.readAsStringSync(), 'private-recovery-bytes');
        final pausedRecovery = diagnostic(paused: true);
        expect(
          pausedRecovery['entryWarnings'],
          contains('recovery copy evidence unknown'),
        );
        expect(pausedRecovery['entryRecovery'], {
          'presentCount': 'unknown',
          'recoverOffered': 'unknown',
          'dismissOffered': true,
        });
        retained.deleteSync();
        expect(diagnostic()['entryRecovery'], {
          'presentCount': 0,
          'recoverOffered': false,
          'dismissOffered': true,
        });
        final unreadableRecovery = Link(retained.path)
          ..createSync(fixture.original.path);
        expect(diagnostic()['entryRecovery'], pausedRecovery['entryRecovery']);
        unreadableRecovery.deleteSync();

        void link(Operation earlier, Operation later) {
          earlier.data['supersededBy'] = later.id;
          later.data['supersedes'] = earlier.id;
          later.data['baseEtag'] = earlier.expectedEtag;
        }

        final middle = accept(
          historical,
          'private-middle',
          hash: 'private-middle-hash',
          version: 'private-middle-version',
        );
        final tip = accept(historical, 'private-tip');
        link(firstUpload, middle);
        link(middle, tip);

        void checkLineage({required bool verified, required bool closedCycle}) {
          manifest.save();
          final slot = (diagnostic()['sessionSlots'] as List).first as Map;
          final uploads = (slot['acceptedUploads'] as List).cast<Map>();
          expect(
            uploads.map((row) => row['receipt']),
            everyElement('accepted'),
          );
          expect(uploads.map((row) => row['supersession']), [
            'match',
            'match',
            closedCycle ? 'match' : 'unknown',
          ]);
          expect(
            uploads.map((row) => row['lineage']),
            everyElement(verified ? 'verified local tip' : 'unknown'),
          );
          expect(
            uploads.map((row) => row['obligation']),
            everyElement(verified ? 'terminal' : 'unknown'),
          );
          expect(slot['relationships'], [
            'historical',
            if (!verified) 'unknown',
          ]);
        }

        checkLineage(verified: true, closedCycle: false);
        final sessionHash = historical.hash;
        historical.hash = 'private-different-session-hash';
        checkLineage(verified: false, closedCycle: false);
        historical.hash = sessionHash;
        tip.data['supersededBy'] = 'private-missing-tip';
        historical.data['uploadTip'] = 'private-missing-tip';
        checkLineage(verified: false, closedCycle: false);
        historical.data['uploadTip'] = tip.id;
        link(tip, firstUpload);
        checkLineage(verified: false, closedCycle: true);
      } finally {
        openDocuments.remove(token);
        engine.close();
        native.setPaused(true);
      }
    },
  );

  test('diagnostic tracks staging attention and conflict recovery', () async {
    await fixture.seed(legacy: true);
    final manifest = Manifest(fixture.profile);
    final native = MappedRootFs(fixture.access.layout, testNativeLibrary);
    final tree = RootTree(
      Directory(manifest.setting('root')!),
      Directory(manifest.setting('staging')!),
      native,
    );
    final cloud = _DiagnosticCloud();
    final engine = SyncEngine(manifest, tree, cloud);
    final entry = manifest.entries[_path]!;
    const stagingWarning = 'staging artifacts uncertain';
    const conflictReason = 'private conflict details';
    try {
      int writes() =>
          manifest.db.select('SELECT total_changes() AS n').single['n'] as int;
      Map<String, Object?> diagnostic({bool paused = false}) {
        final snapshots = jsonEncode([
          entry.toJson(),
          manifest.operations.values.map((op) => op.toJson()).toList(),
        ]);
        final before = writes();
        final report = readEditorDiagnostic(
          engine,
          _path,
          engine.selectionVersion(entry),
          phoneStoragePaused: paused,
        )!;
        expect(writes(), before);
        expect(
          jsonEncode([
            entry.toJson(),
            manifest.operations.values.map((op) => op.toJson()).toList(),
          ]),
          snapshots,
        );
        expect(cloud.calls, 0);
        final json = jsonEncode(report);
        for (final secret in [
          _path,
          fixture.dir.path,
          _original,
          _edit,
          'private ',
        ]) {
          expect(json, isNot(contains(secret)));
        }
        return report;
      }

      final row = await projectEntry(engine, entry);
      final claims = editorWarningClaims(row);
      expect(claims, hasLength(2));
      engine.missingEditors.changeWarnings(
        entry,
        engine.editing.binding,
        claims,
        undo: false,
      );

      final download = engine.artifacts.reserve(_path, 'download')
        ..writeAsStringSync('private download bytes');
      engine.artifacts.complete(download, hash: _digest(download));
      final presentRow = await projectEntry(engine, entry);
      expect(editorWarningClaims(presentRow, undo: true), hasLength(2));
      expect(presentRow['localArtifacts'], containsPair('uncertain', false));
      expect(hasProblem(presentRow), isFalse);
      final withDownload = diagnostic();
      expect(withDownload['entryWarnings'], isNot(contains(stagingWarning)));
      expect(download.readAsStringSync(), 'private download bytes');

      download.deleteSync();
      final missingRow = await projectEntry(engine, entry);
      expect(missingRow['localArtifacts'], containsPair('uncertain', true));
      expect(hasProblem(missingRow), isTrue);
      final withoutDownload = diagnostic();
      expect(withoutDownload['entryWarnings'], contains(stagingWarning));
      expect(withoutDownload['sessionSlots'], withDownload['sessionSlots']);
      expect(
        jsonEncode(withoutDownload),
        isNot(contains(p.basename(download.path))),
      );
      expect(download.existsSync(), isFalse);
      expect(
        diagnostic(paused: true)['entryWarnings'],
        contains(stagingWarning),
      );

      entry.conflict = conflictReason;
      expect(entry.localHash, entry.baselineHash);
      expect(
        (await projectEntry(engine, entry))['canRecoverLocalVariants'],
        false,
      );
      expect(diagnostic()['entryConflictRecovery'], {
        'action': 'Keep both versions',
        'offered': false,
      });
      expect(diagnostic(paused: true)['entryConflictRecovery'], {
        'action': 'Keep both versions',
        'offered': 'unknown',
      });

      fixture.original.writeAsStringSync(_edit);
      entry.localHash = _digest(fixture.original);
      expect(
        (await projectEntry(engine, entry))['canRecoverLocalVariants'],
        true,
      );
      expect(diagnostic()['entryConflictRecovery'], {
        'action': 'Keep both versions',
        'offered': true,
      });
      expect(fixture.original.readAsStringSync(), _edit);

      entry.expectedPresent = false;
      final editor = fixture.absent.first.$3..writeAsStringSync(_original);
      expect(diagnostic()['entryConflictRecovery'], {
        'action': 'Recover local edits as new files',
        'offered': false,
      });
      editor.writeAsStringSync(_edit);
      expect(
        (await projectEntry(engine, entry))['canRecoverLocalVariants'],
        true,
      );
      expect(diagnostic()['entryConflictRecovery'], {
        'action': 'Recover local edits as new files',
        'offered': true,
      });
      expect(editor.readAsStringSync(), _edit);
      editor.deleteSync();
      final unreadable = Link(editor.path)..createSync(fixture.original.path);
      expect(diagnostic()['entryConflictRecovery'], {
        'action': 'Recover local edits as new files',
        'offered': 'unknown',
      });
      expect(unreadable.targetSync(), fixture.original.path);
    } finally {
      engine.close();
      native.setPaused(true);
    }
  });

  testWidgets('Details diagnostic is available only with its build flag', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.seed(legacy: true, paused: true));
    await _mount(tester, fixture);
    await _openDetails(tester);
    final button = find.widgetWithText(TextButton, 'Editor copy diagnostic');
    if (!editorDiagnosticsEnabled) {
      expect(button, findsNothing);
      expect(await fixture.controller.editorDiagnostic(fixture.row), isNull);
      return;
    }
    expect(button, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(button);
      for (var i = 0; i < 50; i++) {
        await tester.pump();
        if (find.textContaining('"sessionSlots"').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('"sessionSlots"'), findsOneWidget);
    expect(find.textContaining('"dismissWarning": true'), findsOneWidget);
    await tester.runAsync(fixture.controller.stop);
    expect(
      File('${fixture.profile.path}/cloud-mutations').readAsStringSync(),
      '0,0,0',
    );
  });

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

  for (final closeDuringRestart in [false, true]) {
    testWidgets(
      closeDuringRestart
          ? 'Finish receives a provider close reported during worker restart'
          : 'Finish waits for a reopened editor across worker restart',
      (tester) async {
        await tester.runAsync(() async {
          await fixture.seed(mixed: true, legacy: true);
          fixture.markLegacyReleaseIntents();
        });
        await _mount(tester, fixture);
        await _confirmFinish(tester, fixture);
        final (id, owner, file) = fixture.present!;
        final service = DocumentsService(
          fixture.controller,
          AccessStore(fixture.profile),
          hidden: inPhoneFolder,
        );
        addTearDown(service.dispose);
        await tester.runAsync(() async {
          final opened = await service.open(
            'w:${p.basename(file.path)}',
            'r',
            const DocumentsCaller(CallerKind.own),
          );
          final token = opened['token'] as String;
          final fd = opened['fd'] as int;
          void checkToken() {
            expect(file.readAsStringSync(), _edit);
            fixture.read((store) {
              expect(store.operations[id]!.data[providerOpenTokensKey], [
                token,
              ]);
              expect(store.operations[owner], isNotNull);
            });
          }

          Future<void> checkPending() async {
            final pass = await fixture.controller.backgroundRun(
              timeout: const Duration(seconds: 5),
            );
            expect(pass['listed'], isTrue);
            expect(
              libraryStatus(fixture.row),
              contains('still has the editor copy open'),
            );
            expect(fixture.row['finishPending'], isTrue);
            final rows = libraryRows(
              fixture.controller.entries,
              LibraryTab.home,
              {},
            );
            for (final path in [_path, 'Music']) {
              expect(
                rows.singleWhere((row) => row.path == path).attention,
                isTrue,
              );
            }
            checkToken();
          }

          try {
            expect(await fixture.controller.stop(), isTrue);
            if (!closeDuringRestart) {
              await fixture.controller.start();
              fixture.controller.setPaused(false);
              await checkPending();
            }
            expect(File('/proc/self/fd/$fd').readAsStringSync(), _edit);
          } finally {
            NativeRootFs(testNativeLibrary).closeFd(fd);
          }

          // The OS close and the provider callback are separate. Until the
          // callback arrives, the token still gates completion.
          if (!closeDuringRestart) await checkPending();
          final acknowledged = expectLater(service.closed(token), completes);
          if (closeDuringRestart) {
            checkToken();
            await fixture.controller.start();
            fixture.controller.setPaused(false);
          }
          await acknowledged.timeout(const Duration(seconds: 5));
          await _Fixture.until(() => fixture.row['finishPending'] == false);
        });
        expect(file.existsSync(), isFalse);
        expect(fixture.original.readAsStringSync(), _edit);
        fixture.read((store) {
          expect(store.operations[id], isNull);
          expect(store.operations[owner], isNull);
          for (final (missingId, missingOwner, _) in fixture.absent) {
            expect(store.operations[missingId], isNotNull);
            expect(store.operations[missingOwner], isNotNull);
          }
        });
      },
    );
  }

  for (final replaceStaging in [false, true]) {
    testWidgets(
      replaceStaging
          ? 'Interrupted Finish retains recovery records in replacement staging'
          : 'Interrupted Finish resumes in the original shared staging folder',
      (tester) async {
        await tester.runAsync(() async {
          await fixture.seed(mixed: true, legacy: true);
          fixture.markLegacyReleaseIntents();
        });
        await _mount(tester, fixture);
        await _confirmFinish(tester, fixture);
        await tester.runAsync(() async {
          await fixture.controller.stop();
          final cloud = await _cloud();
          final (id, owner, copy) = fixture.present!;
          Future<Map<String, Object?>> tick(
            void Function(SyncEngine)? configure,
          ) async {
            final store = Manifest(fixture.profile);
            final routing = AndroidPhoneRootFs(
              fixture.access.layout,
              testNativeLibrary,
            );
            final engine = SyncEngine(
              store,
              RootTree(
                Directory(store.setting('root')!),
                Directory(store.setting('staging')!),
                routing,
              ),
              cloud,
            );
            try {
              configure?.call(engine);
              await engine.tick();
              return await projectEntry(engine, store.entries[_path]!);
            } finally {
              engine.close();
              routing.setPaused(true);
            }
          }

          String? quarantineName;
          await tick((engine) {
            engine.editing.barrier = (phase, request, _) {
              if (phase != 'before-final-unlink') return;
              final plan = engine.editing
                  .plans(request)
                  .singleWhere((plan) => plan['artifact'] == owner);
              quarantineName = plan['to'] as String;
              throw StateError('Interrupt before final unlink');
            };
          });
          expect(copy.existsSync(), isFalse);
          final quarantine = File(
            '${fixture.access.staging}/${quarantineName!}',
          );
          expect(quarantine.readAsStringSync(), _edit);
          fixture.read((store) {
            final request = store
                .operationsAt(_path)
                .singleWhere((op) => op.kind == 'finish-editing');
            expect(request.phase, 'reclaiming');
            expect(store.operations[id], isNotNull);
            expect(store.operations[owner], isNotNull);
          });

          final staging = Directory(fixture.access.staging);
          final displaced = '${staging.path}-displaced';
          if (replaceStaging) {
            staging.renameSync(displaced);
            staging.createSync();
            File('${staging.path}/.nomedia').createSync();
          }
          final row = await tick(null);
          expect(fixture.original.readAsStringSync(), _edit);
          expect(quarantine.existsSync(), isFalse);
          if (replaceStaging) {
            expect(
              File('$displaced/$quarantineName').readAsStringSync(),
              _edit,
            );
            expect(
              libraryStatus(row),
              contains('The editor staging folder has changed.'),
            );
          }
          fixture.read((store) {
            expect(store.operations[id], replaceStaging ? isNotNull : isNull);
            expect(
              store.operations[owner],
              replaceStaging ? isNotNull : isNull,
            );
            final requests = store
                .operationsAt(_path)
                .where((op) => op.kind == 'finish-editing');
            expect(requests, replaceStaging ? hasLength(1) : isEmpty);
            expect(
              store.entries[_path]!.status,
              contains(
                replaceStaging
                    ? 'The editor staging folder has changed.'
                    : 'Editing finished',
              ),
            );
            for (final (missingId, missingOwner, _) in fixture.absent) {
              expect(store.operations[missingId], isNotNull);
              expect(store.operations[missingOwner], isNotNull);
            }
          });
        });
      },
    );
  }

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

  for (final legacy in [true, false]) {
    final profile = legacy ? 'build-177' : 'current';
    test('restart keeps a displaced $profile edit before unlink', () async {
      await fixture.seed(legacy: legacy, parkFirstCopy: true);
      final (id, owner, file) = fixture.absent.first;
      fixture.parkedCopy.renameSync(file.path);
      fixture.markInterruptedReclaim(id, owner);
      final stage = fixture.access.staging;
      final displacedDir = Directory(stage).renameSync('$stage-original');
      Directory(stage).createSync();
      File('$stage/.nomedia').createSync();
      final displaced = File(p.join(displacedDir.path, p.basename(file.path)))
        ..writeAsStringSync('displaced editor changes');

      await fixture.start();

      expect(displaced.readAsStringSync(), 'displaced editor changes');
      expect(missingEditorClaims(fixture.row), isEmpty);
      fixture.read((store) {
        expect(store.operations[id], isNotNull);
        expect(store.operations[owner], isNotNull);
        expect(store.operations[id]!.data['reclaiming'], isNull);
        expect(store.operations[owner]!.data['releasing'], isNull);
      });
    });
  }

  testWidgets('an interrupted release in the original staging can be cleared', (
    tester,
  ) async {
    await tester.runAsync(fixture.seed);
    final (id, owner, _) = fixture.absent.first;
    fixture.markInterruptedReclaim(id, owner);
    await _mount(tester, fixture);
    expect(
      missingEditorClaims(fixture.row).map((claim) => claim['id']),
      contains(id),
    );
    await _openClear(tester);
    await _confirmClear(tester);
    await tester.runAsync(
      () => _Fixture.until(() => fixture.editorResult.startsWith('Cleared 2')),
    );
    fixture.read((store) {
      expect(store.operations[id], isNull);
      expect(store.operations[owner], isNull);
    });
    expect(fixture.original.readAsStringSync(), _original);
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

  test(
    'a named copy survives restart and grace expiry until provider close',
    () async {
      await fixture.seed(keepNamedCopy: true);
      await fixture.start();
      final (id, owner, file) = fixture.present!;
      const token = 'named-copy-held';
      final opened = await fixture.controller.documentsCommand('open', {
        'working': p.basename(file.path),
        'token': token,
      });
      final native = NativeRootFs(testNativeLibrary);
      final fd = opened['fd'] as int;
      Future<void> pass() async {
        final result = await fixture.controller.backgroundRun(
          timeout: const Duration(seconds: 5),
        );
        expect(result['listed'], isTrue);
        expect(result['timedOut'], isNot(true));
      }

      void expectKept() {
        expect(file.readAsStringSync(), _original);
        fixture.read((store) {
          expect(store.operations[id]!.data[providerOpenTokensKey], [token]);
          expect(store.operations[owner], isNotNull);
        });
      }

      try {
        await fixture.controller.stop();
        fixture.read((store) {
          final work = store.operations[id]!;
          expect(work.data[providerOpenTokensKey], [token]);
          work.data['handedAt'] = DateTime.now()
              .subtract(const Duration(hours: 13))
              .millisecondsSinceEpoch;
          store.save();
        });
        await fixture.controller.start();
        await pass();
        expect(File('/proc/self/fd/$fd').readAsStringSync(), _original);
        expectKept();
      } finally {
        native.closeFd(fd);
      }

      // Closing the OS descriptor alone has not delivered the provider event.
      // This also exercises the durable token where Linux would grant a lease.
      fixture.controller.command(
        'removeOpenedCopy',
        _path,
        sessions: [
          {'id': id},
        ],
      );
      await pass();
      expectKept();

      await fixture.controller.documentsCommand('closed', {'token': token});
      await pass();
      expect(file.existsSync(), isFalse);
      fixture.read((store) {
        expect(store.operations[id], isNull);
        expect(store.operations[owner], isNull);
      });
      expect(fixture.original.readAsStringSync(), _original);
    },
  );

  testWidgets('a new hand-out on a legacy session keeps its own warning', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await fixture.seed(legacy: true, paused: true, parkFirstCopy: true);
      fixture.markLegacyReleaseIntents(slots: [0]);
    });
    await _mount(tester, fixture);
    final (id, owner, file) = fixture.absent.first;
    fixture.parkedCopy.renameSync(file.path);
    const token = 'legacy-held-open';
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
      expect(editorWarningClaims(fixture.row).map((claim) => claim['id']), [
        fixture.absent.last.$1,
      ]);
      await _openDismiss(tester);
      await _confirmDismiss(tester);
      await tester.runAsync(
        () => _Fixture.until(
          () => fixture.editorResult == 'Dismissed 1 editor warning.',
        ),
      );
      await tester.pumpAndSettle();
      expect(_attention(tester, _path), isTrue);
      expect(_attention(tester, 'Music'), isTrue);
      expect(File('/proc/self/fd/$fd').readAsStringSync(), _original);
      fixture.read((store) {
        expect(store.operations[id]!.data[providerOpenTokensKey], [token]);
        expect(store.operations[owner], isNotNull);
      });
    } finally {
      NativeRootFs(testNativeLibrary).closeFd(fd);
    }
    await tester.runAsync(() async {
      await fixture.controller.documentsCommand('closed', {'token': token});
      await _Fixture.until(
        () =>
            workingCopyDetails(fixture.row)
                .contains('Cleanup could not be confirmed'),
      );
    });
    await tester.pumpAndSettle();
    expect(_attention(tester, _path), isFalse);
    expect(_attention(tester, 'Music'), isFalse);
    expect(editorWarningClaims(fixture.row), isEmpty);
    expect(missingEditorClaims(fixture.row), isEmpty);
    fixture.read((store) {
      expect(store.operations[id]!.data[providerClosureUnknownKey], isTrue);
      expect(store.operations[owner]!.data['releasing'], isNotNull);
    });
  });
}
