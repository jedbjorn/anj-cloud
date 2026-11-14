// Spec #52 (phone folders) on the host, acceptance row 1 and the engine
// parts of rows 2 to 6: a temporary folder stands in for Android's shared
// storage, and MappedRootFs (the routing the Android adapter uses) maps the
// top folders Music, Videos and Documents into it while the rest of the root
// stays private.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/cloud_names.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/phone_folder_move.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/platform/native/mapped_root_fs.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);

  late Directory fixture;
  late String base, staging, files;
  late PhoneFolderLayout layout;
  late FakeCloud cloud;
  late Manifest store;
  late SyncEngine engine;
  var open = false;
  late CloudNames names;

  PhoneFolderLayout makeLayout({bool paused = false}) =>
      PhoneFolderLayout(base: base, staging: staging, paused: paused);

  void start({bool paused = false}) {
    layout = makeLayout(paused: paused);
    PhoneFolderLayout.active = layout;
    final tree = RootTree.setup(files, 'phone', MappedRootFs(layout));
    names = CloudNames();
    engine = SyncEngine(store, tree, NamedCloud(cloud, names), names: names)
      ..nameOs = NameOs.android;
    open = true;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-phone-folders-');
    base = '${fixture.path}/storage';
    staging = '$base/Android/media/cloud.anj.test/anj-staging';
    files = '${fixture.path}/files';
    Directory(files).createSync();
    for (final name in ['Music', 'Movies', 'Documents', 'Download']) {
      Directory('$base/$name').createSync(recursive: true);
    }
    cloud = FakeCloud();
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
  });
  tearDown(() {
    if (open) engine.close();
    open = false;
    PhoneFolderLayout.active = null;
    fixture.deleteSync(recursive: true);
  });

  File phone(String path) => File('$base/$path');
  File private(String path) => File('${engine.tree.root.path}/$path');
  bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;
  void write(File file, String text) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text, flush: true);
  }

  Future<void> passes([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await engine.tick();
    }
  }

  group('AC1 mapping and names', () {
    test('the three top folders resolve to the phone folders; Videos is '
        'Movies on disk; the rest of the root stays private', () async {
      start();
      cloud.put('Music/Album/a.mp3', 'song');
      cloud.put('Videos/clip.mp4', 'video');
      cloud.put('Documents/notes.txt', 'notes');
      cloud.put('loose.txt', 'loose');
      await passes();
      expect(phone('Music/Album/a.mp3').readAsStringSync(), 'song');
      expect(phone('Movies/clip.mp4').readAsStringSync(), 'video');
      expect(phone('Documents/notes.txt').readAsStringSync(), 'notes');
      expect(private('loose.txt').readAsStringSync(), 'loose');
      // No private copies of the three, no Videos folder anywhere.
      for (final top in ['Music', 'Videos', 'Documents']) {
        expect(exists('${engine.tree.root.path}/$top'), isFalse, reason: top);
      }
      expect(exists('$base/Videos'), isFalse);
      // The engine and the UI keep the cloud names.
      expect(store.entries['Videos/clip.mp4']?.status, 'current local');
      // A new phone file in Movies goes up under Videos.
      write(phone('Movies/new.mkv'), 'new video');
      await passes();
      expect(utf8.decode(cloud.files['Videos/new.mkv']!), 'new video');
      // The media library is told about each install, exactly.
      expect(
        engine.tree.phoneFolders!.drainMediaScans(),
        containsAll([
          '$base/Music/Album/a.mp3',
          '$base/Movies/clip.mp4',
          '$base/Documents/notes.txt',
        ]),
      );
    });

    test(
      'nothing outside the three phone folders is listed or touched',
      () async {
        start();
        write(phone('Download/other.pdf'), 'not ours');
        write(File('$base/top-level.txt'), 'not ours');
        cloud.put('Download/x.txt', 'cloud folder named Download');
        await passes();
        expect(cloud.files.keys, isNot(contains('Download/other.pdf')));
        expect(cloud.files.keys, isNot(contains('top-level.txt')));
        expect(phone('Download/other.pdf').readAsStringSync(), 'not ours');
        // A cloud folder named like a phone folder stays private.
        expect(
          private('Download/x.txt').readAsStringSync(),
          'cloud folder named Download',
        );
        expect(exists('$base/Download/x.txt'), isFalse);
      },
    );

    test(
      'the character step and case clashes: Where Is My Mind?.mp3 is '
      'Where Is My Mind？.mp3 on the phone and keeps its cloud name',
      () async {
        start();
        cloud.put('Music/Where Is My Mind?.mp3', 'pixies');
        cloud.put('Music/Live: 1999?.mp3', 'live');
        cloud.put('Documents/Notes.txt', 'upper');
        cloud.put('Documents/notes.txt', 'lower');
        cloud.put('loose: name?.txt', 'private root keeps the name');
        await passes();
        expect(
          phone('Music/Where Is My Mind？.mp3').readAsStringSync(),
          'pixies',
        );
        expect(phone('Music/Live： 1999？.mp3').readAsStringSync(), 'live');
        expect(exists('$base/Music/Where Is My Mind?.mp3'), isFalse);
        // The older cloud item keeps the name; the later one gets ` (2)`.
        expect(phone('Documents/Notes.txt').readAsStringSync(), 'upper');
        expect(phone('Documents/notes (2).txt').readAsStringSync(), 'lower');
        expect(
          private('loose: name?.txt').readAsStringSync(),
          'private root keeps the name',
        );
        // An edit on the phone reaches the cloud name.
        write(phone('Music/Where Is My Mind？.mp3'), 'remastered');
        await passes();
        expect(
          utf8.decode(cloud.files['Music/Where Is My Mind?.mp3']!),
          'remastered',
        );
        expect(
          cloud.files.keys,
          isNot(contains('Music/Where Is My Mind？.mp3')),
        );
        expect(
          store.entries['Music/Where Is My Mind？.mp3']?.cloudName,
          'Where Is My Mind?.mp3',
        );
      },
    );

    test(
      'the name rule: phone steps are R3 step 1 and the case clash only',
      () {
        final names = NameRule.localNames(const [
          NameEntry('a<b>:c"d\\e|f?g*.txt', fileId: 1),
          NameEntry('trailing.', fileId: 2),
          NameEntry('CON.txt', fileId: 3),
          NameEntry('Tab\tname', fileId: 4),
          NameEntry('Same.txt', fileId: 5),
          NameEntry('same.txt', fileId: 6),
        ], NameOs.phone);
        expect(names['a<b>:c"d\\e|f?g*.txt'], 'a＜b＞：c＂d＼e｜f？g＊.txt');
        expect(names['trailing.'], 'trailing.');
        expect(names['CON.txt'], 'CON.txt');
        expect(names['Tab\tname'], 'Tab␉name');
        expect(names['Same.txt'], 'Same.txt');
        expect(names['same.txt'], 'same (2).txt');
        // The reverse lookup gives the cloud name back.
        expect(
          NameRule.cloudName('Where Is My Mind？.mp3', const [
            NameEntry('Where Is My Mind?.mp3', fileId: 7),
          ], NameOs.phone),
          'Where Is My Mind?.mp3',
        );
      },
    );

    test('.pending- and .trashed- are not files; .nomedia and .thumbnails '
        'are never created in the cloud', () async {
      start();
      cloud.put('Music/keep.mp3', 'keep');
      await passes();
      write(phone('Music/.pending-1700000000-new.mp3'), 'half written');
      write(phone('Music/.nomedia'), '');
      write(phone('Music/.thumbnails/1.jpg'), 'thumb');
      await passes();
      expect(cloud.files.keys.where((k) => k.contains('.pending-')), isEmpty);
      expect(cloud.files.keys, isNot(contains('Music/.nomedia')));
      expect(cloud.files.keys, isNot(contains('Music/.thumbnails/1.jpg')));
      // The Files app's trash: a rename to .trashed-… is a deletion.
      phone('Music/keep.mp3')
          .renameSync('$base/Music/.trashed-1800000000-keep.mp3');
      await passes();
      expect(cloud.files.keys, isNot(contains('Music/keep.mp3')));
      expect(cloud.files.keys.where((k) => k.contains('.trashed-')), isEmpty);
      expect(isSyncExcluded('Music/.trashed-1-x.mp3'), isTrue);
      expect(isSyncExcluded('loose/.trashed-1-x.mp3'), isFalse);
    });

    test('a cloud .nomedia is synced as an ordinary file', () async {
      start();
      cloud.put('Music/Album/.nomedia', '');
      await passes();
      expect(exists('$base/Music/Album/.nomedia'), isTrue);
      expect(store.entries['Music/Album/.nomedia']?.status, 'current local');
    });
  });

  test('AC6: a phone file over the upload limit stays, says so, and is '
      'never deleted or moved', () async {
    start();
    cloud.uploadLimit = 1024;
    write(phone('Movies/big.mkv'), 'x' * 4096);
    await passes();
    expect(store.entries['Movies/big.mkv'], isNull);
    final row = store.entries['Videos/big.mkv']!;
    expect(row.status, startsWith('Too large to upload yet'));
    expect(phone('Movies/big.mkv').lengthSync(), 4096);
    expect(cloud.files.keys, isNot(contains('Videos/big.mkv')));
    expect(cloud.deletes, 0);
  });

  group('AC5 paused, never deleted', () {
    test('without access the phone folders are neither listed nor touched; '
        'the rest keeps syncing; a deletion made meanwhile syncs only after '
        'access returns', () async {
      start();
      cloud.put('Music/a.mp3', 'a');
      cloud.put('Documents/b.txt', 'b');
      cloud.put('loose.txt', 'loose');
      await passes();
      final routing = engine.tree.phoneFolders!;
      routing.setPaused(true);
      await passes();
      expect(cloud.files.keys, containsAll(['Music/a.mp3', 'Documents/b.txt']));
      expect(cloud.deletes, 0);
      expect(store.entries['Music/a.mp3']?.etag, isNotNull);
      // Everything else keeps syncing.
      write(private('loose.txt'), 'changed');
      cloud.put('Music/c.mp3', 'cloud change while paused');
      await passes();
      expect(utf8.decode(cloud.files['loose.txt']!), 'changed');
      expect(exists('$base/Music/c.mp3'), isFalse);
      // A phone deletion while paused is not seen until access returns.
      phone('Music/a.mp3').deleteSync();
      await passes();
      expect(cloud.files.keys, contains('Music/a.mp3'));
      routing.setPaused(false);
      engine.requestFullVerification();
      await passes();
      expect(cloud.files.keys, isNot(contains('Music/a.mp3')));
      expect(
        phone('Music/c.mp3').readAsStringSync(),
        'cloud change while paused',
      );
      expect(phone('Documents/b.txt').readAsStringSync(), 'b');
    });

    test(
      'a paused start never creates the phone folders or their rows',
      () async {
        Directory('$base/Music').deleteSync();
        start(paused: true);
        cloud.put('Music/a.mp3', 'a');
        cloud.put('loose.txt', 'loose');
        await passes();
        expect(exists('$base/Music'), isFalse);
        expect(private('loose.txt').readAsStringSync(), 'loose');
        expect(exists('${engine.tree.root.path}/Music/a.mp3'), isFalse);
        expect(cloud.files.keys, contains('Music/a.mp3'));
      },
    );
  });

  group('AC3 existing phone contents', () {
    test(
      'unique files upload, identical content links without an upload, '
      'different content keeps both; nothing on the phone is overwritten',
      () async {
        write(phone('Music/unique.mp3'), 'only on the phone');
        write(phone('Music/same.mp3'), 'same bytes');
        write(phone('Documents/diff.txt'), 'phone version');
        cloud.put('Music/same.mp3', 'same bytes');
        cloud.put('Documents/diff.txt', 'cloud version');
        start();
        final versionOfSame = cloud.versions['Music/same.mp3'];
        await passes(4);
        expect(
          utf8.decode(cloud.files['Music/unique.mp3']!),
          'only on the phone',
        );
        expect(cloud.versions['Music/same.mp3'], versionOfSame);
        expect(store.entries['Music/same.mp3']?.status, 'current local');
        expect(store.entries['Music/same.mp3']?.conflict, isNull);
        expect(store.entries['Documents/diff.txt']?.conflict, isNotNull);
        expect(phone('Documents/diff.txt').readAsStringSync(), 'phone version');
        expect(
          utf8.decode(cloud.files['Documents/diff.txt']!),
          'cloud version',
        );
        expect(cloud.uploads, 1);
      },
    );
  });

  group('AC4 moving an existing install', () {
    /// An install from before the feature: Music, Videos and Documents
    /// synchronized in the private root.
    Future<void> privateInstall() async {
      cloud.put('Music/Album/a.mp3', 'song a');
      cloud.put('Music/same.mp3', 'same');
      cloud.put('Music/diff.mp3', 'cloud diff');
      cloud.put('Videos/v.mp4', 'video');
      cloud.put('Documents/edit.txt', 'original');
      final tree = RootTree.setup(files, 'phone', NativeRootFs());
      names = CloudNames();
      engine = SyncEngine(store, tree, NamedCloud(cloud, names), names: names);
      open = true;
      await passes();
      File('${tree.root.path}/Documents/edit.txt')
          .writeAsStringSync('unsynced edit', flush: true);
      engine.close();
      open = false;
      store = Manifest(Directory('${fixture.path}/profile'));
      // The phone already has two of the paths.
      write(phone('Music/same.mp3'), 'same');
      write(phone('Music/diff.mp3'), 'phone diff');
    }

    PhoneFolderMove move() => PhoneFolderMove(
      store,
      MappedRootFs(makeLayout()),
      privateRoot: '$files/anj-cloud',
      layout: makeLayout(),
    );

    test('every file ends up in the phone folders once, the unsynced edit is '
        'uploaded, nothing is downloaded, the private folders are gone; a '
        'kill mid-move resumes', () async {
      await privateInstall();
      final downloads = cloud.completedDownloads;
      // Killed after the first install, before its private copy went.
      final first = move()
        ..debugStep = (step, path) {
          if (step == 'installed') throw const FileSystemException('killed');
        };
      expect(first.run, throwsA(isA<FileSystemException>()));
      expect(store.setting(phoneFolderMoveKey), 'moving');
      // Started again: finishes.
      expect(move().run(), greaterThan(0));
      expect(store.setting(phoneFolderMoveKey), 'done');
      for (final top in ['Music', 'Videos', 'Documents']) {
        expect(exists('$files/anj-cloud/$top'), isFalse, reason: top);
      }
      expect(phone('Music/Album/a.mp3').readAsStringSync(), 'song a');
      expect(phone('Movies/v.mp4').readAsStringSync(), 'video');
      expect(phone('Documents/edit.txt').readAsStringSync(), 'unsynced edit');
      expect(phone('Music/same.mp3').readAsStringSync(), 'same');
      expect(phone('Music/diff.mp3').readAsStringSync(), 'phone diff');
      // No leftovers in shared staging.
      expect(
        Directory(staging).listSync().map((e) => e.path.split('/').last),
        everyElement(anyOf('.nomedia')),
      );
      start();
      await engine.tick();
      // Once, on the first pass after the move.
      expect(engine.message, contains(phoneFoldersMovedNotice));
      await passes(4);
      expect(engine.message, isNot(contains(phoneFoldersMovedNotice)));
      expect(utf8.decode(cloud.files['Documents/edit.txt']!), 'unsynced edit');
      expect(cloud.files.keys, contains('Videos/v.mp4'));
      // The phone's different file meets the cloud's: both kept.
      expect(store.entries['Music/diff.mp3']?.conflict, isNotNull);
      expect(utf8.decode(cloud.files['Music/diff.mp3']!), 'cloud diff');
      // Only the conflict check downloads: nothing is re-downloaded.
      expect(cloud.completedDownloads - downloads, 1);
    });
  });

  test('a rename from private staging into a phone folder crosses volumes '
      'by a verified copy and never replaces a file', () async {
    start();
    await passes();
    final tree = engine.tree;
    final guard = tree.native.releaseGuard();
    final name = 'working-legacy';
    final fd = guard.create(tree.stageFd, name);
    tree.native.closeFd(fd);
    File('${tree.staging.path}/$name').writeAsStringSync('edited', flush: true);
    guard.restore(tree.fd, 'Documents/from-private.txt', tree.stageFd, name);
    expect(phone('Documents/from-private.txt').readAsStringSync(), 'edited');
    expect(exists('${tree.staging.path}/$name'), isFalse);
    write(File('${tree.staging.path}/again'), 'other');
    expect(
      () => guard.restore(
        tree.fd,
        'Documents/from-private.txt',
        tree.stageFd,
        'again',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(phone('Documents/from-private.txt').readAsStringSync(), 'edited');
  });
}
