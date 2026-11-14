// Spec #52 (phone folders) on the host, acceptance row 1 and the engine
// parts of rows 2 to 6: a temporary folder stands in for Android's shared
// storage, and MappedRootFs (the routing the Android adapter uses) maps the
// top folders Music, Videos and Documents into it while the rest of the root
// stays private.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/cloud_names.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/phone_folder_move.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/core/sync/worker.dart';
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

  /// Every shared-storage access of the routing boundary (review round 2),
  /// checked against spec #52: nothing outside the three phone folders and
  /// the staging folder, never a listing of the volume.
  List<(String, String)> spy(MappedRootFs fs) {
    final seen = <(String, String)>[];
    fs.debugSharedAccess = (operation, path) => seen.add((operation, path));
    return seen;
  }

  void expectInsidePhoneFolders(List<(String, String)> seen) {
    final stagingPath = staging.substring(base.length + 1);
    expect(seen, isNotEmpty);
    for (final (operation, path) in seen) {
      final first = path.split('/').first.toLowerCase();
      final allowed =
          (operation == 'open' && path.isEmpty) ||
          path == stagingPath ||
          path.startsWith('$stagingPath/') ||
          (path.isNotEmpty && {'music', 'movies', 'documents'}.contains(first));
      expect(allowed, isTrue, reason: '$operation "$path"');
    }
  }

  /// Android's casefolded shared storage on a case-sensitive host: the
  /// stored spelling a lookup of [phone] would resolve to.
  String? casefolded(String phone) {
    if (Directory('$base/$phone').existsSync()) return phone;
    for (final item in Directory(base).listSync()) {
      final name = item.path.split('/').last;
      if (item is Directory && name.toLowerCase() == phone.toLowerCase()) {
        return name;
      }
    }
    return null;
  }

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
        final seen = spy(engine.tree.native as MappedRootFs);
        write(phone('Download/other.pdf'), 'not ours');
        write(File('$base/top-level.txt'), 'not ours');
        cloud.put('Download/x.txt', 'cloud folder named Download');
        cloud.put('Music/m.mp3', 'm');
        await passes();
        expectInsidePhoneFolders(seen);
        expect(seen.where((a) => a.$1 == 'list' && a.$2.isEmpty), isEmpty);
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

    test('across restarts (Android stops the app on every change of '
        'access): a file deleted while paused is a deletion once access is '
        'back', () async {
      start();
      cloud.put('Music/a.mp3', 'a');
      cloud.put('Music/b.mp3', 'b');
      await passes();
      engine.close();
      open = false;
      store = Manifest(Directory('${fixture.path}/profile'));
      start(paused: true);
      await passes();
      phone('Music/a.mp3').deleteSync();
      await passes();
      expect(cloud.files.keys, contains('Music/a.mp3'));
      engine.close();
      open = false;
      store = Manifest(Directory('${fixture.path}/profile'));
      start();
      await passes(4);
      expect(cloud.files.keys, isNot(contains('Music/a.mp3')));
      expect(exists('$base/Music/a.mp3'), isFalse);
      expect(phone('Music/b.mp3').readAsStringSync(), 'b');
      expect(cloud.completedDownloads, 2);
    });

    test('a download interrupted by Android stopping the app waits, intact, '
        'while paused; everything else keeps syncing', () async {
      start();
      cloud.put('Music/a.mp3', 'a');
      await passes();
      // A download of a new version, staged and about to be renamed in.
      final staged = engine.artifacts.reserve('Music/a.mp3', 'download');
      staged.writeAsStringSync('new a', flush: true);
      engine.artifacts.complete(staged, hash: 'x');
      engine.artifacts.record(staged)!.data['installing'] = 'Music/a.mp3';
      store.save();
      final name = staged.path.split('/').last;
      expect(name, startsWith(sharedStagingTag));
      expect(File('$staging/$name').existsSync(), isTrue);
      engine.close();
      open = false;
      store = Manifest(Directory('${fixture.path}/profile'));
      start(paused: true);
      cloud.put('loose.txt', 'loose');
      await passes();
      expect(private('loose.txt').readAsStringSync(), 'loose');
      expect(
        store.operations.values.where((o) => o.data['installing'] != null),
        hasLength(1),
      );
      expect(File('$staging/$name').readAsStringSync(), 'new a');
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

  test('resumed while running, with the watcher and event-driven hashing '
      '(Android): nothing present is restored or downloaded again', () async {
    layout = makeLayout();
    PhoneFolderLayout.active = layout;
    final tree = RootTree.setup(
      files,
      'phone',
      MappedRootFs(layout, null, 'Linux errno', const Duration(minutes: 15)),
    );
    names = CloudNames();
    engine = SyncEngine(store, tree, NamedCloud(cloud, names), names: names)
      ..nameOs = NameOs.android;
    open = true;
    await engine.startWatching();
    write(phone('Music/a.mp3'), 'a');
    cloud.put('Music/b.mp3', 'b');
    await passes(4);
    expect(cloud.files.keys, contains('Music/a.mp3'));
    final downloads = cloud.completedDownloads;
    // Access revoked: Android stops the app; it starts again paused.
    engine.close();
    store = Manifest(Directory('${fixture.path}/profile'));
    final paused = RootTree(
      Directory('$files/anj-cloud'),
      tree.staging,
      MappedRootFs(
        makeLayout(paused: true),
        null,
        'Linux errno',
        const Duration(minutes: 15),
      ),
    );
    engine = SyncEngine(store, paused, NamedCloud(cloud, names), names: names)
      ..nameOs = NameOs.android;
    await engine.startWatching();
    await passes();
    // Deleted by another app while paused.
    phone('Music/a.mp3').deleteSync();
    await passes();
    expect(cloud.files.keys, contains('Music/a.mp3'));
    // Access granted while it runs (Android does not stop the app then).
    final tree2 = paused;
    tree2.phoneFolders!.setPaused(false);
    await engine.restartWatchingAfterPhoneFolders();
    engine.requestFullVerification();
    await passes(4);
    expect(tree2.phoneFolders!.paused, isFalse);
    expect(
      store.entries.values.where((e) => e.restoring).map((e) => e.path),
      isEmpty,
    );
    for (var i = 0; i < 30 && cloud.files.containsKey('Music/a.mp3'); i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await engine.tick();
    }
    // ignore: avoid_print
    print('DEBUG ${store.entries['Music/a.mp3']?.status} ${engine.message}');
    expect(cloud.files.keys, isNot(contains('Music/a.mp3')));
    expect(exists('$base/Music/a.mp3'), isFalse);
    expect(cloud.completedDownloads, downloads);
  });

  test('access back in the middle of a pass that began paused: what that '
      'pass did not list is neither restored nor deleted; the next pass '
      'sends the deletion', () async {
    start();
    cloud.put('Music/a.mp3', 'a');
    cloud.put('Music/b.mp3', 'b');
    await passes();
    final downloads = cloud.completedDownloads;
    final routing = engine.tree.phoneFolders!..setPaused(true);
    await passes();
    phone('Music/a.mp3').deleteSync();
    var resumed = false;
    await engine.tick(
      between: () async {
        if (!resumed) {
          resumed = true;
          routing.setPaused(false);
        }
        return false;
      },
    );
    expect(resumed, isTrue);
    expect(exists('$base/Music/a.mp3'), isFalse);
    expect(cloud.completedDownloads, downloads);
    expect(cloud.files.keys, contains('Music/a.mp3'));
    await passes(4);
    expect(cloud.files.keys, isNot(contains('Music/a.mp3')));
    expect(exists('$base/Music/a.mp3'), isFalse);
    expect(cloud.completedDownloads, downloads);
  });

  test('finding 1: a phone folder renamed in case only keeps its contents; '
      'its name comes back, nothing is deleted or downloaded again', () async {
    start();
    cloud.put('Music/Album/a.mp3', 'a');
    cloud.put('Videos/v.mp4', 'v');
    cloud.put('Documents/d.txt', 'd');
    await passes();
    final fs = engine.tree.native as MappedRootFs
      ..debugStoredSpelling = casefolded;
    final seen = spy(fs);
    final downloads = cloud.completedDownloads;
    Directory('$base/Music').renameSync('$base/music');
    Directory('$base/Movies').renameSync('$base/movies');
    Directory('$base/Documents').renameSync('$base/DOCUMENTS');
    await passes(4);
    for (final name in ['music', 'movies', 'DOCUMENTS']) {
      expect(exists('$base/$name'), isFalse, reason: name);
    }
    expect(phone('Music/Album/a.mp3').readAsStringSync(), 'a');
    expect(phone('Movies/v.mp4').readAsStringSync(), 'v');
    expect(phone('Documents/d.txt').readAsStringSync(), 'd');
    // Killed between the two renames, parked in the staging folder: finished
    // before the next listing.
    Directory('$base/Music').renameSync('$staging/.anj-top-Music');
    await passes(3);
    expect(phone('Music/Album/a.mp3').readAsStringSync(), 'a');
    expect(exists('$staging/.anj-top-Music'), isFalse);
    // Only the three folders' own names and the staging folder: never a
    // listing of the volume, never a temporary name at its top.
    expectInsidePhoneFolders(seen);
    expect(seen.where((a) => a.$1 == 'list' && a.$2.isEmpty), isEmpty);
    expect(
      Directory(base).listSync().map((e) => e.path.split('/').last),
      everyElement(isNot(startsWith('.anj-'))),
    );
    expect(cloud.deletes, 0);
    expect(cloud.completedDownloads, downloads);
    expect(
      cloud.files.keys,
      containsAll(['Music/Album/a.mp3', 'Videos/v.mp4', 'Documents/d.txt']),
    );
    expect(store.entries.values.where((e) => e.restoring), isEmpty);
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

    /// A private install holding [cloudFiles] (cloud path -> text), all
    /// synchronized, plus [localOnly] never-synchronized private files.
    Future<void> privateNames(
      Map<String, String> cloudFiles, {
      Map<String, String> localOnly = const {},
    }) async {
      cloudFiles.forEach(cloud.put);
      final tree = RootTree.setup(files, 'phone', NativeRootFs());
      names = CloudNames();
      engine = SyncEngine(store, tree, NamedCloud(cloud, names), names: names);
      open = true;
      await passes();
      localOnly.forEach((path, text) {
        File('${tree.root.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text, flush: true);
      });
      engine.close();
      open = false;
      store = Manifest(Directory('${fixture.path}/profile'));
    }

    test('finding 2: access granted while the app runs moves the private '
        'folders first, then resumes them, without a restart', () async {
      await privateInstall();
      final downloads = cloud.completedDownloads;
      start(paused: true);
      final events = <Map>[];
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        engine,
        (event) => events.add(event as Map),
        interval: const Duration(milliseconds: 50),
      );
      final done = loop.run(input.stream);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(store.setting(phoneFolderMoveKey), isNot('done'));
      expect(File('$files/anj-cloud/Music/Album/a.mp3').existsSync(), isTrue);
      input.add({'action': 'phoneFolders', 'paused': false});
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) &&
          (store.setting(phoneFolderMoveKey) != 'done' ||
              cloud.files['Documents/edit.txt'] == null ||
              utf8.decode(cloud.files['Documents/edit.txt']!) !=
                  'unsynced edit')) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final moveState = store.setting(phoneFolderMoveKey);
      final pausedAfter = engine.tree.phoneFolders!.paused;
      input.add({'action': 'stop'});
      await done;
      await input.close();
      open = false; // The loop closed the engine.
      expect(moveState, 'done');
      expect(pausedAfter, isFalse);
      expect(phone('Music/Album/a.mp3').readAsStringSync(), 'song a');
      expect(phone('Movies/v.mp4').readAsStringSync(), 'video');
      for (final top in ['Music', 'Videos', 'Documents']) {
        expect(exists('$files/anj-cloud/$top'), isFalse, reason: top);
      }
      expect(utf8.decode(cloud.files['Documents/edit.txt']!), 'unsynced edit');
      expect(
        events
            .where((e) => e['event'] == 'mediaScan')
            .expand((e) => e['paths']),
        contains('$base/Music/Album/a.mp3'),
      );
      // Only the conflict check of the phone's different diff.mp3.
      expect(cloud.completedDownloads - downloads, 1);
      expect(cloud.deletes, 0);
    });

    test('finding 3: the move gives every item its phone name (#202) and '
        'keeps its cloud name: no EPERM loop, no clash, nothing deleted or '
        'uploaded again', () async {
      final cloudFiles = {
        'Music/Where Is My Mind?.mp3': 'pixies',
        'Music/Live: 1999?/track.mp3': 'live',
        'Music/a<b>c.mp3': 'angle',
        'Music/say "hi".mp3': 'quote',
        'Music/x|y*z.mp3': 'pipe star',
        'Documents/Notes.txt': 'upper',
        'Documents/notes.txt': 'lower',
        'Documents/日本語のメモ.txt': 'japanese',
        'Documents/🎵 playlist.txt': 'emoji',
        'Documents/Already?.txt': 'question',
        'Documents/Already？.txt': 'fullwidth',
      };
      await privateNames(cloudFiles, localOnly: {'Music/new?.mp3': 'mine'});
      final downloads = cloud.completedDownloads;
      final before = Map.of(cloud.versions);
      move().run();
      expect(store.setting(phoneFolderMoveKey), 'done');
      expect(phone('Music/Where Is My Mind？.mp3').readAsStringSync(), 'pixies');
      expect(phone('Music/Live： 1999？/track.mp3').readAsStringSync(), 'live');
      expect(phone('Music/a＜b＞c.mp3').readAsStringSync(), 'angle');
      expect(phone('Music/say ＂hi＂.mp3').readAsStringSync(), 'quote');
      expect(phone('Music/x｜y＊z.mp3').readAsStringSync(), 'pipe star');
      expect(phone('Music/new？.mp3').readAsStringSync(), 'mine');
      expect(phone('Documents/日本語のメモ.txt').readAsStringSync(), 'japanese');
      expect(phone('Documents/🎵 playlist.txt').readAsStringSync(), 'emoji');
      // The case clash and the fullwidth clash: the rule's names, all kept.
      final docs = {
        for (final f in Directory('$base/Documents').listSync())
          f.path.split('/').last: (f as File).readAsStringSync(),
      };
      final expected = NameRule.localNames([
        for (final path in cloudFiles.keys.where(
          (k) => k.startsWith('Documents/'),
        ))
          NameEntry(
            path.substring('Documents/'.length),
            fileId: cloud.fileIds[path],
          ),
      ], NameOs.phone);
      for (final MapEntry(key: cloudName, value: local) in expected.entries) {
        expect(docs[local], cloudFiles['Documents/$cloudName'], reason: local);
      }
      expect(docs.length, 6);
      expect(
        Directory('$files/anj-cloud/Music').existsSync() ||
            Directory('$files/anj-cloud/Documents').existsSync(),
        isFalse,
      );
      // Rows moved with their items and kept their cloud names.
      expect(
        store.entries['Music/Where Is My Mind？.mp3']?.cloudName,
        'Where Is My Mind?.mp3',
      );
      expect(store.entries.containsKey('Music/Where Is My Mind?.mp3'), isFalse);
      start();
      await passes(4);
      expect(cloud.deletes, 0);
      expect(cloud.completedDownloads, downloads);
      for (final path in cloudFiles.keys) {
        expect(cloud.versions[path], before[path], reason: '$path untouched');
      }
      // No item reached the cloud under a phone name; the file the cloud never
      // had arrives under the name it had in the old app (review round 2).
      expect(
        cloud.files.keys.where(
          (k) => k.contains('？') && !k.contains('Already'),
        ),
        isEmpty,
      );
      expect(utf8.decode(cloud.files['Music/new?.mp3']!), 'mine');
      expect(store.entries.values.where((e) => e.conflict != null), isEmpty);
    });

    for (final withRow in [false, true]) {
      test('review round 2: a never-synchronized old file keeps the name the '
          'user knew in the cloud (${withRow ? 'with' : 'without'} an old '
          'unsynced row)', () async {
        await privateNames(
          {'Music/kept.mp3': 'kept'},
          localOnly: {'Music/new?.mp3': 'mine', 'Music/Live: 1999?/a.mp3': 'a'},
        );
        if (withRow) {
          store.entries['Music/new?.mp3'] = Entry(
            'Music/new?.mp3',
            ItemKind.file,
          );
          store.save();
        }
        move().run();
        expect(phone('Music/new？.mp3').readAsStringSync(), 'mine');
        expect(phone('Music/Live： 1999？/a.mp3').readAsStringSync(), 'a');
        start();
        await passes(4);
        expect(utf8.decode(cloud.files['Music/new?.mp3']!), 'mine');
        expect(utf8.decode(cloud.files['Music/Live: 1999?/a.mp3']!), 'a');
        expect(cloud.files.keys.where((k) => k.contains('？')), isEmpty);
        expect(phone('Music/new？.mp3').readAsStringSync(), 'mine');
        expect(cloud.deletes, 0);
      });
    }

    for (final kill in ['conflict-installed', 'recorded']) {
      test('finding 4: killed at "$kill", the move keeps exactly one '
          'conflict copy', () async {
        await privateInstall();
        // The phone already holds other bytes where the unsynced edit goes.
        write(phone('Documents/edit.txt'), 'the phone version');
        var once = false;
        final first = move()
          ..debugStep = (step, path) {
            if (step == kill && path == 'Documents/edit.txt' && !once) {
              once = true;
              throw const FileSystemException('killed');
            }
          };
        expect(first.run, throwsA(isA<FileSystemException>()));
        expect(once, isTrue);
        move().run();
        move().run();
        final copies = Directory('$base/Documents')
            .listSync()
            .map((e) => e.path.split('/').last)
            .where((n) => n.startsWith('edit.txt.conflict-'))
            .toList();
        expect(copies, hasLength(1));
        expect(
          File('$base/Documents/${copies.single}').readAsStringSync(),
          'unsynced edit',
        );
        expect(
          phone('Documents/edit.txt').readAsStringSync(),
          'the phone version',
        );
        expect(
          File('$files/anj-cloud/Documents/edit.txt').existsSync(),
          isFalse,
        );
      });
    }

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
