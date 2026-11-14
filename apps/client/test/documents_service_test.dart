// Spec #28 A5, decision #127: the AnJ Cloud documents provider's allowlist
// and stable document ids (DocumentsService over a fake host), on the VM host.
import 'dart:io';

import 'package:anj_cloud/core/access/access_store.dart';
import 'package:anj_cloud/core/access/documents_service.dart';
import 'package:anj_cloud/core/ports/documents.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHost extends ChangeNotifier implements DocumentsHost {
  FakeHost(this.entries);
  @override
  List<Map<String, dynamic>> entries;
  @override
  bool documentsReady = true;
  @override
  void Function(String from, String to)? onLocalRename;
  final commands = <(String, Map<String, Object?>)>[];
  Map<String, Object?> Function(String op, Map<String, Object?> args)? answer;
  @override
  Future<Map<String, Object?>> documentsCommand(
    String op,
    Map<String, Object?> args,
  ) async {
    commands.add((op, args));
    return answer?.call(op, args) ??
        switch (op) {
          'open' => {'fd': 42, 'size': 1},
          'create' => {
            'path': [
              if ((args['parent'] as String).isNotEmpty) args['parent'],
              args['name'],
            ].join('/'),
          },
          'rename' => {
            'path': [
              ...(args['path'] as String).split('/')..removeLast(),
              args['name'],
            ].join('/'),
          },
          'move' => {
            'path': [
              if ((args['parent'] as String).isNotEmpty) args['parent'],
              (args['path'] as String).split('/').last,
            ].join('/'),
          },
          _ => {},
        };
  }

  void set(List<Map<String, dynamic>> value) {
    entries = value;
    notifyListeners();
  }
}

class FakeRevoker implements GrantRevoker {
  List<String> trees = [];
  final revoked = <(String, String)>[];
  @override
  Future<List<String>> persistedTrees() async => trees;
  @override
  Future<void> revokeTree(String package, String documentId) async =>
      revoked.add((package, documentId));

  List<({String id, bool read, bool write})> documents = [];
  final revokedDocuments = <String>[];
  @override
  Future<List<({String id, bool read, bool write})>>
  persistedDocuments() async => documents;
  @override
  Future<void> revokeDocument(String documentId) async {
    revokedDocuments.add(documentId);
    documents.removeWhere((d) => d.id == documentId);
  }
}

Map<String, dynamic> dir(String path, {bool viewOnly = false}) => {
  'path': path,
  'kind': 'directory',
  'status': 'current local',
  'expectedPresent': true,
  'viewOnly': viewOnly,
};

Map<String, dynamic> file(
  String path, {
  bool present = true,
  bool viewOnly = false,
  String status = 'current local',
}) => {
  'path': path,
  'kind': 'file',
  'size': 3,
  'etag': '"e"',
  'status': status,
  'expectedPresent': present,
  'viewOnly': viewOnly,
  'remoteModified': 1700000000,
};

const g1 = DocumentsCaller(
  CallerKind.app,
  package: 'cloud.anj.anj_cloud.qa.grantee1',
);
const g2 = DocumentsCaller(
  CallerKind.app,
  package: 'cloud.anj.anj_cloud.qa.grantee2',
);
const g3 = DocumentsCaller(
  CallerKind.app,
  package: 'cloud.anj.anj_cloud.qa.grantee3',
);
const system = DocumentsCaller(CallerKind.system);

Matcher denied() =>
    throwsA(isA<DocumentsFailure>().having((e) => e.code, 'code', 'denied'));

