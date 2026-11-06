// Incremental cloud listing end to end (spec #33 I4, rows 8, 9 and 10): a real
// Linux sync engine against a review gateway and Nextcloud. Run by
// deploy/incremental_listing_fixture.py, which pairs the devices, builds the
// tree on the server and counts PROPFINDs in Nextcloud's access log between
// the HEAD markers this side sends; this side proves what the client sees.
//
//   dart run tool/incremental_listing_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, alice: {certificate, key}, bob: {...}, aliceUid,
// work, folder, probe}. Line protocol: prints {"await": step} and waits for
// one line on stdin before going on; prints one JSON result line last and
// exits non-zero on the first failed claim.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

/// The worker's client, counting its own PROPFINDs.
class CountingDav extends DavCloud {
  CountingDav(super.origin, super.context, {super.pruneShares})
    : super(folderDeletionQualified: true);
  int propfinds = 0;

  /// Time spent listing, in milliseconds.
  int listingMs = 0;
  @override
  Future<List<RemoteItem>> snapshot() async {
    final watch = Stopwatch()..start();
    try {
      return await super.snapshot();
    } finally {
      listingMs += watch.elapsedMilliseconds;
    }
  }

  @override
  Future<HttpClientResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    File? source,
    List<int>? body,
  }) {
    if (method == 'PROPFIND') propfinds++;
    return super.request(
      method,
      path,
      headers: headers,
      source: source,
      body: body,
    );
  }
}

