import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/first_sync.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/first_sync_screen.dart';

import 'package:anj_cloud/ui/app.dart';

import 'fakes.dart';
import 'layout_fixtures.dart';

/// The first-sync screen (decisions #118, #163; spec #28 A3): Documents,
/// Music and Videos always exist; what is kept inside them (each subfolder,
/// and their loose files as one row) and any other top-level folder is the
/// user's choice, written through the per-folder storage rows. Android starts
/// with nothing kept, desktops with everything.
void main() {
  const mib = 1024 * 1024;
  FirstSyncListing sample() => FirstSyncListing.fromListings(
    const [
      RemoteItem('Documents', ItemKind.directory, '"d"'),
      RemoteItem('Music', ItemKind.directory, '"m"'),
      RemoteItem('Photos', ItemKind.directory, '"p"'),
      RemoteItem('notes.txt', ItemKind.file, '"n"', size: 1000),
      RemoteItem('.DS_Store', ItemKind.file, '"x"', size: 9),
    ],
    {'Documents': 5 * mib, 'Music': 2 * mib, 'Photos': 3 * mib},
    {
      'Documents': (
        items: const [
          RemoteItem('Documents/Taxes', ItemKind.directory, '"t"'),
          RemoteItem('Documents/Receipts', ItemKind.directory, '"r"'),
          RemoteItem('Documents/a.pdf', ItemKind.file, '"a"', size: 600),
          RemoteItem('Documents/b.pdf', ItemKind.file, '"b"', size: 400),
          RemoteItem('Documents/.DS_Store', ItemKind.file, '"y"', size: 9),
        ],
        sizes: const {'Documents/Taxes': 4 * mib, 'Documents/a.pdf': 600},
      ),
      'Music': (
        items: const [RemoteItem('Music/Albums', ItemKind.directory, '"al"')],
        sizes: const {'Music/Albums': 2 * mib},
      ),
    },
  );

  test('listing: subfolders and loose files of the top folders, other '
      'folders, root files, exclusions', () {
    final listing = sample();
    // All three top folders, each with its own row: Music has no loose
    // files and Videos is not on the server yet (review H1).
    expect(listing.tops, ['Documents', 'Music', 'Videos']);
    expect(listing.choices.map((c) => (c.path, c.label, c.size, c.top)), [
      ('Documents/Receipts', 'Receipts', null, 'Documents'),
      ('Documents/Taxes', 'Taxes', 4 * mib, 'Documents'),
      ('Documents', 'New and loose files in Documents', 1000, 'Documents'),
      ('Music/Albums', 'Albums', 2 * mib, 'Music'),
      ('Music', 'New and loose files in Music', 0, 'Music'),
      ('Videos', 'New and loose files in Videos', 0, 'Videos'),
      ('Photos', 'Photos', 3 * mib, null),
    ]);
    expect(listing.choices[2].files, 2);
    expect(listing.choices[4].files, 0);
    expect(listing.rootFiles, 1);
    expect(listing.rootFilesSize, 1000);
    expect(listing.sizesComplete, isFalse);
    expect(listing.total, 1000 + 4 * mib + 1000 + 2 * mib + 3 * mib);
    expect(listing.defaultKeep(FirstSyncDefault.cloud), isEmpty);
    expect(listing.defaultKeep(FirstSyncDefault.local), listing.paths.toSet());
    expect(listing.downloadSize({}), 1000);
    expect(listing.downloadSize({'Music/Albums'}), 1000 + 2 * mib);
    expect(formatSize(0), '0 bytes');
    expect(formatSize(1536), '1.5 KiB');
    expect(formatSize(3 * mib), '3.0 MiB');
  });

  group('engine after the choice', () {
    late Directory fixture;
    late RootTree tree;
    late Manifest store;
    late FakeCloud cloud;
    late SyncEngine engine;
    setUp(() {
      fixture = Directory.systemTemp.createTempSync('anj-first-sync-');
      final parent = Directory('${fixture.path}/files')..createSync();
      tree = RootTree.setup(parent.path, 'first-sync', NativeRootFs());
      store = Manifest(Directory('${fixture.path}/profile'));
      cloud = FakeCloud();
      engine = SyncEngine(store, tree, cloud);
      for (final folder in [
        'Documents',
        'Documents/Taxes',
        'Music',
        'Music/Albums',
        'Photos',
      ]) {
        cloud.directories.add(folder);
        cloud.versions[folder] = '"$folder"';
      }
      cloud.put('Documents/Taxes/2025.pdf', 'tax');
      cloud.put('Documents/loose.txt', 'loose');
      cloud.put('Music/Albums/song.flac', 'song');
      cloud.put('Photos/a.jpg', 'photo');
      cloud.put('notes.txt', 'notes');
    });
    tearDown(() {
      engine.close();
      fixture.deleteSync(recursive: true);
    });
    File local(String path) => File('${tree.root.path}/$path');
    // The listing the screen gets, built the real way (review H1).
    final paths = sample().paths;

    test('Android default (nothing kept): the top folders exist, their '
        'contents stay in the cloud; a ticked folder downloads', () async {
      applyFirstSyncChoice(store, paths, {'Music/Albums'});
      expect(store.setting(firstSyncSetting), 'done');
      // Every top folder has an explicit row (review H1).
      for (final top in ['Documents', 'Music', 'Videos']) {
        expect(store.entries[top]!.override, Retention.cloud, reason: top);
      }
      await engine.tick();
      expect(Directory('${tree.root.path}/Documents').existsSync(), isTrue);
      expect(Directory('${tree.root.path}/Music').existsSync(), isTrue);
      expect(Directory('${tree.root.path}/Videos').existsSync(), isTrue);
      expect(local('Music/Albums/song.flac').readAsStringSync(), 'song');
      expect(local('notes.txt').readAsStringSync(), 'notes');
      expect(local('Documents/Taxes/2025.pdf').existsSync(), isFalse);
      expect(local('Documents/loose.txt').existsSync(), isFalse);
      expect(local('Photos/a.jpg').existsSync(), isFalse);
      // The top folder itself is never Cloud-only (P7); what is inside it
      // follows its row (#163), later subfolders included.
      expect(engine.retention('Documents'), Retention.local);
      expect(engine.retention('Documents/loose.txt'), Retention.cloud);
      expect(engine.retention('Documents/Later/x.txt'), Retention.cloud);
      expect(engine.retention('Music/Albums/song.flac'), Retention.local);

      // Added later elsewhere: a new album in Music (which had no loose
      // files) and a first folder in Videos (absent at pairing) stay in the
      // cloud; a new top-level folder follows #29 (review H1).
      for (final folder in [
        'Music/NewAlbum',
        'Videos',
        'Videos/Holiday',
        'Later',
      ]) {
        cloud.directories.add(folder);
        cloud.versions[folder] = '"$folder"';
      }
      cloud.put('Music/NewAlbum/new.flac', 'new');
      cloud.put('Videos/Holiday/clip.mp4', 'clip');
      cloud.put('Later/new.txt', 'later');
      await engine.tick();
      expect(local('Later/new.txt').readAsStringSync(), 'later');
      expect(local('Music/NewAlbum/new.flac').existsSync(), isFalse);
      expect(local('Videos/Holiday/clip.mp4').existsSync(), isFalse);
      expect(engine.retention('Music/NewAlbum/new.flac'), Retention.cloud);
      expect(local('Documents/loose.txt').existsSync(), isFalse);
    });

    test('desktop default (everything kept): everything downloads', () async {
      applyFirstSyncChoice(store, paths, paths.toSet());
      await engine.tick();
      for (final top in ['Documents', 'Music', 'Videos']) {
        expect(store.entries[top]!.override, Retention.local, reason: top);
      }
      expect(local('Documents/Taxes/2025.pdf').readAsStringSync(), 'tax');
      expect(local('Documents/loose.txt').readAsStringSync(), 'loose');
      expect(local('Music/Albums/song.flac').readAsStringSync(), 'song');
      expect(local('Photos/a.jpg').readAsStringSync(), 'photo');
    });

    test('the top folder\'s "new and loose files" choice switches both ways '
        'later from the library (decision #163, M1)', () async {
      applyFirstSyncChoice(store, paths, {});
      await engine.tick();
      expect(local('Documents/loose.txt').existsSync(), isFalse);
      // Keep on this device: loose files and later folders download.
      engine.setRetention('Documents', Retention.local);
      await engine.tick();
      await engine.tick();
      expect(local('Documents/loose.txt').readAsStringSync(), 'loose');
      // A subfolder's own row still wins.
      expect(local('Documents/Taxes/2025.pdf').existsSync(), isFalse);
      // Back to cloud only: released again, the folder itself stays.
      engine.setRetention('Documents', Retention.cloud);
      await engine.tick();
      await engine.tick();
      expect(local('Documents/loose.txt').existsSync(), isFalse);
      expect(Directory('${tree.root.path}/Documents').existsSync(), isTrue);
      expect(engine.retention('Documents'), Retention.local);
      expect(cloud.deletes, 0);
    });

    test('refuses deeper, excluded or file paths and changes nothing', () {
      for (final bad in ['Documents/Taxes/2025', 'Photos/Sub', '.DS_Store']) {
        expect(
          () => applyFirstSyncChoice(store, [bad], {}),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(store.setting(firstSyncSetting), isNull);
    });
  });

  group('screen', () {
    Future<void> pump(
      WidgetTester tester, {
      required FirstSyncDefault choice,
      required Future<FirstSyncListing> Function() load,
      required Future<void> Function(List<String>, Set<String>) confirm,
      Size size = const Size(360, 800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FirstSyncScreen(
              load: load,
              defaultChoice: choice,
              onConfirm: confirm,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final size in const [Size(360, 800), Size(412, 915)]) {
      testWidgets(
        'Android default: grouped under the top folders, sizes, nothing '
        'ticked; one tick confirmed (${size.width.toInt()}x'
        '${size.height.toInt()})',
        (tester) async {
          List<String>? paths;
          Set<String>? kept;
          await pump(
            tester,
            size: size,
            choice: FirstSyncDefault.cloud,
            load: () async => sample(),
            confirm: (f, k) async {
              paths = f;
              kept = k;
            },
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Choose what stays on this device'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('first-sync-top:Documents')),
            findsOneWidget,
          );
          expect(find.text('Always on this device'), findsWidgets);
          expect(find.text('Taxes'), findsOneWidget);
          expect(find.text('4.0 MiB'), findsOneWidget);
          expect(find.text('New and loose files in Documents'), findsOneWidget);
          expect(find.text('2 files · 1000 bytes'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('first-sync-download')),
            200,
          );
          expect(find.text('Downloads now: 1000 bytes'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('first-sync-top:Documents')),
            -200,
          );
          for (final box in tester.widgetList<CheckboxListTile>(
            find.byType(CheckboxListTile),
          )) {
            expect(box.value, isFalse);
          }
          expect(
            tester
                .getSize(find.byKey(const ValueKey('first-sync:Music/Albums')))
                .height,
            greaterThanOrEqualTo(48),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('first-sync:Music/Albums')),
          );
          await tester.tap(
            find.byKey(const ValueKey('first-sync:Music/Albums')),
          );
          await tester.pump();
          expect(find.text('Downloads now: 2.0 MiB'), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const ValueKey('first-sync-confirm')),
          );
          await tester.tap(find.byKey(const ValueKey('first-sync-confirm')));
          await tester.pumpAndSettle();
          expect(paths, [
            'Documents/Receipts',
            'Documents/Taxes',
            'Documents',
            'Music/Albums',
            'Music',
            'Videos',
            'Photos',
          ]);
          expect(kept, {'Music/Albums'});
        },
      );
    }

    testWidgets('desktop default keeps everything; one untick confirmed', (
      tester,
    ) async {
      Set<String>? kept;
      await pump(
        tester,
        size: const Size(1280, 1400),
        choice: FirstSyncDefault.local,
        load: () async => sample(),
        confirm: (_, k) async => kept = k,
      );
      for (final box in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(box.value, isTrue);
      }
      await tester.tap(find.byKey(const ValueKey('first-sync:Photos')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('first-sync-confirm')));
      await tester.pumpAndSettle();
      expect(kept, {
        'Documents/Receipts',
        'Documents/Taxes',
        'Documents',
        'Music/Albums',
        'Music',
        'Videos',
      });
    });

    testWidgets('a failed listing offers pairing again, then reloads', (
      tester,
    ) async {
      var loads = 0;
      var paired = 0;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FirstSyncScreen(
              load: () async {
                if (loads++ == 0) throw const HttpException('401');
                return FirstSyncListing.fromListings(
                  const [],
                  const {},
                  const {},
                );
              },
              defaultChoice: FirstSyncDefault.cloud,
              onConfirm: (_, _) async {},
              onPair: () async => paired++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('first-sync-pair')));
      await tester.pumpAndSettle();
      expect(paired, 1);
      expect(loads, 2);
      expect(
        find.text('New and loose files in Documents'),
        findsOneWidget,
        reason: 'the top folders are listed even on an empty account',
      );
    });

    testWidgets('a failed listing says nothing downloaded and retries', (
      tester,
    ) async {
      var calls = 0;
      var confirmed = false;
      await pump(
        tester,
        choice: FirstSyncDefault.cloud,
        load: () async {
          if (calls++ == 0) throw const SocketException('offline');
          return FirstSyncListing.fromListings(const [], const {}, const {});
        },
        confirm: (_, _) async => confirmed = true,
      );
      expect(find.byKey(const ValueKey('first-sync-error')), findsOneWidget);
      expect(
        find.textContaining('Nothing has been downloaded'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('first-sync-confirm')), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(
        find.text('New and loose files in Documents'),
        findsOneWidget,
        reason: 'the top folders are listed even on an empty account',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('first-sync-confirm')),
        200,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('first-sync-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('first-sync-confirm')));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });
  });

  testWidgets('desktop (Linux): after a first pairing the app shows the same '
      'screen with everything kept (decision #163)', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = layoutController()..firstSyncPending = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Choose what stays on this device'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('first-sync-top:Documents')),
      findsOneWidget,
    );
    final boxes = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(boxes, isNotEmpty);
    expect(boxes.every((box) => box.value == true), isTrue);
    expect(find.text('New and loose files in Documents'), findsOneWidget);
  });

  testWidgets('a top folder\'s menu shows and switches its new-and-loose-files '
      'choice (decision #163, M1)', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = layoutController();
    controller.entries = [
      for (final row in controller.entries)
        if (row['path'] == 'Documents')
          {...row, 'contentsRetention': 'cloud'}
        else
          row,
    ];
    addTearDown(controller.dispose);
    await tester.pumpWidget(CloudApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('row:Documents')),
        matching: find.byTooltip('Folder actions'),
      ),
    );
    await tester.pumpAndSettle();
    final cloud = tester.widget<CheckedPopupMenuItem<String>>(
      find.byKey(const ValueKey('contents-cloud:Documents')),
    );
    final local = tester.widget<CheckedPopupMenuItem<String>>(
      find.byKey(const ValueKey('contents-local:Documents')),
    );
    expect(cloud.checked, isTrue);
    expect(local.checked, isFalse);
    expect(find.text('Cloud-only / free up space'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('contents-local:Documents')));
    await tester.pumpAndSettle();
    expect(controller.commands, contains('retention:Documents'));
  });
}
