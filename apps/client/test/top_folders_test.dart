import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/top_folders.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A cloud that records every DELETE (file and folder) and qualifies folder
/// deletion, so a folder delete intent would really be sent.
class _DeleteRecordingCloud extends FakeCloud {
  _DeleteRecordingCloud() {
    foldersQualified = true;
  }

  final deleted = <String>[];

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    deleted.add(path);
    await super.deleteFile(path, etag: etag);
  }

  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    check();
    deleted.add(path);
    bool under(String other) => other == path || other.startsWith('$path/');
    for (final file in [...files.keys].where(under)) {
      remove(file);
    }
    for (final folder in [...directories].where(under)) {
      directories.remove(folder);
      this.versions.remove(folder);
    }
  }
}

/// Spec #34 P7 (decision #150): `Documents`, `Music` and `Videos` are always
/// on the device and never Cloud-only; their deletion here never reaches the
/// cloud; files and folders inside them are deleted as before.
void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _DeleteRecordingCloud cloud;
  late SyncEngine engine;
  late bool closed;
  var now = Duration.zero;

  String rootPath() => '${fixture.path}/files/anj-cloud';
  File local(String path) => File('${rootPath()}/$path');
  Directory folder(String path) => Directory('${rootPath()}/$path');
  String text(String path) => local(path).readAsStringSync();
  String remote(String path) => String.fromCharCodes(cloud.files[path]!);

  SyncEngine open() {
    store = Manifest(Directory('${fixture.path}/profile'));
    tree = RootTree(
      Directory(rootPath()),
      Directory('${fixture.path}/files/.anj-cloud-p7'),
      NativeRootFs(),
    );
    // A fake monotonic clock: deletions under the three wait for losses
    // there to settle (H1), and tests move time on with [settle].
    return SyncEngine(store, tree, cloud)..debugElapsed = () => now;
  }

  /// Moves the fake clock past the settle time for held deletions.
  void settle() => now += engine.topDeleteSettle + const Duration(seconds: 1);

  void close() {
    engine.close();
    closed = true;
  }

  void reopen() {
    close();
    engine = open();
    closed = false;
  }

  /// Synchronized: Documents/a.txt, Documents/Sub/b.txt, and the Cloud-only
  /// Documents/Archive/old.txt (absent here).
  Future<void> populated() async {
    for (final path in [
      'Documents',
      'Documents/Sub',
      'Documents/Archive',
      'Music',
      'Videos',
    ]) {
      await cloud.mkdir(path);
    }
    cloud.put('Documents/a.txt', 'alpha');
    cloud.put('Documents/Sub/b.txt', 'beta');
    cloud.put('Documents/Archive/old.txt', 'archived');
    await engine.tick();
    engine.setRetention('Documents/Archive', Retention.cloud);
    await engine.tick();
    expect(text('Documents/a.txt'), 'alpha');
    expect(text('Documents/Sub/b.txt'), 'beta');
    expect(local('Documents/Archive/old.txt').existsSync(), isFalse);
    expect(store.entries['Documents/Archive/old.txt']!.status, 'cloud-only');
  }

  /// Nothing deleted in the cloud, nothing queued to be.
  void noDeletion() {
    expect(cloud.deleted, isEmpty);
    expect(cloud.moves, isEmpty);
    expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    expect(remote('Documents/a.txt'), 'alpha');
    expect(remote('Documents/Sub/b.txt'), 'beta');
    expect(remote('Documents/Archive/old.txt'), 'archived');
    expect(cloud.directories, containsAll(['Documents', 'Documents/Sub']));
  }

  /// Back as it was, the Cloud-only folder still Cloud-only.
  void restored() {
    expect(
      FileSystemEntity.typeSync(folder('Documents').path, followLinks: false),
      FileSystemEntityType.directory,
    );
    expect(text('Documents/a.txt'), 'alpha');
    expect(text('Documents/Sub/b.txt'), 'beta');
    expect(folder('Documents/Archive').existsSync(), isTrue);
    expect(local('Documents/Archive/old.txt').existsSync(), isFalse);
    expect(engine.retention('Documents/Archive/old.txt'), Retention.cloud);
    expect(store.entries['Documents/Archive/old.txt']!.status, 'cloud-only');
    expect(
      store.entries['Documents/a.txt']!.status,
      anyOf(topFolderRestored, 'current local'),
    );
    expect(
      store.entries.values.where((e) => e.restoring).map((e) => e.path),
      isEmpty,
    );
  }

  // ANJ_CASEFOLD_DIR: a case-insensitive directory (casefold tmpfs or ext4)
  // to run every test on, as macOS and Windows volumes are.
  final casefold = Platform.environment['ANJ_CASEFOLD_DIR'];
  setUp(() {
    closed = false;
    now = Duration.zero;
    fixture = casefold == null
        ? Directory.systemTemp.createTempSync('anj-top-folders-test-')
        : Directory(casefold).createTempSync('anj-top-folders-test-');
    final parent = Directory('${fixture.path}/files')..createSync();
    RootTree.setup(parent.path, 'p7', NativeRootFs()).close();
    cloud = _DeleteRecordingCloud();
    engine = open();
    store.setSetting('retention', 'local');
  });
  tearDown(() {
    if (!closed) engine.close();
    fixture.deleteSync(recursive: true);
  });

  test(
    'rm -rf Documents: re-created with its contents, no DELETE, one notice',
    () async {
      await populated();
      folder('Documents').deleteSync(recursive: true);
      await engine.tick();
      noDeletion();
      restored();
      expect(engine.message, contains('Documents was deleted on this device'));
      // The notice is not repeated once the folder is back.
      await engine.tick();
      expect(engine.message, isNot(contains('Documents was deleted')));
      noDeletion();
    },
  );

  test('every top folder is restored; Music and Videos too', () async {
    await populated();
    cloud.put('Music/song.txt', 'la');
    cloud.put('Videos/clip.txt', 'frame');
    await engine.tick();
    for (final top in topFolders) {
      folder(top).deleteSync(recursive: true);
    }
    await engine.tick();
    noDeletion();
    expect(text('Music/song.txt'), 'la');
    expect(text('Videos/clip.txt'), 'frame');
    expect(remote('Music/song.txt'), 'la');
    expect(remote('Videos/clip.txt'), 'frame');
    expect(
      engine.message,
      contains('Documents, Music and Videos was deleted on this device'),
    );
  });

  test(
    'a restore interrupted by a failed download is never a deletion',
    () async {
      await populated();
      folder('Documents').deleteSync(recursive: true);
      cloud.failDownloads = 1;
      await engine.tick();
      expect(cloud.deleted, isEmpty);
      // One of the two downloads failed; the other came back.
      expect(store.entries.values.where((e) => e.restoring), hasLength(1));
      // Restarted before the next pass: the mark is durable.
      reopen();
      await engine.tick();
      noDeletion();
      restored();
    },
  );

  test('rename away: the renamed copy uploads as a new folder; the original is restored', () async {
    await populated();
    folder('Documents').renameSync('${rootPath()}/Papers');
    await engine.tick();
    await engine.tick();
    noDeletion();
    restored();
    expect(remote('Papers/a.txt'), 'alpha');
    expect(remote('Papers/Sub/b.txt'), 'beta');
    expect(text('Papers/a.txt'), 'alpha');
  });

  test(
    'a case-only rename of Documents is renamed back, not sent as a move',
    () async {
      await populated();
      final downloads = cloud.completedDownloads;
      folder('Documents').renameSync('${rootPath()}/documents');
      await engine.tick();
      await engine.tick();
      noDeletion();
      expect(
        Directory(rootPath()).listSync().map((e) => e.path.split('/').last),
        allOf(contains('Documents'), isNot(contains('documents'))),
      );
      expect(text('Documents/a.txt'), 'alpha');
      expect(text('Documents/Sub/b.txt'), 'beta');
      // The same folder, renamed back: nothing to restore or download.
      expect(cloud.completedDownloads, downloads);
      expect(store.entries.values.where((e) => e.restoring), isEmpty);
      expect(cloud.directories.contains('documents'), isFalse);
      expect(engine.message, isNot(contains('Paused')));
    },
  );

  test(
    'ANJ_CASEFOLD_DIR is case-insensitive when given',
    skip: casefold == null ? 'no casefold directory given' : null,
    () {
      folder('Probe').createSync();
      expect(folder('probe').existsSync(), isTrue);
    },
  );

  test(
    "the cloud renaming Documents in case only never renames it here",
    () async {
      await populated();
      await cloud.move(
        'Documents',
        'documents',
        etag: cloud.versions['Documents']!,
      );
      await engine.tick();
      await engine.tick();
      expect(folder('Documents').existsSync(), isTrue);
      expect(
        Directory(rootPath()).listSync().map((e) => e.path.split('/').last),
        contains('Documents'),
      );
      expect(cloud.deleted, isEmpty);
      expect(engine.message, isNot(contains('Paused')));
      // Moved back in the cloud; nothing renamed or deleted here.
      expect(cloud.moves, ['Documents -> documents', 'documents -> Documents']);
      expect(cloud.directories, contains('Documents'));
      expect(cloud.directories, isNot(contains('documents')));
      expect(remote('Documents/a.txt'), 'alpha');
      expect(text('Documents/a.txt'), 'alpha');
      expect(text('Documents/Sub/b.txt'), 'beta');
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
      expect(
        store.entries.keys.where((k) => k.startsWith('documents')),
        isEmpty,
      );
    },
  );

  test(
    'replaced by a file: moved aside as a conflict copy, never deleted',
    () async {
      await populated();
      folder('Documents').deleteSync(recursive: true);
      local('Documents').writeAsStringSync('not a folder');
      await engine.tick();
      await engine.tick();
      noDeletion();
      restored();
      expect(text('Documents (conflict copy)'), 'not a folder');
      expect(remote('Documents (conflict copy)'), 'not a folder');
    },
  );

  test('replaced by a symbolic link: the link is moved aside, its target untouched', () async {
    await populated();
    final elsewhere = Directory('${fixture.path}/elsewhere')..createSync();
    File('${elsewhere.path}/keep.txt').writeAsStringSync('outside');
    folder('Documents').deleteSync(recursive: true);
    Link('${rootPath()}/Documents').createSync(elsewhere.path);
    await engine.tick();
    await engine.tick();
    noDeletion();
    restored();
    final aside = Link('${rootPath()}/Documents (conflict copy)');
    expect(aside.existsSync(), isTrue);
    expect(aside.targetSync(), elsewhere.path);
    expect(File('${elsewhere.path}/keep.txt').readAsStringSync(), 'outside');
    expect(cloud.files.keys.where((k) => k.contains('keep.txt')), isEmpty);
  });

  test('a second occupant gets the next free conflict-copy name', () async {
    await populated();
    local('Documents (conflict copy)').writeAsStringSync('first');
    await engine.tick();
    folder('Documents').deleteSync(recursive: true);
    local('Documents').writeAsStringSync('second');
    await engine.tick();
    noDeletion();
    expect(text('Documents (conflict copy)'), 'first');
    expect(text('Documents (conflict copy 2)'), 'second');
  });

  test(
    'deleted while the app is stopped: restored at startup, no DELETE',
    () async {
      await populated();
      close();
      folder('Documents').deleteSync(recursive: true);
      engine = open();
      closed = false;
      await engine.tick();
      noDeletion();
      restored();
    },
  );

  test(
    'deleted and re-created empty while stopped: restored at startup',
    () async {
      await populated();
      close();
      folder('Documents').deleteSync(recursive: true);
      folder('Documents').createSync();
      engine = open();
      closed = false;
      await engine.tick();
      noDeletion();
      restored();
    },
  );

  test('deleted during an active pass: the transfer does not re-create it, the next pass restores', () async {
    await populated();
    cloud.put('Documents/a.txt', 'alpha');
    cloud.put('Documents/Sub/b.txt', 'beta');
    var removed = false;
    await engine.tick(
      between: () async {
        if (!removed) {
          removed = true;
          folder('Documents').deleteSync(recursive: true);
        }
        return false;
      },
    );
    expect(removed, isTrue);
    expect(cloud.deleted, isEmpty);
    // Not brought back half-empty by the download into it.
    expect(folder('Documents').existsSync(), isFalse);
    await engine.tick();
    noDeletion();
    restored();
  });

  test(
    'deleted and re-created during an active pass: restored, no DELETE',
    () async {
      await populated();
      cloud.put('Documents/Sub/b.txt', 'beta');
      var removed = false;
      await engine.tick(
        between: () async {
          if (!removed) {
            removed = true;
            folder('Documents').deleteSync(recursive: true);
            folder('Documents').createSync();
          }
          return false;
        },
      );
      await engine.tick();
      await engine.tick();
      noDeletion();
      restored();
    },
  );

  test('a queued deletion of a top folder is never sent', () async {
    await populated();
    final etag = store.entries['Documents']!.etag;
    engine.intent('Documents', 'delete', etag: etag);
    await engine.tick();
    noDeletion();
    expect(text('Documents/a.txt'), 'alpha');
  });

  test(
    'deleting a file or a folder inside Documents still reaches the cloud',
    () async {
      await populated();
      local('Documents/a.txt').deleteSync();
      folder('Documents/Sub').deleteSync(recursive: true);
      await engine.tick();
      // Held until losses under Documents settle (H1).
      expect(cloud.deleted, isEmpty);
      expect(engine.nextLocalDeadline(), isNull, reason: 'no watcher here');
      settle();
      await engine.tick();
      expect(cloud.deleted, containsAll(['Documents/a.txt', 'Documents/Sub']));
      expect(cloud.files.containsKey('Documents/a.txt'), isFalse);
      expect(cloud.files.containsKey('Documents/Sub/b.txt'), isFalse);
      expect(cloud.deleted, isNot(contains('Documents')));
      expect(local('Documents/a.txt').existsSync(), isFalse);
      expect(folder('Documents').existsSync(), isTrue);
      expect(store.entries.values.where((e) => e.restoring), isEmpty);
    },
  );

  test(
    'Delete everywhere and bulk Cloud-only are refused on the three; their '
    'own Cloud row covers only what is inside (decision #163)',
    () async {
      await populated();
      for (final top in topFolders) {
        engine.setRetention(top, Retention.cloud);
        expect(engine.retention(top), Retention.local);
        engine.setRetention(top, Retention.local);
        expect(
          () => engine.requestDelete(top),
          throwsA(isA<FileSystemException>()),
        );
        Map<String, dynamic> target() => {
          'path': top,
          'kind': 'directory',
          'selectionVersion': engine.selectionVersion(store.entries[top]!),
        };
        expect(engine.applyBulk('cloud', [target()])['accepted'], 0);
        expect(engine.applyBulk('delete', [target()])['accepted'], 0);
        expect(engine.retention(top), Retention.local);
      }
      engine.setRetention('Documents/Sub', Retention.cloud);
      expect(engine.retention('Documents/Sub/b.txt'), Retention.cloud);
      await engine.tick();
      expect(local('Documents/Sub/b.txt').existsSync(), isFalse);
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    },
  );

  test(
    'a Cloud row on a top folder makes its contents Cloud-only, never the '
    'folder itself (decision #163)',
    () async {
      await populated();
      store.entries['Documents']!.override = Retention.cloud;
      store.save();
      reopen();
      await engine.tick();
      await engine.tick();
      // Kept: it is the first-sync choice for what is inside Documents.
      expect(store.entries['Documents']!.override, Retention.cloud);
      expect(engine.retention('Documents'), Retention.local);
      expect(engine.retention('Documents/a.txt'), Retention.cloud);
      expect(engine.retention('Documents/Sub/b.txt'), Retention.cloud);
      expect(folder('Documents').existsSync(), isTrue);
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
      expect(cloud.deleted, isEmpty);
    },
  );

  test(
    'switching a top folder to "new and loose files: cloud only" keeps the '
    'folders already inside as they are (#97 re-review N2)',
    () async {
      // An upgraded pre-#97 profile: Music has no row, its albums are Local.
      await populated();
      for (final folder in ['Music/Albums', 'Music/Live']) {
        cloud.directories.add(folder);
        cloud.versions[folder] = '"$folder"';
      }
      cloud.put('Music/Albums/a.flac', 'album');
      cloud.put('Music/Live/b.flac', 'live');
      cloud.put('Music/loose.mp3', 'loose');
      await engine.tick();
      await engine.tick();
      expect(text('Music/Albums/a.flac'), 'album');
      expect(store.entries['Music']!.override, isNull);

      engine.setRetention('Music', Retention.cloud);
      expect(store.entries['Music/Albums']!.override, Retention.local);
      expect(store.entries['Music/Live']!.override, Retention.local);
      await engine.tick();
      await engine.tick();
      expect(text('Music/Albums/a.flac'), 'album');
      expect(text('Music/Live/b.flac'), 'live');
      expect(local('Music/loose.mp3').existsSync(), isFalse);
      expect(engine.retention('Music/New/x.flac'), Retention.cloud);

      // And back: the folders keep their own choice, loose files return.
      engine.setRetention('Music/Live', Retention.cloud);
      engine.setRetention('Music', Retention.local);
      expect(store.entries['Music/Live']!.override, Retention.cloud);
      await engine.tick();
      await engine.tick();
      expect(text('Music/loose.mp3'), 'loose');
      expect(local('Music/Live/b.flac').existsSync(), isFalse);
      expect(cloud.deleted, isEmpty);
    },
  );

  test('a top folder missing from the cloud is created there again, not deleted here', () async {
    await populated();
    cloud.directories.remove('Videos');
    cloud.versions.remove('Videos');
    await engine.tick();
    await engine.tick();
    expect(folder('Videos').existsSync(), isTrue);
    expect(cloud.directories, contains('Videos'));
    expect(cloud.deleted, isEmpty);
  });

  test(
    'with the folder watcher: rm -rf Documents is restored, no DELETE',
    skip: Platform.isLinux || Platform.isMacOS
        ? null
        : 'Linux and macOS only (inotify, FSEvents)',
    () async {
      await populated();
      engine.watcherSettings = const WatcherSettings(
        quiet: Duration(milliseconds: 150),
        maxDelay: Duration(seconds: 2),
      );
      await engine.startWatching();
      (engine.watcher! as LocalWatcher)
        ..quiet = const Duration(milliseconds: 150)
        ..maxDelay = const Duration(seconds: 2);
      await engine.tick();
      folder('Documents').deleteSync(recursive: true);
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (!local('Documents/Sub/b.txt').existsSync()) {
        expect(DateTime.now().isBefore(end), isTrue, reason: 'not restored');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
      await engine.tick();
      noDeletion();
      restored();
    },
  );

  /// A stable filesystem modelled on the tmpfs fixture (the stable-volume
  /// seam): folder birth times are reported only where trusted (SC-074).
  void trustedFilesystem() {
    final fs = tree.native as NativeRootFs;
    fs.debugVolume(fsid: 0x5eed);
    addTearDown(fs.debugVolume);
  }

  const birthSkip =
      'Linux and Android only: no folder birth time on macOS (APFS never '
      'reuses inode numbers) or Windows (the file id differs)';
  final birthOnly = Platform.isLinux || Platform.isAndroid ? null : birthSkip;

  test('deleted and created again on the same file number (ext4, f2fs): its '
      'birth time tells; restored, never deleted (SC-074)', skip: birthOnly,
      () async {
    trustedFilesystem();
    await populated();
    await engine.tick();
    final row = store.entries['Documents']!;
    final birth = row.localBirth;
    expect(birth, isNotNull, reason: 'the scan reports a folder birth time');
    folder('Documents').deleteSync(recursive: true);
    folder('Documents').createSync();
    // ext4 and f2fs hand the new folder the old number: the row now names
    // it, and only the birth time recorded before differs.
    final fresh = tree.statItem('Documents')!;
    expect(fresh.birth, isNot(birth));
    row
      ..localIdentity = fresh.identity
      ..localBirth = birth;
    await engine.tick();
    settle();
    await engine.tick();
    await engine.tick();
    noDeletion();
    restored();
  });

  test('a top folder with no birth time on record falls back to its file '
      'number alone (an earlier profile, or a filesystem without one)',
      skip: birthOnly, () async {
    trustedFilesystem();
    await populated();
    await engine.tick();
    store.entries['Documents']!.localBirth = null;
    store.save();
    await engine.tick();
    // Still recorded again from the next scan, and nothing restored.
    expect(store.entries['Documents']!.localBirth, isNotNull);
    expect(cloud.deleted, isEmpty);
  });

  test('a never-paired profile keeps the three as plain folders', () async {
    cloud.online = false;
    folder('Music').deleteSync();
    await engine.tick();
    expect(folder('Music').existsSync(), isTrue);
    expect(cloud.deleted, isEmpty);
  });

  group('a recursive delete removes the contents first (H1)', () {
    test('a pass between the contents and the folder sends nothing', () async {
      await populated();
      local('Documents/a.txt').deleteSync();
      folder('Documents/Sub').deleteSync(recursive: true);
      await engine.tick();
      expect(cloud.deleted, isEmpty);
      // Losses keep arriving while the delete runs: still held.
      now += const Duration(seconds: 8);
      folder('Documents/Archive').deleteSync(recursive: true);
      await engine.tick();
      now += const Duration(seconds: 8);
      await engine.tick();
      expect(cloud.deleted, isEmpty);
      folder('Documents').deleteSync(recursive: true);
      await engine.tick();
      settle();
      await engine.tick();
      await engine.tick();
      noDeletion();
      restored();
    });

    test(
      'a deletion queued offline is taken back when Documents goes',
      () async {
        await populated();
        cloud.online = false;
        local('Documents/a.txt').deleteSync();
        await engine.tick();
        expect(
          store.operations.values.where((o) => o.kind == 'delete'),
          hasLength(1),
        );
        folder('Documents').deleteSync(recursive: true);
        settle();
        cloud.online = true;
        await engine.tick();
        settle();
        await engine.tick();
        noDeletion();
        restored();
      },
    );

    test(
      'the top folder is checked afresh before a held deletion is sent',
      () async {
        await populated();
        local('Documents/a.txt').deleteSync();
        await engine.tick();
        expect(cloud.deleted, isEmpty);
        // Gone after this pass's scan read it, before the dispatch.
        settle();
        var removed = false;
        engine.debugElapsed = () {
          if (!removed &&
              engine.manifest.operations.values.any(
                (o) => o.kind == 'delete',
              )) {
            removed = true;
            folder('Documents').deleteSync(recursive: true);
          }
          return now;
        };
        await engine.tick();
        expect(removed, isTrue);
        expect(cloud.deleted, isEmpty);
        await engine.tick();
        noDeletion();
        restored();
      },
    );

    test(
      'with the folder watcher, contents due before the folder send nothing',
      skip: Platform.isLinux || Platform.isMacOS
          ? null
          : 'Linux and macOS only (inotify, FSEvents)',
      () async {
        await populated();
        engine.watcherSettings = const WatcherSettings(
          quiet: Duration(milliseconds: 150),
          maxDelay: Duration(seconds: 2),
        );
        await engine.startWatching();
        final watcher = engine.watcher! as LocalWatcher
          ..quiet = const Duration(milliseconds: 150)
          ..maxDelay = const Duration(seconds: 2);
        await engine.tick();
        local('Documents/a.txt').deleteSync();
        folder('Documents/Sub').deleteSync(recursive: true);
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (store.operations.values.where((o) => o.kind == 'delete').length <
                2 &&
            cloud.deleted.isEmpty) {
          expect(DateTime.now().isBefore(end), isTrue, reason: 'not seen');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // A partial pass holds a removal for the quiet period first
          // (decision #140, spec #33 I1) on the same fake clock.
          now += const Duration(milliseconds: 200);
          await engine.tick();
        }
        expect(cloud.deleted, isEmpty);
        // The folder goes last, and its event is not due yet when the held
        // deletions are: the dispatch's fresh check finds it gone.
        watcher.quiet = const Duration(seconds: 30);
        watcher.maxDelay = const Duration(seconds: 60);
        folder('Documents').deleteSync(recursive: true);
        settle();
        await engine.tick();
        expect(cloud.deleted, isEmpty);
        watcher
          ..quiet = const Duration(milliseconds: 150)
          ..maxDelay = const Duration(seconds: 2);
        while (!local('Documents/Sub/b.txt').existsSync()) {
          expect(DateTime.now().isBefore(end), isTrue, reason: 'not restored');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
        }
        settle();
        await engine.tick();
        noDeletion();
        restored();
      },
    );

    test(
      'a deletion inside settles, then is sent; the deadline wakes the worker',
      skip: Platform.isLinux || Platform.isMacOS
          ? null
          : 'Linux and macOS only (inotify, FSEvents)',
      () async {
        await populated();
        await engine.startWatching();
        await engine.tick();
        local('Documents/a.txt').deleteSync();
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (store.operations.values
                .where((o) => o.kind == 'delete')
                .isEmpty &&
            cloud.deleted.isEmpty) {
          expect(DateTime.now().isBefore(end), isTrue, reason: 'not seen');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // A partial pass holds a removal for the quiet period first
          // (decision #140, spec #33 I1) on the same fake clock.
          now += const Duration(milliseconds: 200);
          await engine.tick();
        }
        await engine.tick();
        expect(cloud.deleted, isEmpty);
        final due = engine.nextLocalDeadline();
        expect(due, isNotNull);
        expect(due!, lessThanOrEqualTo(engine.topDeleteSettle));
        settle();
        expect(engine.nextLocalDeadline(), Duration.zero);
        await engine.tick();
        expect(cloud.deleted, ['Documents/a.txt']);
        expect(local('Documents/a.txt').existsSync(), isFalse);
      },
    );
  });

  test(
    'a folder that cannot be made a folder pauses the pass and infers nothing',
    () async {
      await populated();
      folder('Documents').deleteSync(recursive: true);
      // A FIFO cannot be moved aside by the root boundary.
      final made = Process.runSync('mkfifo', ['${rootPath()}/Documents']);
      if (made.exitCode != 0) return;
      await engine.tick();
      expect(
        engine.message,
        contains('"Documents" in your AnJ Cloud folder is not a folder'),
      );
      expect(engine.message, contains('no deletions are inferred'));
      expect(cloud.deleted, isEmpty);
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    },
  );
}