void main() {
  late Directory profile;
  late FakeHost host;
  late AccessStore store;
  late FakeRevoker revoker;
  late DocumentsService service;
  var now = DateTime(2026, 11, 4, 12);

  List<Map<String, dynamic>> library() => [
    dir('Music'),
    dir('Music/Album'),
    file('Music/Album/track.mp3'),
    file('Music/loose.flac'),
    dir('Private'),
    file('Private/secret.txt'),
    dir('Shared'),
    dir('Shared/Ann', viewOnly: true),
    file('Shared/Ann/photo.jpg', viewOnly: true),
    file('cloud.txt', present: false),
    file('gone.txt', status: 'delete queued'),
  ];

  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-documents-');
    host = FakeHost(library());
    store = AccessStore(profile, clock: () => now);
    revoker = FakeRevoker();
    service = DocumentsService(host, store, revoker: revoker, clock: () => now);
  });
  tearDown(() {
    service.dispose();
    store.close();
    profile.deleteSync(recursive: true);
  });

  String id(String path) => service.idOf(path);
  List<String> names(Map<String, Object?> listing) => [
    for (final row in listing['rows'] as List) (row as Map)['name'] as String,
  ];

  test('the system Files app browses everything except deleted rows', () {
    expect(names(service.children('root', system)), [
      'Music',
      'Private',
      'Shared',
      'cloud.txt',
    ]);
    expect(names(service.children(id('Music'), system)), [
      'Album',
      'loose.flac',
    ]);
    final cloud =
        (service.children('root', system)['rows'] as List).last as Map;
    expect(cloud['cloudOnly'], isTrue);
  });

  test('spec #52: the phone folders leave the provider; their approvals end '
      'and their old ids stop resolving', () async {
    await service.approve(g1.package!, 'Music/Album', AccessMode.read);
    await service.approve(g1.package!, 'Private', AccessMode.write);
    final album = id('Music/Album');
    service.dispose();
    service = DocumentsService(
      host,
      store,
      revoker: revoker,
      clock: () => now,
      hidden: (path) => path == 'Music' || path.startsWith('Music/'),
    );
    expect(names(service.children('root', system)), [
      'Private',
      'Shared',
      'cloud.txt',
    ]);
    expect(service.folders, isNot(contains('Music')));
    expect(
      () => service.resolve(album),
      throwsA(isA<DocumentsFailure>().having((e) => e.code, 'c', 'notFound')),
    );
    expect(service.approvals.map((a) => a.folder), ['Private']);
  });

  test('Files app navigation resolves root, folder and file ancestry', () {
    expect(service.findPath(null, 'root', system), ['root']);
    expect(service.findPath(null, id('Music/Album'), system), [
      'root',
      id('Music'),
      id('Music/Album'),
    ]);
    expect(service.findPath(null, id('Music/Album/track.mp3'), system), [
      'root',
      id('Music'),
      id('Music/Album'),
      id('Music/Album/track.mp3'),
    ]);
    expect(service.findPath(null, id('cloud.txt'), system), [
      'root',
      id('cloud.txt'),
    ]);
    expect(
      host.commands,
      isEmpty,
      reason: 'Navigation needs no network or file bytes.',
    );
  });

  test(
    'tree navigation exposes only the approved parent and descendants',
    () async {
      final parent = id('Music/Album');
      final child = id('Music/Album/track.mp3');
      expect(() => service.findPath(parent, child, g1), denied());
      await service.approve(g1.package!, 'Music/Album', AccessMode.read);
      expect(service.findPath(parent, child, g1), [parent, child]);
      expect(service.findPath(parent, parent, g1), [parent]);
      expect(() => service.findPath(null, child, g1), denied());
      expect(() => service.findPath(id('Music'), child, g1), denied());
      await service.revoke(g1.package!, 'Music/Album');
      expect(() => service.findPath(parent, child, g1), denied());
    },
  );

  test(
    'navigation refuses unrelated, missing, deleted and non-tree documents',
    () {
      final notFound = throwsA(
        isA<DocumentsFailure>().having((e) => e.code, 'code', 'notFound'),
      );
      expect(
        () => service.findPath(id('Private'), id('Music/Album'), system),
        notFound,
      );
      expect(
        () => service.findPath(id('cloud.txt'), id('cloud.txt'), system),
        notFound,
      );
      expect(() => service.findPath(null, 'n:999999', system), notFound);
      expect(() => service.findPath(null, id('gone.txt'), system), notFound);
      host.set([
        ...library(),
        {
          ...file('Docs.txt'),
          'workingCopies': [
            {'path': '/staging/working-1-Docs.txt'},
          ],
        },
      ]);
      expect(
        () => service.findPath(null, 'w:working-1-Docs.txt', system),
        notFound,
      );
      expect(
        () => service.findPath('w:working-1-Docs.txt', id('Music'), system),
        notFound,
      );
      const viewer = DocumentsCaller(CallerKind.document, documentRead: true);
      expect(() => service.findPath(null, id('Music/Album'), viewer), denied());
      expect(
        () => service.findPath(id('Music/Album'), id('Music/Album'), viewer),
        denied(),
      );
      host.set([dir('Music/Album')]);
      expect(() => service.findPath(null, id('Music/Album'), system), notFound);
    },
  );

  test('default: no app has access, even to a folder it picked', () async {
    expect(() => service.children(id('Music'), g1), denied());
    expect(() => service.document(id('Music/loose.flac'), g1), denied());
    await expectLater(service.open(id('Music/loose.flac'), 'r', g1), denied());
    expect(host.commands, isEmpty);
    // The refusal is offered for approval in settings.
    expect(service.requests.single.package, g1.package);
    expect(service.requests.single.folder, 'Music');
  });

  test('a read approval covers its subtree only, read-only', () async {
    await service.approve(g1.package!, 'Music', AccessMode.read);
    expect(service.approvals.single.status, ApprovalStatus.approved);
    expect(names(service.children(id('Music/Album'), g1)), ['track.mp3']);
    expect(service.approvals.single.status, ApprovalStatus.connected);
    final open = await service.open(id('Music/Album/track.mp3'), 'r', g1);
    expect(open['fd'], 42);
    expect(host.commands.single.$2['write'], isFalse);
    // Not outside it, not the parent, never a change.
    expect(() => service.children('root', g1), denied());
    expect(() => service.document(id('Private/secret.txt'), g1), denied());
    await expectLater(service.open(id('Music/loose.flac'), 'w', g1), denied());
    await expectLater(
      service.create(id('Music'), 'new.txt', false, g1),
      denied(),
    );
    final row =
        (service.children(id('Music'), g1)['rows'] as List).first as Map;
    expect(row['write'] ?? false, isFalse);
    expect(row['create'], isFalse);
    expect(row['delete'], isFalse);
    // Another app is still refused.
    expect(() => service.children(id('Music'), g2), denied());
  });

  test(
    'a write approval changes inside the folder, never the folder itself',
    () async {
      await service.approve(g1.package!, 'Music', AccessMode.write);
      await service.open(id('Music/loose.flac'), 'rw', g1);
      expect(host.commands.last.$2['write'], isTrue);
      expect(
        await service.create(id('Music'), 'new.txt', false, g1),
        isNotNull,
      );
      await service.rename(id('Music/loose.flac'), 'renamed.flac', g1);
      await expectLater(service.rename(id('Music'), 'Tunes', g1), denied());
      await expectLater(service.delete(id('Music'), g1), denied());
      await service.delete(id('Music/Album/track.mp3'), g1);
      expect(
        [for (final c in host.commands) c.$1],
        ['open', 'create', 'rename', 'delete'],
      );
    },
  );

  test('revoking one app leaves another app on the same folder', () async {
    await service.approve(g1.package!, 'Music', AccessMode.read);
    await service.approve(g2.package!, 'Music', AccessMode.read);
    revoker.trees = [id('Music'), id('Private')];
    await service.revoke(g1.package!, 'Music');
    expect(() => service.children(id('Music'), g1), denied());
    expect(names(service.children(id('Music'), g2)), ['Album', 'loose.flac']);
    final statuses = {for (final a in service.approvals) a.package: a.status};
    expect(statuses[g1.package], ApprovalStatus.revoked);
    expect(statuses[g2.package], ApprovalStatus.connected);
    // The platform grants g1 can no longer use are withdrawn for g1 only.
    expect(revoker.revoked, [
      (g1.package!, id('Music')),
      (g1.package!, id('Private')),
    ]);
  });

  test('subfolder and parent approvals are separate rows', () async {
    // Approved for the subfolder only: the parent stays closed, even
    // through a parent tree the app picked.
    await service.approve(g1.package!, 'Music/Album', AccessMode.read);
    expect(() => service.children(id('Music'), g1), denied());
    expect(names(service.children(id('Music/Album'), g1)), ['track.mp3']);
    // Approved for both: revoking the parent keeps the subfolder.
    await service.approve(g2.package!, 'Music', AccessMode.read);
    await service.approve(g2.package!, 'Music/Album', AccessMode.read);
    revoker.trees = [id('Music'), id('Music/Album')];
    await service.revoke(g2.package!, 'Music');
    expect(() => service.children(id('Music'), g2), denied());
    expect(() => service.document(id('Music/loose.flac'), g2), denied());
    expect(names(service.children(id('Music/Album'), g2)), ['track.mp3']);
    // Neither platform grant overlaps nothing g2 still holds: both stay.
    expect(revoker.revoked, isEmpty);
    await service.revoke(g2.package!, 'Music/Album');
    expect(() => service.children(id('Music/Album'), g2), denied());
    expect(revoker.revoked, [
      (g2.package!, id('Music')),
      (g2.package!, id('Music/Album')),
    ]);
  });

  test('a per-document grant reaches that document only (R1)', () async {
    const viewer = DocumentsCaller(
      CallerKind.document,
      package: 'viewer',
      documentRead: true,
    );
    expect(
      service.document(id('Private/secret.txt'), viewer)['name'],
      'secret.txt',
    );
    await service.open(id('Private/secret.txt'), 'r', viewer);
    await expectLater(
      service.open(id('Private/secret.txt'), 'w', viewer),
      denied(),
    );
    expect(() => service.children(id('Private'), viewer), denied());
    await expectLater(
      service.delete(id('Private/secret.txt'), viewer),
      denied(),
    );
  });

  test(
    'every provider change asks for prompt background work (review M1)',
    () async {
      var prompts = 0;
      service.onLocalChange = () => prompts++;
      await service.approve(g1.package!, 'Music', AccessMode.write);
      await service.approve(g2.package!, 'Music', AccessMode.read);
      // Reading changes nothing: no prompt.
      final read = await service.open(id('Music/loose.flac'), 'r', g1);
      await service.closed(read['token'] as String);
      expect(prompts, 0, reason: 'a read-only open and close');
      // A refused change asks for nothing.
      await expectLater(
        service.create(id('Music'), 'x.txt', false, g2),
        denied(),
      );
      expect(prompts, 0);
      final made = await service.create(id('Music'), 'new.txt', false, g1);
      expect(prompts, 1, reason: 'create');
      final written = await service.open(made, 'w', g1);
      expect(prompts, 1, reason: 'opening for writing has not changed it yet');
      await service.closed(written['token'] as String);
      expect(prompts, 2, reason: 'closed after writing');
      await service.closed(written['token'] as String);
      expect(prompts, 2, reason: 'a repeated close is ignored');
      final renamed = await service.rename(made, 'renamed.txt', g1);
      expect(prompts, 3, reason: 'rename');
      final moved = await service.move(renamed, id('Music/Album'), g1);
      expect(prompts, 4, reason: 'move');
      await service.delete(moved, g1);
      expect(prompts, 5, reason: 'delete');
      // The system Files app's changes count as well.
      await service.create(id('Music'), 'by-files.txt', false, system);
      expect(prompts, 6);
      // A prompt that cannot be asked for does not fail the change.
      service.onLocalChange = () => throw StateError('no runner');
      await service.create(id('Music'), 'still.txt', false, g1);
    },
  );

  test(
    'kept single-file grants are listed and revocable (review M2)',
    () async {
      const viewer = DocumentsCaller(
        CallerKind.document,
        package: 'viewer',
        documentRead: true,
      );
      final secret = id('Private/secret.txt');
      final track = id('Music/Album/track.mp3');
      revoker.documents = [
        (id: secret, read: true, write: false),
        (id: secret, read: true, write: true), // a second app, never seen
        (id: track, read: true, write: false),
        (id: 'n:9999', read: true, write: false),
      ];
      // The platform's list names no app: the provider records who uses it.
      await service.open(secret, 'r', viewer);
      service.document(track, viewer);
      // An app reaching the file through a folder approval is not a file user.
      await service.approve(g1.package!, 'Music', AccessMode.read);
      service.document(track, g1);
      final files = await service.fileGrants();
      expect(
        [for (final f in files) f.name],
        [
          'A file that is no longer in AnJ Cloud',
          'Music/Album/track.mp3',
          'Private/secret.txt',
        ],
      );
      final row = files.last;
      expect(row.documentId, secret);
      expect(row.holders, 2);
      expect(row.write, isTrue);
      expect(row.packages, ['viewer']);
      expect(files[1].packages, ['viewer']);
      expect(files[1].write, isFalse);
      // A rename keeps the id, so the row follows the file.
      service.localRenamed('Private/secret.txt', 'Private/renamed.txt');
      host.set([
        for (final e in library())
          if (e['path'] == 'Private/secret.txt')
            {...e, 'path': 'Private/renamed.txt'}
          else
            e,
      ]);
      expect(
        (await service.fileGrants()).map((f) => f.name),
        contains('Private/renamed.txt'),
      );
      var notified = 0;
      service.addListener(() => notified++);
      await service.revokeFile(secret);
      expect(revoker.revokedDocuments, [secret]);
      expect(notified, greaterThan(0));
      expect(store.fileUsers().containsKey(secret), isFalse);
      expect(store.fileUsers()[track], ['viewer']);
      expect(
        (await service.fileGrants()).map((f) => f.documentId),
        isNot(contains(secret)),
      );
    },
  );

  test(
    'working copies are reachable only through a per-document grant',
    () async {
      host.set([
        ...library(),
        {
          ...file('Docs.txt', present: false),
          'workingCopies': [
            {'id': 'op', 'path': '/data/files/.anj-cloud-x/working-1-Docs.txt'},
          ],
        },
      ]);
      const editor = DocumentsCaller(
        CallerKind.document,
        package: 'editor',
        documentRead: true,
        documentWrite: true,
      );
      final opened = await service.open('w:working-1-Docs.txt', 'rw', editor);
      expect(opened['token'], isNotNull);
      expect(host.commands.last.$2['working'], 'working-1-Docs.txt');
      await service.approve(g1.package!, '', AccessMode.write);
      await expectLater(
        service.open('w:working-1-Docs.txt', 'r', g1),
        denied(),
      );
      expect(service.isChild('root', 'w:working-1-Docs.txt'), isFalse);
    },
  );

  test('a kept working-copy grant says "being edited" only once the copy '
      'changed (decision #183)', () async {
    List<Map<String, dynamic>> withCopy({required bool edited}) => [
      ...library(),
      {
        ...file('Docs.txt', present: false),
        'workingCopies': [
          {
            'id': 'op',
            'path': '/data/files/.anj-cloud-x/working-1-Docs.txt',
            'edited': edited,
          },
        ],
      },
    ];
    revoker.documents = [
      (id: 'w:working-1-Docs.txt', read: true, write: false),
    ];
    host.set(withCopy(edited: false));
    expect((await service.fileGrants()).single.name, 'Docs.txt');
    host.set(withCopy(edited: true));
    expect((await service.fileGrants()).single.name, 'Docs.txt (being edited)');
  });

  test('top folders carry no delete, rename or move flags (spec #34 P7)', () {
    final rows = service.children('root', system)['rows'] as List;
    final music = rows.cast<Map>().singleWhere((r) => r['name'] == 'Music');
    expect(music['delete'], isFalse);
    expect(music['rename'], isFalse);
    expect(music['move'], isFalse);
    expect(music['create'], isTrue);
    final album = (service.children(id('Music'), system)['rows'] as List)
        .cast<Map>()
        .singleWhere((r) => r['name'] == 'Album');
    expect(album['delete'], isTrue);
    expect(album['rename'], isTrue);
  });

  test('view-only items carry no change flags and refuse writes', () async {
    final rows = service.children(id('Shared/Ann'), system)['rows'] as List;
    final photo = rows.single as Map;
    expect(photo['write'], isFalse);
    expect(photo['delete'], isFalse);
    await expectLater(
      service.open(id('Shared/Ann/photo.jpg'), 'w', system),
      throwsA(
        isA<DocumentsFailure>().having((e) => e.code, 'code', 'readOnly'),
      ),
    );
  });

  test('document ids stay stable across rename and move', () async {
    final album = id('Music/Album');
    final track = id('Music/Album/track.mp3');
    await service.approve(g1.package!, 'Music/Album', AccessMode.read);
    expect(await service.rename(album, 'Record', system), album);
    expect(service.resolve(album).path, 'Music/Record');
    expect(service.resolve(track).path, 'Music/Record/track.mp3');
    expect(service.findPath(null, track, system), [
      'root',
      id('Music'),
      album,
      track,
    ]);
    // The approval follows its folder.
    expect(service.approvals.single.folder, 'Music/Record');
    expect(names(service.children(album, g1)), ['track.mp3']);
    expect(await service.move(album, id('Private'), system), album);
    expect(service.resolve(track).path, 'Private/Record/track.mp3');
    expect(service.isChild(id('Private'), track), isTrue);
    expect(service.isChild(id('Music'), track), isFalse);
    expect(service.findPath(null, track, system), [
      'root',
      id('Private'),
      album,
      track,
    ]);
    expect(service.findPath(album, track, g1), [album, track]);
  });

  test(
    'a deleted item ends its id and approvals; its name gets a new id',
    () async {
      final album = id('Music/Album');
      await service.approve(g1.package!, 'Music/Album', AccessMode.read);
      revoker.trees = [album];
      await service.delete(album, system);
      expect(service.approvals, isEmpty);
      expect(revoker.revoked, [(g1.package!, album)]);
      expect(() => service.resolve(album), throwsA(isA<DocumentsFailure>()));
      host.set(library());
      expect(id('Music/Album'), isNot(album));
    },
  );

  test(
    'ids of items gone from the projection are pruned after the grace',
    () async {
      final secret = id('Private/secret.txt');
      await service.approve(g1.package!, 'Private', AccessMode.read);
      host.set([
        for (final e in library())
          if (!(e['path'] as String).startsWith('Private')) e,
      ]);
      expect(service.approvals, hasLength(1), reason: 'within the grace');
      now = now.add(const Duration(minutes: 6));
      host.set([
        for (final e in library())
          if (!(e['path'] as String).startsWith('Private')) e,
      ]);
      expect(service.approvals, isEmpty);
      expect(() => service.resolve(secret), throwsA(isA<DocumentsFailure>()));
    },
  );

  test(
    'creates show at once and listings wait while the engine starts',
    () async {
      final created = await service.create(
        id('Music'),
        'new.txt',
        false,
        system,
      );
      expect(service.resolve(created).path, 'Music/new.txt');
      expect(names(service.children(id('Music'), system)), contains('new.txt'));
      host.documentsReady = false;
      host.set(const []);
      expect(service.children('root', system)['loading'], isTrue);
      expect(service.roots()['ready'], isFalse);
    },
  );

  test(
    'approvals persist across restarts; requests clear once approved',
    () async {
      expect(() => service.children(id('Music'), g3), denied());
      await service.approve(g3.package!, 'Music', AccessMode.write);
      expect(service.requests, isEmpty);
      service.dispose();
      store.close();
      store = AccessStore(profile, clock: () => now);
      service = DocumentsService(
        host,
        store,
        revoker: revoker,
        clock: () => now,
      );
      expect(service.approvals.single.mode, AccessMode.write);
      expect(names(service.children(id('Music'), g3)), ['Album', 'loose.flac']);
    },
  );

  test('open descriptors are counted per app until closed', () async {
    await service.approve(g1.package!, 'Music', AccessMode.read);
    final open = await service.open(id('Music/loose.flac'), 'r', g1);
    await service.revoke(g1.package!, 'Music');
    expect(service.approvals.single.openFiles, 1);
    await service.closed(open['token'] as String);
    expect(service.approvals.single.openFiles, 0);
    expect(host.commands.last.$1, 'closed');
  });

  test("the app's own rename keeps ids and approvals (review F3)", () async {
    final album = id('Music/Album');
    await service.approve(g1.package!, 'Music/Album', AccessMode.read);
    host.onLocalRename!('Music/Album', 'Music/Record');
    expect(service.approvals.single.folder, 'Music/Record');
    host.set([
      for (final e in library())
        if ((e['path'] as String).startsWith('Music/Album'))
          {...e, 'path': (e['path'] as String).replaceFirst('Album', 'Record')}
        else
          e,
    ]);
    expect(service.resolve(album).path, 'Music/Record');
    expect(names(service.children(album, g1)), ['track.mp3']);
  });

  test(
    'a different folder at an approved path does not inherit it (review F3)',
    () async {
      List<Map<String, dynamic>> withIdentity(String identity) => [
        for (final e in library())
          if (e['path'] == 'Music') {...e, 'localIdentity': identity} else e,
      ];
      host.set(withIdentity('dev:100'));
      final music = id('Music');
      await service.approve(g1.package!, 'Music', AccessMode.read);
      host.set(withIdentity('dev:100'));
      expect(names(service.children(music, g1)), ['Album', 'loose.flac']);
      // Renamed through the provider: same inode, approval kept.
      host.set(withIdentity('dev:100'));
      expect(service.approvals, hasLength(1));
      // Replaced by another folder of the same name.
      revoker.trees = [music];
      host.set(withIdentity('dev:200'));
      await Future<void>.delayed(Duration.zero);
      expect(service.approvals, isEmpty);
      expect(() => service.children(id('Music'), g1), denied());
      expect(id('Music'), isNot(music));
      expect(revoker.revoked, [(g1.package!, music)]);
    },
  );

  test(
    'a read-only document grant does not hide a folder approval (review F4)',
    () async {
      const viewer = DocumentsCaller(
        CallerKind.document,
        package: 'cloud.anj.anj_cloud.qa.grantee1',
        documentRead: true,
      );
      await expectLater(
        service.open(id('Music/loose.flac'), 'rw', viewer),
        denied(),
      );
      await service.approve(g1.package!, 'Music', AccessMode.write);
      await service.open(id('Music/loose.flac'), 'rw', viewer);
      expect(host.commands.last.$2['write'], isTrue);
      expect(service.document(id('Music/loose.flac'), viewer)['write'], isTrue);
      await service.rename(id('Music/loose.flac'), 'x.flac', viewer);
      // Without the approval, still only the one document, read-only.
      await expectLater(
        service.open(id('Private/secret.txt'), 'rw', viewer),
        denied(),
      );
    },
  );

  test(
    'open tokens are unique even within one microsecond (review F5)',
    () async {
      await service.approve(g1.package!, 'Music', AccessMode.read);
      final fixed = DateTime(2026, 11, 4, 12);
      now = fixed;
      final tokens = <String>{
        for (var i = 0; i < 20; i++)
          (await service.open(id('Music/loose.flac'), 'r', g1))['token']
              as String,
      };
      expect(tokens, hasLength(20));
      await service.closed(tokens.first);
      final again = await service.open(id('Music/loose.flac'), 'r', g1);
      expect(tokens, isNot(contains(again['token'])));
    },
  );
}
