import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_platform.dart';

/// An in-memory Nextcloud tree over real TLS. Any change gives the item a
/// new ETag and every folder above it one too, as Nextcloud propagates
/// them; except, when [propagateFromShares] is false, above an incoming
/// share's mount (an owner's change inside it stops at the mount).
class _Tree {
  final kinds = <String, ItemKind>{'': ItemKind.directory};
  final etags = <String, String>{'': '"root"'};
  final ids = <String, int>{'': 1};
  final permissions = <String, String>{};

  /// Folders this account shares (`oc:share-types`); sharing changes no ETag.
  final sharedOut = <String>{};
  var _version = 0;
  var _id = 1;
  bool propagateFromShares = true;
  var incoming = <Map<String, Object?>>[];

  String _parent(String path) {
    final at = path.lastIndexOf('/');
    return at < 0 ? '' : path.substring(0, at);
  }

  bool _mount(String path) => permissions[path]?.contains('S') ?? false;

  void touch(String path) {
    var current = path;
    while (true) {
      etags[current] = '"e${++_version}"';
      if (current.isEmpty) return;
      if (!propagateFromShares && _mount(current)) return;
      current = _parent(current);
    }
  }

  void folder(String path, {String? permission}) {
    kinds[path] = ItemKind.directory;
    ids[path] = ++_id;
    if (permission != null) permissions[path] = permission;
    touch(path);
  }

  void file(String path) {
    kinds[path] = ItemKind.file;
    ids.putIfAbsent(path, () => ++_id);
    touch(path);
  }

  bool _under(String root, String path) =>
      path == root || path.startsWith('$root/');

  void delete(String path) {
    for (final key in kinds.keys.where((k) => _under(path, k)).toList()) {
      kinds.remove(key);
      etags.remove(key);
      ids.remove(key);
      permissions.remove(key);
    }
    touch(_parent(path));
  }

  /// A move keeps every moved item's ETag and file ID (the worst case for
  /// a listing keyed by ETag alone); both parents change.
  void move(String from, String to) {
    String renamed(String key) => '$to${key.substring(from.length)}';
    for (final key in kinds.keys.where((k) => _under(from, k)).toList()) {
      kinds[renamed(key)] = kinds.remove(key)!;
      etags[renamed(key)] = etags.remove(key)!;
      ids[renamed(key)] = ids.remove(key)!;
      if (permissions.remove(key) case final value?) {
        permissions[renamed(key)] = value;
      }
    }
    touch(_parent(from));
    touch(_parent(to));
  }

  String _response(String path) {
    final href = path.isEmpty
        ? '/dav/'
        : '/dav/${path.split('/').map(Uri.encodeComponent).join('/')}'
              '${kinds[path] == ItemKind.directory ? '/' : ''}';
    return '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
        '<d:resourcetype>${kinds[path] == ItemKind.directory ? '<d:collection/>' : ''}</d:resourcetype>'
        '<d:getetag>${etags[path]}</d:getetag><d:getcontentlength>1</d:getcontentlength>'
        '<oc:fileid>${ids[path]}</oc:fileid>'
        '${permissions[path] == null ? '' : '<oc:permissions>${permissions[path]}</oc:permissions>'}'
        '<oc:share-types>${sharedOut.contains(path) ? '<oc:share-type>0</oc:share-type>' : ''}</oc:share-types>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  }

  String listing(String path) =>
      '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
      '${_response(path)}'
      '${kinds.keys.where((k) => k.isNotEmpty && k != path && _parent(k) == path).map(_response).join()}'
      '</d:multistatus>';
}

void main() {
  if (skipSuite('incremental listing over a TLS fixture', opensslSkip)) return;
  late Directory fixture;
  late File ca;
  late File key;
  late HttpServer server;
  late _Tree tree;
  late Duration now;
  late DateTime wall;

  /// The folder the sharing routes share.
  const sharePath = 'T2/L0/x3';

  /// Called on each PROPFIND before it is answered.
  void Function(String path)? onPropfind;
  late DavCloud api;
  final propfinds = <String>[];

  /// Folders whose next PROPFIND fails once with this status.
  final failing = <String, int>{};

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-incremental-');
    ca = File('${fixture.path}/server.crt');
    key = File('${fixture.path}/server.key');
    final result = await Process.run(testOpenssl!, [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      key.path,
      '-out',
      ca.path,
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      // macOS's TLS policy requires serverAuth on a server certificate;
      // clientAuth keeps this self-signed anchor valid for client chains.
      '-addext',
      'extendedKeyUsage=serverAuth,clientAuth',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
    ]);
    if (result.exitCode != 0) throw StateError('TLS fixture setup failed.');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  DavCloud connect({bool pruneShares = false}) => DavCloud(
    Uri.parse('https://127.0.0.1:${server.port}'),
    SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca.path),
    monotonic: () => now,
    wallClock: () => wall,
    pruneShares: pruneShares,
  );

