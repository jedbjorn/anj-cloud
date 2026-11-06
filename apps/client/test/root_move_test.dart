// Linux `move-root` (Feature #19, after spec #34): moving a profile's synced
// folder by rename only. Every home, desktop and profile here is a temporary
// directory; no test reads or writes the real home folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_identity.dart';
import 'package:anj_cloud/core/local/root_move.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/linux/xdg_root_placement.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _Crash implements Exception {
  const _Crash(this.step);
  final String step;
}

void main() {
  if (skipSuite('Move root (Linux)', linuxOnly('rename(2) layouts'))) {
    return;
  }
  final native = NativeRootFs(testNativeLibrary);
  late Directory fixture;
  late Directory home;
  late Directory desktop;
  late Directory profile;
  const id = 'abcdef0123456789abcdef0123456789';

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-move-root-');
    home = Directory(p.join(fixture.resolveSymbolicLinksSync(), 'home'))
      ..createSync();
    desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
    profile = Directory(p.join(fixture.resolveSymbolicLinksSync(), 'profile'));
  });
  tearDown(() {
    native.debugVolume();
    fixture.deleteSync(recursive: true);
  });

  XdgRootPlacement placement() =>
      XdgRootPlacement(environment: {'HOME': home.path});

  /// A profile paired with the picker before spec #34: root
  /// `<parent>/anj-cloud`, staging the sibling `.anj-cloud-<profileId>`, a
  /// few synced files and no desktop shortcut recorded.
  void pickerProfile(String parent) {
    Directory(parent).createSync(recursive: true);
    final tree = RootTree.setup(parent, id, native);
    final identity = native.rootInfo(tree.fd).identity;
    tree.close();
    File(p.join(tree.root.path, 'Documents', 'a.txt')).writeAsStringSync('a');
    File(p.join(tree.root.path, 'Music', 'b.mp3')).writeAsStringSync('bb');
    Directory(p.join(tree.root.path, 'Photos', 'x'))
        .createSync(recursive: true);
    profile.createSync(recursive: true);
    final store = Manifest(profile);
    store.setSetting('profileId', id);
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
    store.setSetting('rootIdentity', identity);
    store.close();
  }

  T withStore<T>(T Function(Manifest store) action) {
    final store = Manifest(profile);
    try {
      return action(store);
    } finally {
      store.close();
    }
  }

  String? setting(String key) => withStore((s) => s.setting(key));

  RootMover mover(
    Manifest store, {
    void Function(String)? step,
    List<String> knownRoots = const [],
  }) => RootMover(
    store,
    profile.path,
    native,
    desktop: desktop.path,
    keep: placement().keptDirectories(),
    knownRoots: knownRoots,
    step: step,
  );

  Future<Map<String, Object?>> move(
    String target, {
    void Function(String)? step,
    List<String> knownRoots = const [],
  }) async {
    final store = Manifest(profile);
    try {
      return await mover(
        store,
        step: step,
        knownRoots: knownRoots,
      ).move(target);
    } finally {
      store.close();
    }
  }

  Future<Map<String, Object?>?> resume() async {
    final store = Manifest(profile);
    try {
      return await mover(store).resumeAtStart();
    } finally {
      store.close();
    }
  }

  /// Inode of [root] and of every item under it, by relative path.
  Map<String, int> inodes(String root) => {
    '.': _inode(root),
    for (final e in Directory(root).listSync(recursive: true))
      p.relative(e.path, from: root): _inode(e.path),
  };

  /// The state after a finished the VM host-style move.
  void expectHaloMoved(String target, Map<String, int> before) {
    final settings = withStore(
      (s) => {
        for (final k in [
          'root',
          'staging',
          'stagingMovedFrom',
          rootMoveSetting,
          'desktopShortcut',
        ])
          k: s.setting(k),
      },
    );
    expect(settings['root'], target);
    expect(settings['staging'], p.join(profile.path, 'staging'));
    expect(settings['stagingMovedFrom'], isNull);
    expect(settings[rootMoveSetting], isNull);
    final link = p.join(desktop.path, 'AnJ Cloud');
    expect(settings['desktopShortcut'], 'created:$link');
    expect(Link(link).targetSync(), target);
    expect(inodes(target), before);
    expect(File(p.join(target, 'Documents', 'a.txt')).readAsStringSync(), 'a');
    // Only the new folder and the desktop are left in the home folder.
    expect(home.listSync().map((e) => p.basename(e.path)).toSet(), {
      'anj-cloud',
      'Desktop',
    });
    // The next start accepts the root as matched.
    withStore((s) {
      final tree = RootTree(
        Directory(target),
        Directory(settings['staging']!),
        native,
      );
      try {
        expect(acceptRoot(s, tree).outcome, RootOutcome.matched);
      } finally {
        tree.close();
      }
    });
  }

  group('the VM host layout (~/AnJ Cloud/anj-cloud)', () {
    late String from;
    late String target;
    setUp(() {
      pickerProfile(p.join(home.path, 'AnJ Cloud'));
      from = p.join(home.path, 'AnJ Cloud', 'anj-cloud');
      target = p.join(home.path, 'anj-cloud');
    });

    test('moves by rename, staging into the profile, shortcut made, old '
        'parent removed, identity still matches', () async {
      final before = inodes(from);
      final identity = setting('rootIdentity');
      final outcome = await move(target);
      expect(outcome['moved'], isTrue);
      expect(outcome['from'], from);
      expect(outcome['to'], target);
      expect(outcome['removed'], [p.join(home.path, 'AnJ Cloud')]);
      expect(
        outcome['stagingFrom'],
        p.join(home.path, 'AnJ Cloud', '.anj-cloud-$id'),
      );
      expectHaloMoved(target, before);
      expect(setting('rootIdentity'), identity);
    });

    test('a stable fsid identity (btrfs/ext4 form) still matches', () async {
      native.debugVolume(fsid: 0x1234abcd);
      // Re-record the identity in the stable form.
      withStore((s) {
        final fd = native.openRoot(from);
        s.setSetting('rootIdentity', native.rootInfo(fd).identity);
        native.closeFd(fd);
      });
      expect(setting('rootIdentity'), startsWith('f'));
      final before = inodes(from);
      await move(target);
      expectHaloMoved(target, before);
    });

    test('a re-run after success changes nothing', () async {
      await move(target);
      final outcome = await move(target);
      expect(outcome['moved'], isFalse);
      expect(setting('root'), target);
    });

    test('a foreign desktop entry is never replaced', () async {
      final foreign = File(p.join(desktop.path, 'AnJ Cloud'))
        ..writeAsStringSync('mine');
      await move(target);
      expect(setting('desktopShortcut'), 'foreign:${foreign.path}');
      expect(foreign.readAsStringSync(), 'mine');
      expect(setting('root'), target);
    });

    test('a shortcut this profile made to the old folder follows it', () async {
      final link = Link(p.join(desktop.path, 'AnJ Cloud'))..createSync(from);
      withStore((s) => s.setSetting('desktopShortcut', 'created:${link.path}'));
      final outcome = await move(target);
      expect(outcome['desktopShortcut'], 'updated:${link.path}');
      expect(link.targetSync(), target);
      expect(setting('desktopShortcut'), 'created:${link.path}');
    });

    test('staging with finished copies and a kept copy moves whole; every '
        'recorded path follows it', () async {
      final old = p.join(home.path, 'AnJ Cloud', '.anj-cloud-$id');
      // A download installed by hard link keeps its staging name (#123).
      final rootFile = p.join(from, 'Documents', 'a.txt');
      final alias = p.join(old, 'download-1');
      Process.runSync('ln', [rootFile, alias]);
      final kept = p.join(old, 'preserved-1');
      File(kept).writeAsStringSync('kept bytes');
      File(p.join(old, 'stray-1')).writeAsStringSync('no record');
      withStore((s) {
        s.operations['dl-1'] = Operation(
          'dl-1',
          'artifact',
          'Documents/a.txt',
          phase: 'complete',
          staged: alias,
        )..data = {'role': 'download', 'name': 'download-1'};
        s.operations['keep-1'] =
            Operation(
                'keep-1',
                'retained',
                'Music/b.mp3',
                phase: 'complete',
                staged: kept,
              )
              ..data = {
                'nested': {
                  'copies': [kept],
                },
              };
        s.entries['Music/b.mp3'] = Entry('Music/b.mp3', ItemKind.file)
          ..preservedCopies = [kept]
          ..remoteCopy = kept;
        s.save();
      });
      final aliasInode = _inode(alias);
      final before = inodes(from);
      final outcome = await move(target);
      expect(outcome['moved'], isTrue);
      expectHaloMoved(target, before);
      final staging = p.join(profile.path, 'staging');
      expect(_inode(p.join(staging, 'download-1')), aliasInode);
      expect(_inode(p.join(target, 'Documents', 'a.txt')), aliasInode);
      expect(
        File(p.join(staging, 'preserved-1')).readAsStringSync(),
        'kept bytes',
      );
      expect(File(p.join(staging, 'stray-1')).existsSync(), isTrue);
      withStore((s) {
        expect(s.operations['dl-1']!.staged, p.join(staging, 'download-1'));
        expect(s.operations['keep-1']!.staged, p.join(staging, 'preserved-1'));
        expect(s.operations['keep-1']!.data['nested'], {
          'copies': [p.join(staging, 'preserved-1')],
        });
        expect(s.entries['Music/b.mp3']!.preservedCopies, [
          p.join(staging, 'preserved-1'),
        ]);
        expect(
          s.entries['Music/b.mp3']!.remoteCopy,
          p.join(staging, 'preserved-1'),
        );
        // No row names the old staging folder any more.
        for (final table in ['settings', 'entries', 'operations']) {
          final rows = s.db.select('SELECT * FROM $table');
          for (final row in rows) {
            expect('${row.values}', isNot(contains(old)), reason: table);
          }
        }
      });
    });

    test('an old parent holding other files is kept', () async {
      File(p.join(home.path, 'AnJ Cloud', 'notes.txt')).writeAsStringSync('n');
      final outcome = await move(target);
      expect(outcome['removed'], isEmpty);
      expect(
        File(p.join(home.path, 'AnJ Cloud', 'notes.txt')).existsSync(),
        isTrue,
      );
    });

    group('refusals change nothing', () {
      late Map<String, String?> settings;
      late List<String> tree;
      List<String> listing() => [
        for (final e in fixture.listSync(recursive: true))
          if (!p.basename(e.path).startsWith('manifest.sqlite'))
            p.relative(e.path, from: fixture.path),
      ]..sort();
      Map<String, String?> allSettings() => withStore(
        (s) => {
          for (final row in s.db.select('SELECT key, value FROM settings'))
            row['key'] as String: row['value'] as String?,
        },
      );
      setUp(() {
        settings = allSettings();
        tree = listing();
      });
      Future<void> refused(
        String target,
        Matcher message, {
        List<String>? known,
      }) async {
        await expectLater(
          move(target, knownRoots: known ?? const []),
          throwsA(
            isA<RootMoveRefused>()
                .having((e) => e.message, 'message', message)
                .having((e) => e.journalKept, 'journalKept', isFalse),
          ),
        );
        expect(allSettings(), settings);
        expect(listing(), tree);
      }

      test('the target exists', () async {
        Directory(target).createSync();
        tree = listing();
        await refused(target, contains('already exists'));
      });

      test('the target is inside the root', () async {
        await refused(p.join(from, 'Photos', 'anj-cloud'), contains('inside'));
      });

      test(
        'the target overlaps another profile or the profile itself',
        () async {
          await refused(
            target,
            contains('overlaps'),
            known: [p.join(home.path, 'anj-cloud', 'other')],
          );
          await refused(
            p.join(profile.path, 'anj-cloud'),
            contains('overlaps'),
          );
        },
      );

      test('staging holds unfinished work', () async {
        final staged = p.join(home.path, 'AnJ Cloud', '.anj-cloud-$id', 'u-1');
        File(staged).writeAsStringSync('x');
        withStore((s) {
          s.operations['up-1'] = Operation(
            'up-1',
            'upload',
            'Documents/a.txt',
            staged: staged,
          );
          s.save();
        });
        settings = allSettings();
        tree = listing();
        await refused(
          target,
          allOf(
            contains('1 operations: upload'),
            contains('Open AnJ Cloud, let it finish syncing'),
          ),
        );
      });

      test('the staging place in the profile is in use', () async {
        final inUse = Directory(p.join(profile.path, 'staging'))..createSync();
        File(p.join(inUse.path, 'other')).writeAsStringSync('o');
        tree = listing();
        await refused(target, contains('already in use'));
      });

      test('the root is not the recorded one', () async {
        withStore((s) => s.setSetting('rootIdentity', '1:2'));
        settings = allSettings();
        await refused(target, contains('not the one this profile recorded'));
      });

      test('a target not named anj-cloud', () async {
        await refused(p.join(home.path, 'Cloud'), contains('named anj-cloud'));
      });

      // ANJ_TEST_OTHER_VOLUME names a folder on another filesystem or
      // btrfs subvolume (with TMPDIR on btrfs: a subvolume beside it).
      test('another filesystem or btrfs subvolume', () async {
        final shm = Directory(
          Platform.environment['ANJ_TEST_OTHER_VOLUME'] ?? '/dev/shm',
        );
        if (!shm.existsSync()) {
          markTestSkipped('needs /dev/shm (a second filesystem)');
          return;
        }
        final other = shm.createTempSync('anj-move-root-');
        try {
          if (native.identity(native.openRoot(other.path)).split(':')[0] ==
              native.identity(native.openRoot(home.path)).split(':')[0]) {
            markTestSkipped('${shm.path} is the fixture filesystem');
            return;
          }
          await refused(
            p.join(other.path, 'anj-cloud'),
            contains('same filesystem'),
          );
          expect(other.listSync(), isEmpty);
        } finally {
          other.deleteSync(recursive: true);
        }
      });
    });

    const steps = [
      'journaled',
      'stagingMoved',
      'stagingSwitched',
      'renamed',
      'committed',
      'parentCleaned',
    ];
    for (final crash in steps) {
      test('a crash after "$crash": the root setting or the journal always '
          'names the folder; a re-run completes', () async {
        final before = inodes(from);
        await expectLater(
          move(
            target,
            step: (s) {
              if (s == crash) throw _Crash(s);
            },
          ),
          throwsA(isA<_Crash>()),
        );
        final root = setting('root')!;
        expect(
          Directory(root).existsSync() || setting(rootMoveSetting) != null,
          isTrue,
        );
        if (!Directory(root).existsSync()) {
          final journal =
              jsonDecode(setting(rootMoveSetting)!) as Map<String, dynamic>;
          expect(Directory(journal['to'] as String).existsSync(), isTrue);
        }
        expect((await move(target))['moved'], isTrue);
        expectHaloMoved(target, before);
      });

      test('a crash after "$crash": the next app start completes or '
          'undoes', () async {
        final before = inodes(from);
        await expectLater(
          move(
            target,
            step: (s) {
              if (s == crash) throw _Crash(s);
            },
          ),
          throwsA(isA<_Crash>()),
        );
        final outcome = await resume();
        if (const {
          'journaled',
          'stagingMoved',
          'stagingSwitched',
        }.contains(crash)) {
          // The folder was not renamed: undone. A staging move that began
          // is finished (the P3 place), one that did not is not started.
          expect(outcome!['undone'], isTrue);
          expect(setting('root'), from);
          expect(setting(rootMoveSetting), isNull);
          expect(inodes(from), before);
          expect(Directory(target).existsSync(), isFalse);
          final staging = setting('staging')!;
          expect(
            staging,
            crash == 'journaled'
                ? p.join(home.path, 'AnJ Cloud', '.anj-cloud-$id')
                : p.join(profile.path, 'staging'),
          );
          expect(Directory(staging).existsSync(), isTrue);
          // A later run moves the folder.
          expect((await move(target))['moved'], isTrue);
          expectHaloMoved(target, before);
        } else {
          expect(outcome!['moved'], isTrue);
          expectHaloMoved(target, before);
        }
      });
    }
  });

  group('nested layout (~/anj-cloud/anj-cloud)', () {
    late String from;
    late String target;
    setUp(() {
      pickerProfile(p.join(home.path, 'anj-cloud'));
      target = p.join(home.path, 'anj-cloud');
      from = p.join(target, 'anj-cloud');
    });

    void expectNestedMoved(Map<String, int> before) {
      expect(setting('root'), target);
      expect(setting('staging'), p.join(profile.path, 'staging'));
      expect(setting(rootMoveSetting), isNull);
      expect(inodes(target), before);
      expect(home.listSync().map((e) => p.basename(e.path)).toSet(), {
        'anj-cloud',
        'Desktop',
      });
      expect(Link(p.join(desktop.path, 'AnJ Cloud')).targetSync(), target);
      withStore((s) {
        final tree = RootTree(
          Directory(target),
          Directory(s.setting('staging')!),
          native,
        );
        try {
          expect(acceptRoot(s, tree).outcome, RootOutcome.matched);
        } finally {
          tree.close();
        }
      });
    }

    test('moves through a temporary name; the emptied parent goes', () async {
      final before = inodes(from);
      final outcome = await move(target);
      expect(outcome['moved'], isTrue);
      expect(outcome['removed'], isEmpty);
      expectNestedMoved(before);
    });

    test('anything else in the parent is refused and listed', () async {
      final extra = File(p.join(target, 'stray.txt'))..writeAsStringSync('s');
      final hidden = Directory(p.join(target, '.other'))..createSync();
      await expectLater(
        move(target),
        throwsA(
          isA<RootMoveRefused>().having((e) => e.entries, 'entries', [
            hidden.path,
            extra.path,
          ]),
        ),
      );
      expect(setting('root'), from);
      expect(setting(rootMoveSetting), isNull);
      expect(Directory(from).existsSync(), isTrue);
    });

    test('an entry appearing during the move puts the folder back', () async {
      await expectLater(
        move(
          target,
          step: (s) {
            if (s == 'renamedAside') {
              File(p.join(target, 'late.txt')).writeAsStringSync('l');
            }
          },
        ),
        throwsA(
          isA<RootMoveRefused>().having((e) => e.journalKept, 'kept', isFalse),
        ),
      );
      expect(setting('root'), from);
      expect(setting(rootMoveSetting), isNull);
      expect(Directory(from).existsSync(), isTrue);
      expect(File(p.join(target, 'late.txt')).existsSync(), isTrue);
    });

    const steps = [
      'journaled',
      'stagingMoved',
      'stagingSwitched',
      'renamedAside',
      'parentRemoved',
      'renamed',
      'committed',
      'parentCleaned',
    ];
    for (final crash in steps) {
      test('a crash after "$crash": a re-run completes', () async {
        final before = inodes(from);
        await expectLater(
          move(
            target,
            step: (s) {
              if (s == crash) throw _Crash(s);
            },
          ),
          throwsA(isA<_Crash>()),
        );
        expect(
          Directory(setting('root')!).existsSync() ||
              setting(rootMoveSetting) != null,
          isTrue,
        );
        expect((await move(target))['moved'], isTrue);
        expectNestedMoved(before);
      });

      test('a crash after "$crash": the next app start completes or '
          'undoes', () async {
        final before = inodes(from);
        await expectLater(
          move(
            target,
            step: (s) {
              if (s == crash) throw _Crash(s);
            },
          ),
          throwsA(isA<_Crash>()),
        );
        final outcome = (await resume())!;
        if (const {
          'journaled',
          'stagingMoved',
          'stagingSwitched',
        }.contains(crash)) {
          expect(outcome['undone'], isTrue);
          expect(setting('root'), from);
          expect(setting(rootMoveSetting), isNull);
          expect(inodes(from), before);
        } else {
          expect(outcome['moved'], isTrue);
          expectNestedMoved(before);
        }
      });
    }
  });

  group('review findings (PR #102)', () {
    late String from;
    late String target;
    late String old;
    late String kept;
    setUp(() {
      pickerProfile(p.join(home.path, 'AnJ Cloud'));
      from = p.join(home.path, 'AnJ Cloud', 'anj-cloud');
      target = p.join(home.path, 'anj-cloud');
      old = p.join(home.path, 'AnJ Cloud', '.anj-cloud-$id');
      kept = p.join(old, 'preserved-1');
      File(kept).writeAsStringSync('recovery bytes');
      withStore((s) {
        s.entries['Music/b.mp3'] = Entry('Music/b.mp3', ItemKind.file)
          ..preservedCopies = [kept];
        s.save();
      });
    });

    Future<void> crashAfterStagingMoved() => expectLater(
      move(
        target,
        step: (s) {
          if (s == 'stagingMoved') throw _Crash(s);
        },
      ),
      throwsA(isA<_Crash>()),
    );

    // R1: the staging rename was made, the switch was not, and a start that
    // used the old setting made the old staging folder again (RootTree
    // createSync). The journal is never dropped with staging moved away.
    test('R1: staging moved, old place made again empty: a re-run finishes '
        'and every copy is still recorded where it is', () async {
      await crashAfterStagingMoved();
      RootTree(Directory(from), Directory(setting('staging')!), native).close();
      expect(Directory(old).existsSync(), isTrue);
      final before = inodes(from);
      expect((await move(target))['moved'], isTrue);
      expectHaloMoved(target, before);
      final moved = p.join(profile.path, 'staging', 'preserved-1');
      expect(withStore((s) => s.entries['Music/b.mp3']!.preservedCopies), [
        moved,
      ]);
      expect(File(moved).readAsStringSync(), 'recovery bytes');
    });

    test('R1: old place made again with files: the journal stays, nothing '
        'is dropped, and the app start keeps sync stopped', () async {
      await crashAfterStagingMoved();
      Directory(old).createSync();
      File(p.join(old, 'written-later')).writeAsStringSync('w');
      await expectLater(
        move(target),
        throwsA(
          isA<RootMoveRefused>()
              .having((e) => e.journalKept, 'journalKept', isTrue)
              .having((e) => e.message, 'message', contains('holds files')),
        ),
      );
      expect(setting(rootMoveSetting), isNotNull);
      expect(setting('staging'), old);
      expect(
        File(p.join(profile.path, 'staging', 'preserved-1')).existsSync(),
        isTrue,
      );
      // The app start cannot finish it either: no worker, no folder made.
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: placement(),
      );
      try {
        await controller.initialize();
        expect(controller.rootMovePending, isTrue);
        expect(controller.status, SyncStatus.attention);
        expect(controller.message, contains('Sync stays stopped'));
        await controller.start();
        expect(controller.rootMovePending, isTrue);
      } finally {
        await controller.stop();
        controller.dispose();
      }
      expect(setting(rootMoveSetting), isNotNull);
      expect(setting('staging'), old);
      expect(File(p.join(old, 'written-later')).existsSync(), isTrue);
      // Once the stray file is moved into the new place, a re-run finishes.
      File(p.join(old, 'written-later'))
          .renameSync(p.join(profile.path, 'staging', 'written-later'));
      expect((await move(target))['moved'], isTrue);
      expect(setting('staging'), p.join(profile.path, 'staging'));
    });

    test('L1: archived excluded-path history does not block the move; its '
        'paths follow the folder', () async {
      final archived = p.join(old, 'upload-x');
      File(archived).writeAsStringSync('x');
      withStore((s) {
        s.operations['ex-1'] =
            Operation(
                'ex-1',
                'excluded-operation',
                'Music/x.tmp',
                phase: 'retained-history',
                staged: archived,
              )
              ..data = {
                'policyVersion': 1,
                'original': {'kind': 'upload', 'staged': archived},
              };
        s.save();
      });
      expect((await move(target))['moved'], isTrue);
      final now = p.join(profile.path, 'staging', 'upload-x');
      withStore((s) {
        final op = s.operations['ex-1']!;
        expect(op.staged, now);
        expect((op.data['original'] as Map)['staged'], now);
      });
    });

    test('L1: an archived excluded entry naming a kept copy does not block '
        'the move; its paths follow the folder (review R5)', () async {
      withStore((s) {
        final e = Entry('Videos/x.mkv', ItemKind.file)
          ..preservedCopies = [kept];
        s.operations['ex-2'] = Operation('ex-2', 'excluded-entry', e.path)
          ..data = {'policyVersion': 1, 'entry': e.toJson()};
        s.save();
      });
      expect((await move(target))['moved'], isTrue);
      final now = p.join(profile.path, 'staging', 'preserved-1');
      withStore((s) {
        final entry = s.operations['ex-2']!.data['entry'] as Map;
        expect(entry['preservedCopies'], [now]);
      });
      expect(File(now).readAsStringSync(), 'recovery bytes');
    });

    test('L2: a link that cannot be retargeted is reported stale, never '
        'created', () async {
      final link = Link(p.join(desktop.path, 'AnJ Cloud'))..createSync(from);
      withStore((s) => s.setSetting('desktopShortcut', 'created:${link.path}'));
      // An entry the user owns at the old fixed temporary name is untouched,
      // and a link made under a fresh name replaces only this link.
      final userFile = File(p.join(desktop.path, '.AnJ Cloud.anj-cloud-move'))
        ..writeAsStringSync('user file');
      final outcome = await move(target);
      expect(outcome['desktopShortcut'], 'updated:${link.path}');
      expect(link.targetSync(), target);
      expect(userFile.readAsStringSync(), 'user file');
      expect(desktop.listSync().map((e) => p.basename(e.path)).toSet(), {
        'AnJ Cloud',
        '.AnJ Cloud.anj-cloud-move',
      });
    });

    test(
      'L2: an unwritable desktop leaves the link stale and says so',
      () async {
        final link = Link(p.join(desktop.path, 'AnJ Cloud'))..createSync(from);
        withStore(
          (s) => s.setSetting('desktopShortcut', 'created:${link.path}'),
        );
        Process.runSync('chmod', ['a-w', desktop.path]);
        try {
          final outcome = await move(target);
          expect(outcome['moved'], isTrue);
          expect(outcome['desktopShortcut'], 'stale:${link.path}');
          expect(link.targetSync(), from);
        } finally {
          Process.runSync('chmod', ['u+w', desktop.path]);
        }
      },
    );
  });

  test('an emptied user directory is never removed', () async {
    // A localized Documents folder named by user-dirs.dirs.
    Directory(p.join(home.path, '.config')).createSync();
    File(p.join(home.path, '.config', 'user-dirs.dirs'))
        .writeAsStringSync('XDG_DOCUMENTS_DIR="\$HOME/Dokumente"\n');
    expect(
      placement().keptDirectories(),
      containsAll([home.path, p.join(home.path, 'Dokumente')]),
    );
    pickerProfile(p.join(home.path, 'Dokumente'));
    final outcome = await move(p.join(home.path, 'anj-cloud'));
    expect(outcome['moved'], isTrue);
    expect(outcome['removed'], isEmpty);
    expect(Directory(p.join(home.path, 'Dokumente')).existsSync(), isTrue);
  });

  test(
    'the app start finishes an interrupted move before it uses the root',
    () async {
      pickerProfile(p.join(home.path, 'AnJ Cloud'));
      final target = p.join(home.path, 'anj-cloud');
      await expectLater(
        move(
          target,
          step: (s) {
            if (s == 'renamed') throw _Crash(s);
          },
        ),
        throwsA(isA<_Crash>()),
      );
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: placement(),
      );
      try {
        await controller.initialize();
        expect(controller.root, target);
        expect(setting(rootMoveSetting), isNull);
        expect(Link(p.join(desktop.path, 'AnJ Cloud')).targetSync(), target);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );
}

int _inode(String path) {
  final result = Process.runSync('stat', ['-c', '%i', path]);
  return int.parse((result.stdout as String).trim());
}