final _input = stdin.transform(utf8.decoder).transform(const LineSplitter());
final StreamIterator<String> _lines = StreamIterator(_input);

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(config['work'] as String);
  if (work.existsSync()) throw StateError('Fixture work path must be absent.');
  work.createSync(recursive: true);
  final origin = Uri.parse(config['origin'] as String);
  SecurityContext context(String who) {
    final device = config[who] as Map<String, dynamic>;
    return SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(config['ca'] as String)
      ..useCertificateChain(device['certificate'] as String)
      ..usePrivateKey(device['key'] as String);
  }

  final folder = config['folder'] as String;
  final probe = config['probe'] as String;
  final claims = <String, Object?>{};
  void claim(String name, bool passed, [Object? detail]) {
    claims[name] = detail ?? passed;
    if (!passed) {
      stdout.writeln(jsonEncode({'failed': name, 'claims': claims}));
      exit(1);
    }
  }

  Future<void> wait(String step) async {
    stdout.writeln(jsonEncode({'await': step}));
    if (!await _lines.moveNext()) throw StateError('Controller went away.');
  }

  final cloud = CountingDav(origin, context('alice'));
  // A second connection of the same account makes the cloud-side changes.
  final writer = DavCloud(origin, context('alice'));
  final bob = DavCloud(origin, context('bob'));
  final marks = <String>[];
  Future<void> mark(String name) async {
    final response = await writer.request('HEAD', 'zz-marker-$name');
    await response.drain<void>();
    marks.add(name);
  }

  Engine open(String name, CountingDav client) {
    final tree = RootTree.setup(
      (Directory('${work.path}/$name')..createSync()).path,
      'listing-e2e',
      NativeRootFs(),
    );
    final store = Manifest(Directory('${work.path}/$name-profile'));
    // Pre-seeded as the user's choice: the fixture folder is Cloud-only, so
    // no pass downloads the library (the row is what setRetention writes).
    store.entries[folder] = Entry(folder, ItemKind.directory)
      ..override = Retention.cloud;
    store.save();
    return (engine: SyncEngine(store, tree, client), store: store);
  }

  // A check as the worker runs it: list, then reconcile; with its markers.
  Future<({int propfinds, int ms, int listingMs})> check(
    SyncEngine engine,
    CountingDav client,
    String name,
  ) async {
    await mark('$name-begin');
    final before = client.propfinds;
    final listed = client.listingMs;
    final watch = Stopwatch()..start();
    await engine.tick(remote: RemotePolicy.always);
    final ms = watch.elapsedMilliseconds;
    await mark('$name-end');
    claim('$name listed', engine.remoteListed, engine.message);
    return (
      propfinds: client.propfinds - before,
      ms: ms,
      listingMs: client.listingMs - listed,
    );
  }

  try {
    await wait('populate');
    final (:engine, :store) = open('a', cloud);
    final first = await check(engine, cloud, 'first');
    final rows = store.entries.keys.where((k) => k.startsWith('$folder/'));
    claim('first pass lists the tree', rows.length == 5500, {
      'rows': rows.length,
      'ms': first.ms,
      'listing_ms': first.listingMs,
      'propfinds': first.propfinds,
      'full_walks': cloud.fullWalks,
    });
    // Row 8: nothing changed.
    final quiet = [
      for (var i = 1; i <= 3; i++) (await check(engine, cloud, 'quiet$i')),
    ];
    claim(
      'row 8: at most 3 PROPFINDs per quiet check (client count)',
      quiet.every((q) => q.propfinds <= 3),
      [for (final q in quiet) q.propfinds],
    );
    // Row 9, owned: an edit and a new file six folders down.
    final deep = '$folder/T0/A0/B0/C0/D0';
    claim('deep folder is six levels down', deep.split('/').length == 6);
    final edited = '$deep/f0.txt';
    final source = File('${work.path}/source.txt')
      ..writeAsStringSync('edited deep');
    final version = await writer.upload(
      edited,
      source,
      etag: store.entries[edited]!.etag,
    );
    await writer.upload('$deep/added.txt', source, etag: null);
    final owned = await check(engine, cloud, 'deep');
    claim(
      'row 9: deep owned change seen on the next check',
      {
        store.entries[edited]?.etag == version,
        store.entries['$deep/added.txt']?.status == 'cloud-only',
      }.every((v) => v),
      {'propfinds': owned.propfinds},
    );
    // Row 9, shares: does an owner's deep change reach the recipient's
    // folder ETags? Read with a fresh client (a full walk) each time.
    var chain = probe;
    await bob.mkdir(chain);
    for (var level = 1; level <= 5; level++) {
      chain = '$chain/S$level';
      await bob.mkdir(chain);
    }
    final probeFile = File('${work.path}/probe.txt')..writeAsStringSync('p');
    var probeVersion = await bob.upload('$chain/f.txt', probeFile, etag: null);
    await bob.createShare(
      probe,
      config['aliceUid'] as String,
      SharePermission.edit,
    );
    final mount = '$sharedFolder/${probe.split('/').last}';
    Future<Map<String, String>> recipientView() async {
      final fresh = DavCloud(origin, context('alice'));
      try {
        return {
          for (final item in await fresh.snapshot())
            if (item.kind == ItemKind.directory &&
                (item.path == sharedFolder || inSharedFolder(item.path)))
              item.path: item.etag,
        };
      } finally {
        fresh.close();
      }
    }

    final trials = <Map<String, Object?>>[];
    var view = await recipientView();
    claim('share mounted for the recipient', view.containsKey(mount), view);
    final relative = chain.substring(probe.length);
    for (final change in ['edit', 'add', 'delete']) {
      switch (change) {
        case 'edit':
          probeVersion = await bob.upload(
            '$chain/f.txt',
            probeFile,
            etag: probeVersion,
          );
        case 'add':
          await bob.upload('$chain/n9.txt', probeFile, etag: null);
        case 'delete':
          final listed = {
            for (final item in await bob.snapshot()) item.path: item.etag,
          };
          await bob.deleteFile('$chain/n9.txt', etag: listed['$chain/n9.txt']!);
      }
      final after = await recipientView();
      trials.add({
        'change': change,
        'shared_changed': after[sharedFolder] != view[sharedFolder],
        'mount_changed': after[mount] != view[mount],
        'deepest_changed': after['$mount$relative'] != view['$mount$relative'],
      });
      view = after;
    }
    final propagates = trials.every(
      (t) => t['shared_changed'] == true && t['mount_changed'] == true,
    );
    claims['share propagation'] = {'propagates': propagates, 'trials': trials};
    claim(
      'the client prunes shares only with proven propagation',
      propagates || !cloud.pruneShares,
    );
    // The engine (shares always walked unless proven) sees the owner's change.
    final mounted = await check(engine, cloud, 'share-mount');
    await bob.upload('$chain/late.txt', probeFile, etag: null);
    final shared = await check(engine, cloud, 'share-deep');
    claim(
      'row 9: deep change in an incoming share seen on the next check',
      store.entries['$mount$relative/late.txt']?.etag != null,
      {'mount_check': mounted.propfinds, 'propfinds': shared.propfinds},
    );
    final quietShared = await check(engine, cloud, 'quiet-shared');
    claims['quiet check with the share'] = quietShared.propfinds;
    // Row 10 on the stack: a fresh device's first pass over 10,000 files.
    await wait('grow');
    final fresh = CountingDav(origin, context('alice'));
    final second = open('b', fresh);
    final big = await check(second.engine, fresh, 'first10k');
    final bigRows = second.store.entries.values.where(
      (e) => e.path.startsWith('$folder/') && e.kind == ItemKind.file,
    );
    claim(
      'row 10: 10,000 Cloud-only files on a fresh device',
      bigRows.length >= 10000,
      {'files': bigRows.length, 'ms': big.ms, 'propfinds': big.propfinds},
    );
    second.engine.close();
    fresh.close();
    engine.close();
    stdout.writeln(jsonEncode({'claims': claims, 'marks': marks}));
  } finally {
    cloud.close();
    writer.close();
    bob.close();
  }
  exit(0);
}

typedef Engine = ({SyncEngine engine, Manifest store});