  Future<HttpServer> serve([int port = 0]) async {
    final result = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port,
      SecurityContext()
        ..useCertificateChain(ca.path)
        ..usePrivateKey(key.path),
    );
    result.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      final route = request.uri.path;
      if (route == '/v1/shares/incoming') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(tree.incoming));
      } else if (route.startsWith('/v1/shares')) {
        // Outgoing shares by id: '7' is the one share, of [sharePath].
        final outgoing = {
          'share_id': '7',
          'path': sharePath,
          'recipient_id': 'bob',
          'recipient_display_name': 'Bob',
          'permission': 'edit',
        };
        response.headers.contentType = ContentType.json;
        if (request.method == 'POST') tree.sharedOut.add(sharePath);
        if (request.method == 'DELETE') tree.sharedOut.remove(sharePath);
        response.write(
          jsonEncode(
            route == '/v1/shares/outgoing'
                ? [outgoing]
                : request.method == 'DELETE'
                ? {}
                : outgoing,
          ),
        );
      } else if (request.method == 'PROPFIND' && route.startsWith('/dav/')) {
        final path = Uri.decodeFull(route.substring(5))
            .replaceAll(RegExp(r'/$'), '');
        propfinds.add(path);
        onPropfind?.call(path);
        if (failing.remove(path) case final status?) {
          response.statusCode = status;
        } else if (tree.kinds[path] != ItemKind.directory) {
          response.statusCode = 404;
        } else {
          response.statusCode = 207;
          response.write(tree.listing(path));
        }
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
    return result;
  }

  setUp(() async {
    tree = _Tree();
    now = Duration.zero;
    propfinds.clear();
    failing.clear();
    wall = DateTime.utc(2026, 11, 4, 12);
    onPropfind = null;
    server = await serve();
    api = connect();
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  /// 500 folders of 10 files, as row 8's 5,000-file tree: 10 top folders,
  /// each with 7 levels of 7 folders beneath.
  void library({Iterable<int> tops = const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]}) {
    for (final top in tops) {
      if (!tree.kinds.containsKey('T$top')) tree.folder('T$top');
      for (var f = 0; f < 49; f++) {
        final path =
            'T$top/${List.generate(f ~/ 7 + 1, (d) => 'L$d').join('/')}/x$f';
        var parent = '';
        for (final part in path.split('/')) {
          parent = parent.isEmpty ? part : '$parent/$part';
          if (!tree.kinds.containsKey(parent)) tree.folder(parent);
        }
        for (var n = 0; n < 10; n++) {
          tree.file('$path/f$n.txt');
        }
      }
    }
  }

  Future<Map<String, RemoteItem>> list() async => {
    for (final item in await api.snapshot()) item.path: item,
  };

  Map<String, String> expected() => {
    for (final entry in tree.etags.entries)
      if (entry.key.isNotEmpty) entry.key: entry.value,
  };

  Future<Map<String, RemoteItem>> listsLikeAFullWalkWith() async {
    final listed = await list();
    expect({for (final e in listed.entries) e.key: e.value.etag}, expected());
    expect(
      {for (final e in listed.entries) e.key: e.value.fileId},
      {
        for (final e in tree.ids.entries)
          if (e.key.isNotEmpty) e.key: e.value,
      },
    );
    return listed;
  }

  Future<void> listsLikeAFullWalk() => listsLikeAFullWalkWith();

  int folderCount() =>
      tree.kinds.values.where((k) => k == ItemKind.directory).length;

  test(
    'an unchanged tree costs one PROPFIND after the first full walk',
    () async {
      library();
      expect(folderCount(), greaterThan(400));
      await listsLikeAFullWalk();
      expect(propfinds, hasLength(folderCount()));
      expect(api.fullWalks, 1);
      for (var check = 0; check < 3; check++) {
        propfinds.clear();
        await listsLikeAFullWalk();
        expect(propfinds, ['']);
      }
      expect(api.fullWalks, 1);
    },
  );

  test('a change six folders down is seen on the next check', () async {
    library();
    await list();
    const deep = 'T3/L0/L1/L2/L3/L4/x30';
    expect(deep.split('/'), hasLength(7));
    tree.file('$deep/f2.txt'); // edited
    tree.file('$deep/new.txt'); // created
    propfinds.clear();
    await listsLikeAFullWalk();
    // The root, then only the folders on the changed path.
    expect(propfinds.toSet(), {
      '',
      'T3',
      'T3/L0',
      'T3/L0/L1',
      'T3/L0/L1/L2',
      'T3/L0/L1/L2/L3',
      'T3/L0/L1/L2/L3/L4',
      deep,
    });
  });

  test('a deleted folder and a moved subtree are still seen', () async {
    library();
    await list();
    tree.delete('T1/L0/x2');
    tree.move('T2/L0/L1', 'T4/L0/Moved');
    propfinds.clear();
    final listed = await list();
    expect(listed.keys.where((k) => k.startsWith('T1/L0/x2')), isEmpty);
    expect(listed.keys.where((k) => k.startsWith('T2/L0/L1')), isEmpty);
    expect(listed.keys, contains('T4/L0/Moved/L2/L3/x21/f0.txt'));
    expect({for (final e in listed.entries) e.key: e.value.etag}, expected());
    // The moved folder kept its ETag and file ID but is new at its path:
    // listed there, never reused from its old place.
    expect(propfinds, contains('T4/L0/Moved'));
  });

  test('a listing error forces a full walk', () async {
    library();
    await list();
    tree.file('T5/L0/x0/f0.txt');
    failing['T5/L0'] = 500;
    await expectLater(api.snapshot(), throwsA(isA<CloudFailure>()));
    propfinds.clear();
    await listsLikeAFullWalk();
    expect(propfinds, hasLength(folderCount()));
    expect(api.fullWalks, 2);
    // Stored again: the next check is cheap.
    propfinds.clear();
    await list();
    expect(propfinds, ['']);
  });

  test('a failed connection forces a full walk', () async {
    library();
    await list();
    final port = server.port;
    await server.close(force: true);
    await expectLater(api.snapshot(), throwsA(isA<Exception>()));
    server = await serve(port);
    propfinds.clear();
    await listsLikeAFullWalk();
    expect(propfinds, hasLength(folderCount()));
  });

  test('a full walk runs at least every 6 hours (fake clock)', () async {
    library();
    await list();
    expect(listingFullWalkInterval, const Duration(hours: 6));
    now = const Duration(hours: 5, minutes: 59);
    propfinds.clear();
    await list();
    expect(propfinds, ['']);
    now = const Duration(hours: 6);
    propfinds.clear();
    await listsLikeAFullWalk();
    expect(propfinds, hasLength(folderCount()));
    expect(api.fullWalks, 2);
    // The interval counts from the latest full walk.
    now = const Duration(hours: 11, minutes: 59);
    propfinds.clear();
    await list();
    expect(propfinds, ['']);
    now = const Duration(hours: 12);
    await list();
    expect(api.fullWalks, 3);
  });

  test(
    'wall-clock time also bounds the interval (suspend), never a step back',
    () async {
      library();
      await list();
      // Suspended for 7 hours: the monotonic clock saw one.
      now = const Duration(hours: 1);
      wall = wall.add(const Duration(hours: 7));
      propfinds.clear();
      await listsLikeAFullWalk();
      expect(propfinds, hasLength(folderCount()));
      expect(api.fullWalks, 2);
      // The wall clock stepped back 10 hours: ignored, not a full walk.
      now = const Duration(hours: 2);
      wall = wall.subtract(const Duration(hours: 10));
      propfinds.clear();
      await list();
      expect(propfinds, ['']);
      // Nor does the step postpone one: 6 monotonic hours still walk.
      now = const Duration(hours: 7);
      await list();
      expect(api.fullWalks, 3);
      // Just under 6 wall hours after that walk: still pruned.
      now = const Duration(hours: 8);
      wall = wall.add(const Duration(hours: 5, minutes: 59));
      propfinds.clear();
      await list();
      expect(propfinds, ['']);
    },
  );

  test(
    'a folder recreated with the same ETag but a new file ID is listed',
    () async {
      library();
      await list();
      const folder = 'T6/L0/x1';
      final etag = tree.etags[folder]!;
      tree.delete(folder);
      tree.folder(folder);
      tree.file('$folder/replacement.txt');
      // Same ETag as the folder it replaced; its parents changed.
      tree.etags[folder] = etag;
      expect(tree.ids[folder], isNot(tree.ids['T6/L0']));
      propfinds.clear();
      final listed = await list();
      expect(propfinds, contains(folder));
      expect(listed.keys.where((k) => k.startsWith('$folder/')), [
        '$folder/replacement.txt',
      ]);
      expect(listed[folder]!.fileId, tree.ids[folder]);
    },
  );

  test('a failed request of any kind forces a full walk', () async {
    library();
    await list();
    final port = server.port;
    await server.close(force: true);
    final file = File('${fixture.path}/upload')..writeAsStringSync('x');
    await expectLater(
      api.upload('T0/new.txt', file, etag: null),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      api.deleteFile('T0/x0/f0.txt', etag: '"e1"'),
      throwsA(isA<Exception>()),
    );
    server = await serve(port);
    propfinds.clear();
    await listsLikeAFullWalk();
    expect(propfinds, hasLength(folderCount()));
  });

  test('a forget during a listing in flight is not overwritten', () async {
    library();
    // While the first walk runs, a request fails (a reconnect).
    onPropfind = (path) {
      if (path == 'T5') api.forgetListing();
    };
    await listsLikeAFullWalk();
    onPropfind = null;
    propfinds.clear();
    await listsLikeAFullWalk();
    expect(propfinds, hasLength(folderCount()));
    // That walk completed undisturbed and is stored.
    propfinds.clear();
    await list();
    expect(propfinds, ['']);
    // Likewise during an incremental check.
    tree.file('T5/L0/x0/f0.txt');
    onPropfind = (path) {
      if (path == 'T5') api.forgetListing();
    };
    await listsLikeAFullWalk();
    onPropfind = null;
    propfinds.clear();
    await list();
    expect(propfinds, hasLength(folderCount()));
  });

  test('a share made here re-lists only the folders above it', () async {
    library();
    await list();
    expect((await list())[sharePath]!.shared, isFalse);
    final etags = Map.of(tree.etags);
    await api.createShare(sharePath, 'bob', SharePermission.edit);
    expect(tree.etags, etags); // no ETag changed
    propfinds.clear();
    final shared = await listsLikeAFullWalkWith();
    expect(shared[sharePath]!.shared, isTrue);
    expect(propfinds.toSet(), {'', 'T2', 'T2/L0'});
    // Removing it, by id once the outgoing list was read.
    await api.outgoingShares();
    await api.removeShare('7');
    propfinds.clear();
    expect((await list())[sharePath]!.shared, isFalse);
    expect(propfinds.toSet(), {'', 'T2', 'T2/L0'});
    // A share whose path is unknown here forgets everything.
    await api.removeShare('8');
    propfinds.clear();
    await list();
    expect(propfinds, hasLength(folderCount()));
  });

  test('a share on a name spelled in NFD re-lists its NFC folders', () async {
    // Nextcloud stores and lists the NFC spelling (decision #138); macOS
    // hands the client the NFD one.
    const nfc = 'Caf\u00e9/R\u00e9sum\u00e9';
    const nfd = 'Cafe\u0301/Re\u0301sume\u0301';
    tree.folder('Caf\u00e9');
    tree.folder(nfc);
    tree.folder('$nfc/Inner');
    library(tops: [0]);
    await list();
    await api.createShare('$nfd/Inner', 'bob', SharePermission.edit);
    propfinds.clear();
    await list();
    expect(propfinds.toSet(), {'', 'Caf\u00e9', nfc});
  });

  group('incoming shares', () {
    void shared() {
      library();
      tree.folder('Shared');
      tree.folder('Shared/Family', permission: 'SRGDNVCK');
      var path = 'Shared/Family';
      for (var d = 0; d < 6; d++) {
        path = '$path/D$d';
        tree.folder(path, permission: 'SRGDNVCK');
        tree.file('$path/f.txt');
        tree.permissions['$path/f.txt'] = 'SRGDNVW';
      }
    }

    test(
      'without proven propagation every folder holding one is listed',
      () async {
        shared();
        tree.propagateFromShares = false;
        await list();
        // The owner edits deep in the share; nothing above the mount changes.
        const deep = 'Shared/Family/D0/D1/D2/D3/D4/D5';
        tree.file('$deep/f.txt');
        expect(tree.etags['Shared'], isNot(isNull));
        propfinds.clear();
        await listsLikeAFullWalk();
        expect(propfinds.toSet(), {
          '',
          'Shared',
          'Shared/Family',
          for (var d = 1; d <= 6; d++)
            ['Shared/Family', for (var i = 0; i < d; i++) 'D$i'].join('/'),
        });
        expect(propfinds.length, lessThanOrEqualTo(9));
      },
    );

    test('with proven propagation a share is pruned like any folder', () async {
      api.close();
      api = connect(pruneShares: true);
      shared();
      await list();
      propfinds.clear();
      await list();
      expect(propfinds, ['']);
      tree.file('Shared/Family/D0/D1/D2/D3/D4/D5/f.txt');
      propfinds.clear();
      await listsLikeAFullWalk();
      expect(propfinds, hasLength(9)); // the root and the changed path
    });

    test('a change to the incoming shares forces a full walk', () async {
      shared();
      await api.incomingShares();
      await list();
      tree.incoming = [
        {
          'share_id': '7',
          'path': 'Shared/Family',
          'owner_display_name': 'Ann',
          'permission': 'edit',
        },
      ];
      await api.incomingShares();
      propfinds.clear();
      await list();
      expect(propfinds, hasLength(folderCount()));
      // The same list again changes nothing.
      await api.incomingShares();
      propfinds.clear();
      await list();
      expect(propfinds.length, lessThanOrEqualTo(9));
    });
  });

  test('the engine sees a deep cloud change on its next check', () async {
    tree.folder('T3');
    final parent = Directory('${fixture.path}/engine-${server.port}')
      ..createSync();
    final root = RootTree.setup(parent.path, 'incremental', NativeRootFs());
    final store = Manifest(Directory('${parent.path}/profile'));
    final engine = SyncEngine(store, root, api);
    addTearDown(() {
      engine.close();
      parent.deleteSync(recursive: true);
    });
    store.verifyTracking = false;
    await engine.tick();
    engine.setRetention('T3', Retention.cloud);
    library(tops: [3]);
    await engine.tick();
    const file = 'T3/L0/L1/L2/L3/L4/x30/f2.txt';
    final first = store.entries[file]!.etag;
    expect(first, tree.etags[file]);
    propfinds.clear();
    await engine.tick(remote: RemotePolicy.always);
    expect(propfinds, ['']);
    tree.file(file);
    tree.file('T3/L0/L1/L2/L3/L4/x30/added.txt');
    await engine.tick(remote: RemotePolicy.always);
    expect(store.entries[file]!.etag, tree.etags[file]);
    expect(store.entries[file]!.etag, isNot(first));
    expect(store.entries['T3/L0/L1/L2/L3/L4/x30/added.txt']?.etag, isNotNull);
  });
}
