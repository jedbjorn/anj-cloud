import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/sync/case_moves.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Nextcloud 33 permissions as observed on a throwaway stack (spec #26).
const viewFolder = 'SGDN';
const viewFile = 'SG';
const editFolder = 'SGDNVCK';
const editFile = 'SGDNVW';
const ownFolder = 'RGDNVCK';
const ownFile = 'RGDNVW';

/// [FakeCloud] with listing permissions, share types and the gateway's
/// sharing routes. [hidden]: an incoming mount Nextcloud no longer lists
/// (owner disabled, or unshared).
class SharingCloud extends FakeCloud implements SharingApi {
  final Map<String, String> permissions = {};
  final Set<String> shared = {};
  final Set<String> hidden = {};

  /// Paths listed without `oc:permissions` (an older server or proxy).
  final Set<String> noPermissions = {};
  List<IncomingShare>? incoming = [];
  bool failIncoming = false;
  List<OutgoingShare> outgoing = [];
  int incomingCalls = 0;
  int outgoingCalls = 0;
  int sharingCalls = 0;

  /// The mount holding [path]: under `Shared/`, or a placed share (spec #34
  /// P6) that [setShare] made.
  String? mountOf(String path) {
    final shared = incomingMountOf(path);
    if (shared != null) return shared;
    final parts = path.split('/');
    if (parts.length < 2) return null;
    final mount = '${parts[0]}/${parts[1]}';
    return isPlacedMountPlace(mount) && permissions.containsKey(mount)
        ? mount
        : null;
  }

  String? _permissions(String path, ItemKind kind) {
    if (noPermissions.contains(path)) return null;
    if (permissions[path] case final value?) return value;
    final mount = mountOf(path);
    final folder = mount == null ? null : permissions[mount];
    if (folder != null) {
      final view = permissionsViewOnly(folder, directory: true);
      return kind == ItemKind.directory
          ? (view ? viewFolder : editFolder)
          : (view ? viewFile : editFile);
    }
    return kind == ItemKind.directory ? ownFolder : ownFile;
  }

  /// Changes a share's permission for the mount and everything in it.
  void setShare(String mount, SharePermission permission) {
    permissions.removeWhere((path, _) => mountOf(path) == mount);
    permissions[mount] = permission == SharePermission.view
        ? viewFolder
        : editFolder;
  }

  @override
  Future<List<RemoteItem>> snapshot() async => [
    for (final item in await super.snapshot())
      if (!hidden.contains(mountOf(item.path)))
        RemoteItem(
          item.path,
          item.kind,
          item.etag,
          size: item.size,
          fileId: item.fileId,
          modified: item.modified,
          permissions: _permissions(item.path, item.kind),
          shared: shared.contains(item.path),
        ),
  ];

  @override
  Future<List<IncomingShare>?> incomingShares() async {
    check();
    incomingCalls++;
    sharingCalls++;
    if (failIncoming) throw const CloudFailure('incoming list failed');
    return incoming;
  }

  @override
  Future<List<OutgoingShare>> outgoingShares() async {
    outgoingCalls++;
    sharingCalls++;
    return outgoing;
  }

  @override
  Future<List<HouseholdUser>> householdUsers() async {
    sharingCalls++;
    return const [HouseholdUser('bob', 'Bob')];
  }

  @override
  Future<OutgoingShare> createShare(
    String path,
    String recipientId,
    SharePermission permission,
  ) async {
    sharingCalls++;
    return OutgoingShare('9', path, recipientId, 'Bob', permission);
  }

  @override
  Future<OutgoingShare> updateShare(
    String shareId,
    SharePermission permission,
  ) async {
    sharingCalls++;
    return OutgoingShare(shareId, 'x', 'bob', 'Bob', permission);
  }

  @override
  Future<void> removeShare(String shareId) async => sharingCalls++;

  /// Moving a mount moves it for this account (Nextcloud keeps the new
  /// target; the gateway's incoming list follows).
  @override
  Future<void> move(String from, String to, {required String etag}) async {
    await super.move(from, to, etag: etag);
    String renamed(String v) => to + v.substring(from.length);
    incoming = [
      for (final share in incoming ?? const <IncomingShare>[])
        share.path == from
            ? IncomingShare(
                share.shareId,
                to,
                share.ownerName,
                share.permission,
              )
            : share,
    ];
    for (final key
        in permissions.keys.where((v) => withinOrAt(from, v)).toList()) {
      permissions[renamed(key)] = permissions.remove(key)!;
    }
  }

  /// Share IDs left, in order; [failForEveryone] makes the next leaves
  /// and renames fail with it.
  final List<String> left = [];
  final List<(String, String)> renamedForEveryone = [];
  CloudFailure? failForEveryone;

  /// The owner's folder and this account's mount take [name].
  @override
  Future<String?> renameForEveryone(String shareId, String name) async {
    check();
    sharingCalls++;
    if (failForEveryone case final failure?) throw failure;
    renamedForEveryone.add((shareId, name));
    final from = incoming!.firstWhere((s) => s.shareId == shareId).path;
    final to = '${p.posix.dirname(from)}/$name';
    await super.move(from, to, etag: versions[from]!);
    String renamed(String v) => to + v.substring(from.length);
    incoming = [
      for (final share in incoming!)
        share.shareId == shareId
            ? IncomingShare(shareId, to, share.ownerName, share.permission)
            : share,
    ];
    for (final key
        in permissions.keys.where((v) => withinOrAt(from, v)).toList()) {
      permissions[renamed(key)] = permissions.remove(key)!;
    }
    return to;
  }

  void _dropMount(String shareId) {
    final mount = incoming!.firstWhere((s) => s.shareId == shareId).path;
    incoming = [
      for (final share in incoming!)
        if (share.shareId != shareId) share,
    ];
    for (final path in [...files.keys].where((v) => withinOrAt(mount, v))) {
      remove(path);
    }
    directories.removeWhere((v) => withinOrAt(mount, v));
    versions.removeWhere((v, _) => withinOrAt(mount, v));
    permissions.removeWhere((v, _) => withinOrAt(mount, v));
  }

  /// The share ends for this account: its folder leaves this view; the
  /// owner's folder is not part of this fake.
  @override
  Future<void> leaveShare(String shareId) async {
    check();
    sharingCalls++;
    if (failForEveryone case final failure?) throw failure;
    left.add(shareId);
    _dropMount(shareId);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late SharingCloud cloud;
  late SyncEngine engine;
  var now = Duration.zero;

  /// Passes with the fake clock past the deletion settle.
  Future<void> settle([int passes = 2]) async {
    for (var i = 0; i < passes; i++) {
      now += const Duration(minutes: 1);
      await engine.tick();
    }
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-sharing-test-');
    final parent = Directory('${fixture.path}/a')..createSync();
    tree = RootTree.setup(parent.path, 'a', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = SharingCloud();
    now = Duration.zero;
    // Deletions inside share and top folders wait for the settle (#91).
    engine = SyncEngine(store, tree, cloud)..debugElapsed = () => now;
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  String text(String path) => local(path).readAsStringSync();

  /// Alice's folder shared with this account (Bob) at Shared/Photos.
  Future<void> incomingShare(SharePermission permission) async {
    for (final folder in ['Shared', 'Shared/Photos']) {
      cloud.directories.add(folder);
      cloud.versions[folder] = '"d-$folder"';
    }
    cloud.put('Shared/Photos/a.txt', 'owner bytes');
    cloud.setShare('Shared/Photos', permission);
    cloud.incoming = [IncomingShare('7', 'Shared/Photos', 'Alice', permission)];
    await engine.tick();
    expect(text('Shared/Photos/a.txt'), 'owner bytes');
  }

  int attempts() => cloud.uploadAttempts + cloud.deletes;

  test('decision #160: a Shared/ mount deleted and a new folder made there '
      'on its reused file number: no MOVE, the share is left, the new folder '
      'uploads as this account\'s own', () async {
    await incomingShare(SharePermission.edit);
    await engine.tick();
    expect(store.entries['Shared/Photos']!.localIdentity, isNotNull);
    Directory('${tree.root.path}/Shared/Photos').deleteSync(recursive: true);
    tree.ensureDirectory('Shared/Mine');
    local('Shared/Mine/mine.txt').writeAsStringSync('mine');
    store.entries['Shared/Photos']!.localIdentity = tree
        .statItem('Shared/Mine')!
        .identity!;
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.renamedForEveryone, isEmpty);
    expect(cloud.left, ['7']);
    expect(String.fromCharCodes(cloud.files['Shared/Mine/mine.txt']!), 'mine');
  });

  group('a folder this account shares out (decision #162)', () {
    Future<void> sharedTaxes() async {
      tree.ensureDirectory('Documents/Taxes');
      local('Documents/Taxes/a.txt').writeAsStringSync('mine');
      await engine.tick();
      cloud.shared.add('Documents/Taxes');
      await engine.tick();
      expect(store.entries['Documents/Taxes']!.sharedOut, isTrue);
      expect(store.entries['Documents/Taxes']!.localIdentity, isNotNull);
      expect(store.entries['Documents/Taxes/a.txt']!.localIdentity, isNotNull);
    }

    test('deleted, and a new folder made in the same pass on its reused file '
        'number: no MOVE, never deleted for everyone (restored), the new '
        'folder uploads unshared (decision #162)', () async {
      await sharedTaxes();
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      tree.ensureDirectory('Documents/Receipts');
      local('Documents/Receipts/private.txt').writeAsStringSync('private');
      // The number the shared folder had, now the new folder's (ext4, XFS).
      store.entries['Documents/Taxes']!.localIdentity = tree
          .statItem('Documents/Receipts')!
          .identity!;
      await engine.tick();
      await settle();
      expect(cloud.moves, isEmpty);
      expect(cloud.deletes, 0);
      expect(
        store.operations.values.where((o) => o.kind == 'delete'),
        isEmpty,
      );
      expect(text('Documents/Taxes/a.txt'), 'mine');
      expect(String.fromCharCodes(cloud.files['Documents/Taxes/a.txt']!), 'mine');
      expect(
        String.fromCharCodes(cloud.files['Documents/Receipts/private.txt']!),
        'private',
      );
      expect(cloud.shared, isNot(contains('Documents/Receipts')));
      expect(store.entries['Documents/Receipts']!.sharedOut, isFalse);
    });

    test('renamed with its files: one MOVE, the share follows', () async {
      await sharedTaxes();
      Directory('${tree.root.path}/Documents/Taxes')
          .renameSync('${tree.root.path}/Documents/Taxes 2025');
      await engine.tick();
      await settle();
      expect(cloud.moves, ['Documents/Taxes -> Documents/Taxes 2025']);
      expect(cloud.deletes, 0);
      expect(
        String.fromCharCodes(cloud.files['Documents/Taxes 2025/a.txt']!),
        'mine',
      );
    });
  });

  group('View only', () {
    test('an edit is kept in place as a conflict and never uploaded', () async {
      await incomingShare(SharePermission.view);
      final before = attempts();
      local('Shared/Photos/a.txt').writeAsStringSync('my edit');
      await engine.tick();
      await engine.tick();
      expect(attempts(), before);
      final entry = store.entries['Shared/Photos/a.txt']!;
      expect(entry.conflict, viewOnlyConflict);
      expect(text('Shared/Photos/a.txt'), 'my edit');
      expect(
        String.fromCharCodes(cloud.files['Shared/Photos/a.txt']!),
        'owner bytes',
      );
    });

    test('a new file or folder is not uploaded and its bytes stay', () async {
      await incomingShare(SharePermission.view);
      local('Shared/Photos/new.txt').writeAsStringSync('mine');
      tree.ensureDirectory('Shared/Photos/Sub');
      await engine.tick();
      expect(cloud.uploadAttempts, 0);
      expect(cloud.directories.contains('Shared/Photos/Sub'), isFalse);
      expect(
        store.entries['Shared/Photos/new.txt']!.conflict,
        viewOnlyConflict,
      );
      expect(store.entries['Shared/Photos/Sub']!.conflict, viewOnlyConflict);
      expect(text('Shared/Photos/new.txt'), 'mine');
    });

    test(
      'a deleted unmodified file returns from the cloud with the reason',
      () async {
        await incomingShare(SharePermission.view);
        local('Shared/Photos/a.txt').deleteSync();
        await engine.tick();
        expect(cloud.deletes, 0);
        expect(
          store.operations.values.where((o) => o.kind == 'delete'),
          isEmpty,
        );
        expect(text('Shared/Photos/a.txt'), 'owner bytes');
        expect(store.entries['Shared/Photos/a.txt']!.status, viewOnlyRestored);
      },
    );

    test(
      'a rename restores the original and keeps the new name as a conflict',
      () async {
        await incomingShare(SharePermission.view);
        local('Shared/Photos/a.txt')
            .renameSync('${tree.root.path}/Shared/Photos/b.txt');
        await engine.tick();
        expect(attempts(), 0);
        expect(text('Shared/Photos/a.txt'), 'owner bytes');
        expect(text('Shared/Photos/b.txt'), 'owner bytes');
        expect(
          store.entries['Shared/Photos/b.txt']!.conflict,
          viewOnlyConflict,
        );
      },
    );

    test(
      'an owner change meanwhile keeps the local copy (existing conflict path)',
      () async {
        await incomingShare(SharePermission.view);
        local('Shared/Photos/a.txt').writeAsStringSync('my edit');
        cloud.put('Shared/Photos/a.txt', 'owner changed');
        await engine.tick();
        expect(cloud.uploadAttempts, 0);
        expect(store.entries['Shared/Photos/a.txt']!.conflict, isNotNull);
        expect(text('Shared/Photos/a.txt'), 'my edit');
      },
    );
  });

  test('downgrade turns a held change into a View only conflict; upgrade never uploads it', () async {
    await incomingShare(SharePermission.edit);
    cloud.failUpload = true;
    local('Shared/Photos/a.txt').writeAsStringSync('held edit');
    await engine.tick();
    expect(cloud.uploadAttempts, 1);
    cloud.failUpload = false;
    cloud.setShare('Shared/Photos', SharePermission.view);
    engine.uploads.retryAll();
    await engine.tick();
    expect(cloud.uploadAttempts, 1);
    expect(store.entries['Shared/Photos/a.txt']!.conflict, viewOnlyConflict);
    // Decision #80 (5): back to Can edit, the held conflict stays a conflict.
    cloud.setShare('Shared/Photos', SharePermission.edit);
    await engine.tick();
    await engine.tick();
    expect(cloud.uploadAttempts, 1);
    expect(store.entries['Shared/Photos/a.txt']!.conflict, viewOnlyConflict);
    expect(
      String.fromCharCodes(cloud.files['Shared/Photos/a.txt']!),
      'owner bytes',
    );
  });

  test('Can edit uploads normally', () async {
    await incomingShare(SharePermission.edit);
    local('Shared/Photos/a.txt').writeAsStringSync('bob edit');
    await engine.tick();
    expect(
      String.fromCharCodes(cloud.files['Shared/Photos/a.txt']!),
      'bob edit',
    );
    expect(store.entries['Shared/Photos/a.txt']!.conflict, isNull);
  });

  test("removing an incoming share's folder in Shared/ leaves the share after the settle (decision #157)", () async {
    await incomingShare(SharePermission.edit);
    Directory('${tree.root.path}/Shared/Photos').deleteSync(recursive: true);
    await engine.tick();
    expect(cloud.left, isEmpty, reason: 'not before the settle');
    expect(store.entries['Shared/Photos']!.status, leavingShare);
    await settle();
    expect(cloud.left, ['7']);
    expect(cloud.deletes, 0); // One leave, no file DELETEs.
    expect(Directory('${tree.root.path}/Shared/Photos').existsSync(), isFalse);
    expect(engine.incoming, isEmpty);
  });

  test("a recipient's own folder under Shared/ is not a mount: its deletion reaches the cloud", () async {
    await incomingShare(SharePermission.edit);
    tree.ensureDirectory('Shared/Mine');
    local('Shared/Mine/x.txt').writeAsStringSync('mine');
    await engine.tick();
    await engine.tick(); // Listed once: version and permissions recorded.
    expect(cloud.directories.contains('Shared/Mine'), isTrue);
    expect(store.entries['Shared/Mine']!.permissions, ownFolder);
    expect(engine.isIncomingMountPath('Shared/Mine'), isFalse);
    expect(engine.isIncomingMountPath('Shared/Photos'), isTrue);
    Directory('${tree.root.path}/Shared/Mine').deleteSync(recursive: true);
    await engine.tick();
    // An ordinary folder deletion: queued for the cloud (the fake does not
    // qualify folder DELETE), never restored as "leaving a share".
    expect(
      store.operations.values.where(
        (o) => o.kind == 'delete' && o.path == 'Shared/Mine',
      ),
      hasLength(1),
    );
    expect(Directory('${tree.root.path}/Shared/Mine').existsSync(), isFalse);
    expect(store.entries['Shared/Mine']!.status, isNot(sharedFolderRestoring));
    // The incoming share's own folder is left instead
    // (decision #154), once settled: never as ordinary file deletes.
    Directory('${tree.root.path}/Shared/Photos').deleteSync(recursive: true);
    await engine.tick();
    expect(store.entries['Shared/Photos']!.status, leavingShare);
  });

  test('fresh permissions win over a stale incoming list for a folder under Shared/', () async {
    await incomingShare(SharePermission.edit);
    tree.ensureDirectory('Shared/Mine');
    local('Shared/Mine/x.txt').writeAsStringSync('mine');
    // A stale incoming list still names Shared/Mine (kept from an earlier
    // pass: this pass's fetch fails), but the listing says it is our own.
    cloud.incoming = [
      ...cloud.incoming!,
      const IncomingShare('9', 'Shared/Mine', 'Alice', SharePermission.edit),
    ];
    await engine.tick();
    cloud.failIncoming = true;
    await engine.tick();
    expect(engine.incoming.containsKey('Shared/Mine'), isTrue);
    expect(store.entries['Shared/Mine']!.permissions, ownFolder);
    expect(engine.isIncomingMountPath('Shared/Mine'), isFalse);
    Directory('${tree.root.path}/Shared/Mine').deleteSync(recursive: true);
    await engine.tick();
    expect(
      store.operations.values.where(
        (o) => o.kind == 'delete' && o.path == 'Shared/Mine',
      ),
      hasLength(1),
    );
    expect(store.entries['Shared/Mine']!.status, isNot(sharedFolderRestoring));
    expect(engine.isIncomingMountPath('Shared/Photos'), isTrue);
  });

  test('while the incoming list was never read, an unlisted folder under Shared/ is restored', () async {
    cloud.failIncoming = true;
    for (final folder in ['Shared', 'Shared/Unknown']) {
      cloud.directories.add(folder);
      cloud.versions[folder] = '"d-$folder"';
      cloud.noPermissions.add(folder);
    }
    cloud.put('Shared/Unknown/a.txt', 'bytes');
    cloud.noPermissions.add('Shared/Unknown/a.txt');
    await engine.tick();
    expect(engine.isIncomingMountPath('Shared/Unknown'), isTrue);
    Directory('${tree.root.path}/Shared/Unknown').deleteSync(recursive: true);
    await engine.tick();
    expect(cloud.deletes, 0);
    expect(text('Shared/Unknown/a.txt'), 'bytes');
  });

  test('unshare: the folder leaves sync and an unsynced edit stays in place as a conflict', () async {
    await incomingShare(SharePermission.edit);
    cloud.put('Shared/Photos/b.txt', 'second');
    await engine.tick();
    cloud.online = false;
    local('Shared/Photos/a.txt').writeAsStringSync('unsynced edit');
    await engine.tick(); // Offline: recorded, not uploaded.
    cloud.online = true;
    // Alice removes Bob: the mount and the incoming row disappear.
    for (final path in ['Shared/Photos/a.txt', 'Shared/Photos/b.txt']) {
      cloud.remove(path);
    }
    cloud.directories.remove('Shared/Photos');
    cloud.incoming = [];
    await engine.tick();
    await engine.tick();
    expect(cloud.uploadAttempts, 0);
    expect(cloud.deletes, 0);
    // The engine's existing in-place conflict (#78 N3): the folder holding
    // unsynchronized work, with its bytes where they were; no recovery copy.
    expect(text('Shared/Photos/a.txt'), 'unsynced edit');
    expect(
      store.entries['Shared/Photos']!.conflict,
      'Remote folder deletion meets unsynchronized descendants. Local bytes retained.',
    );
    expect(store.operations.values.where((o) => o.kind == 'retained'), isEmpty);
  });

  group('placed in Documents, Music or Videos (spec #34 P6)', () {
    /// Alice's Documents/Taxes shared with this account (Bob), placed at
    /// Bob's Documents/Taxes by the gateway.
    Future<void> placedShare(SharePermission permission) async {
      for (final folder in ['Documents', 'Documents/Taxes']) {
        cloud.directories.add(folder);
        cloud.versions[folder] = '"d-$folder"';
      }
      cloud.put('Documents/Taxes/a.txt', 'owner bytes');
      cloud.put('Documents/mine.txt', 'mine');
      cloud.setShare('Documents/Taxes', permission);
      cloud.incoming = [
        IncomingShare('7', 'Documents/Taxes', 'Alice', permission),
      ];
      await engine.tick();
      // A watching engine may need a few passes to list.
      for (
        var i = 0;
        i < 20 && !local('Documents/Taxes/a.txt').existsSync();
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
    }

    test('into a share placed in Documents: a delete plus a create, never '
        'a MOVE (another storage, spec #33)', () async {
      await placedShare(SharePermission.edit);
      await engine.tick();
      expect(store.entries['Documents/mine.txt']!.localIdentity, isNotNull);
      local('Documents/mine.txt')
          .renameSync('${tree.root.path}/Documents/Taxes/mine.txt');
      await engine.tick();
      await settle();
      expect(cloud.moves, isEmpty);
      expect(cloud.files['Documents/mine.txt'], isNull);
      expect(
        String.fromCharCodes(cloud.files['Documents/Taxes/mine.txt']!),
        'mine',
      );
    });

    test('out of a share placed in Documents: a delete plus a create, never '
        'a MOVE (another storage, spec #33)', () async {
      await placedShare(SharePermission.edit);
      local('Documents/Taxes/new.txt').writeAsStringSync('new');
      await engine.tick();
      expect(
        store.entries['Documents/Taxes/new.txt']!.localIdentity,
        isNotNull,
      );
      local('Documents/Taxes/new.txt')
          .renameSync('${tree.root.path}/Documents/new.txt');
      await engine.tick();
      await settle();
      expect(cloud.moves, isEmpty);
      expect(cloud.files['Documents/Taxes/new.txt'], isNull);
      expect(String.fromCharCodes(cloud.files['Documents/new.txt']!), 'new');
    });

    test('the incoming list makes it a mount, never its name alone', () async {
      await placedShare(SharePermission.edit);
      expect(engine.isIncomingMountPath('Documents/Taxes'), isTrue);
      expect(engine.inIncomingShare('Documents/Taxes/a.txt'), isTrue);
      expect(engine.incoming['Documents/Taxes']!.ownerName, 'Alice');
      expect(engine.isIncomingMountPath('Documents/mine.txt'), isFalse);
      expect(engine.inIncomingShare('Documents'), isFalse);
      // A folder of the same shape the list does not name is the user's own.
      tree.ensureDirectory('Documents/Own');
      await engine.tick();
      expect(engine.isIncomingMountPath('Documents/Own'), isFalse);
      expect(engine.mountOf('Documents/Own/x'), isNull);
      // The list no longer names it: no longer a mount.
      cloud.incoming = [];
      await engine.tick();
      expect(engine.isIncomingMountPath('Documents/Taxes'), isFalse);
    });

    test('View only applies inside it like in Shared/', () async {
      await placedShare(SharePermission.view);
      final before = attempts();
      local('Documents/Taxes/a.txt').writeAsStringSync('my edit');
      local('Documents/mine.txt').writeAsStringSync('my own edit');
      await engine.tick();
      expect(engine.viewOnly('Documents/Taxes/a.txt'), isTrue);
      expect(engine.viewOnly('Documents/mine.txt'), isFalse);
      expect(
        store.entries['Documents/Taxes/a.txt']!.conflict,
        viewOnlyConflict,
      );
      expect(attempts(), before + 1); // Only the user's own file.
    });

    test('deleting it here leaves the share once settled; no file DELETEs, the owner\'s folder untouched (decision #157)', () async {
      await placedShare(SharePermission.edit);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      expect(cloud.left, isEmpty);
      expect(store.entries['Documents/Taxes']!.status, leavingShare);
      expect(
        Directory('${tree.root.path}/Documents/Taxes').existsSync(),
        isFalse,
        reason: 'nothing restored meanwhile',
      );
      await settle();
      expect(cloud.left, ['7']);
      expect(cloud.deletes, 0);
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
      expect(engine.incoming.containsKey('Documents/Taxes'), isFalse);
      expect(store.entries['Documents/Taxes/a.txt']!.expectedPresent, isFalse);
      await settle();
      expect(cloud.left, ['7']);
      expect(
        Directory('${tree.root.path}/Documents/Taxes').existsSync(),
        isFalse,
      );
      expect(text('Documents/mine.txt'), 'mine');
    });

    test('a View only share made earlier is left the same way', () async {
      await placedShare(SharePermission.view);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, ['7']);
      expect(cloud.deletes, 0);
    });

    test('a failed leave holds the folder and retries; nothing restored or deleted', () async {
      await placedShare(SharePermission.edit);
      cloud.failForEveryone = const CloudFailure(
        "The owner's device is needed",
        status: 409,
      );
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(
        Directory('${tree.root.path}/Documents/Taxes').existsSync(),
        isFalse,
      );
      expect(
        store.entries['Documents/Taxes']!.status,
        contains("The owner's device is needed"),
      );
      expect(store.entries['Documents/Taxes/a.txt']!.etag, isNotNull);
      cloud.failForEveryone = null;
      await settle();
      expect(cloud.left, ['7']);
      expect(cloud.deletes, 0);
    });

    test('deleting the whole top folder restores the share inside, never leaves it (decision #150)', () async {
      await placedShare(SharePermission.edit);
      Directory('${tree.root.path}/Documents').deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(engine.incoming.containsKey('Documents/Taxes'), isTrue);
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      expect(text('Documents/mine.txt'), 'mine');
    });

    test('an event-driven pass waits the SC-054 delay, then the settle, before leaving', () async {
      const settings = WatcherSettings(
        quiet: Duration(milliseconds: 150),
        maxDelay: Duration(seconds: 2),
      );
      engine.close();
      store = Manifest(Directory('${fixture.path}/profile-watched'))
        ..setSetting('retention', 'local');
      final parent = Directory('${fixture.path}/w')..createSync();
      tree = RootTree.setup(
        parent.path,
        'w',
        NativeRootFs(
          Platform.environment['ANJ_ROOTFS_LIBRARY'],
          'Linux errno',
          const Duration(minutes: 60),
        ),
      )..vmDirectory = '${fixture.path}/no-vm';
      engine =
          SyncEngine(store, tree, cloud, watchers: const LinuxChangeWatchers())
            ..watcherSettings = settings
            ..debugElapsed = () => now;
      await engine.startWatching();
      await placedShare(SharePermission.edit);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
      }
      expect(engine.eventDriven, isTrue);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(
        store.entries['Documents/Taxes']!.status,
        isNot(leavingShare),
        reason: 'missing for less than quiet',
      );
      now += settings.quiet;
      engine.markDirty('Documents/Taxes', descendants: true);
      await engine.tick();
      expect(cloud.left, isEmpty, reason: 'not before the settle');
      now += settings.maxDelay + settings.quiet;
      engine.markDirty('Documents/Taxes', descendants: true);
      await engine.tick();
      expect(cloud.left, ['7']);
    });

    for (final (label, from, to) in [
      ('a rename', 'Documents/Taxes', 'Documents/Taxes 2025'),
      ('a case-only rename', 'Documents/Taxes', 'Documents/taxes'),
    ]) {
      test(
        '$label in place renames it for everyone; nothing uploaded or deleted (decision #155)',
        () async {
          await placedShare(SharePermission.edit);
          // Right after arrival: the identity is recorded when the folder
          // is created here (review F-H2).
          Directory('${tree.root.path}/$from')
              .renameSync('${tree.root.path}/$to');
          await engine.tick();
          await engine.tick();
          expect(cloud.renamedForEveryone, [('7', p.posix.basename(to))]);
          expect(cloud.left, isEmpty);
          expect(engine.incoming.keys, [to]);
          expect(engine.isIncomingMountPath(to), isTrue);
          expect(cloud.uploadAttempts, 0);
          expect(cloud.deletes, 0);
          expect(store.entries['$to/a.txt']!.etag, isNotNull);
          expect(store.entries.containsKey('$from/a.txt'), isFalse);
        },
      );
    }

    test('a rename after a pass without a listing is still a rename for everyone (F-H2)', () async {
      await placedShare(SharePermission.edit);
      await engine.tick(remote: RemotePolicy.never);
      Directory('${tree.root.path}/Documents/Taxes')
          .renameSync('${tree.root.path}/Documents/Taxes 2025');
      await engine.tick();
      await settle();
      expect(cloud.renamedForEveryone, [('7', 'Taxes 2025')]);
      expect(cloud.left, isEmpty);
    });

    test('a share folder whose identity is not on record is never left; restored (F-H2)', () async {
      await placedShare(SharePermission.edit);
      // Its row carries the identity the index keeps (spec #33 I1).
      store.entries['Documents/Taxes']!.localIdentity = null;
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
    });

    test(
      'Shared deleted and created again empty: the shares in it are restored, never left (F-M2)',
      () async {
        await incomingShare(SharePermission.edit);
        await engine.tick();
        Directory('${tree.root.path}/Shared').deleteSync(recursive: true);
        Directory('${tree.root.path}/Shared').createSync();
        await engine.tick();
        await settle();
        expect(cloud.left, isEmpty);
        expect(cloud.deletes, 0);
        expect(text('Shared/Photos/a.txt'), 'owner bytes');
      },
      // ext4/f2fs give the recreated Shared its old inode number, so the
      // engine sees the same folder with the share gone and leaves it
      // (on-device run, inode probe in the PR #60 evidence). Fixed by the
      // identity lane (birth-time identity); runs on the VM host's btrfs.
      skip: Platform.isAndroid
          ? 'SC-074: a recreated Shared reuses its inode on ext4/f2fs'
          : false,
    );

    test('Shared deleted and created again empty on the same file number '
        '(ext4, f2fs): its birth time tells; the shares are restored, never '
        'left (SC-074)', skip: Platform.isLinux || Platform.isAndroid
            ? null
            : 'Linux and Android only: no folder birth time elsewhere',
        () async {
      // A stable filesystem modelled on the tmpfs fixture: folder birth
      // times are reported only where trusted.
      final fs = tree.native as NativeRootFs;
      fs.debugVolume(fsid: 0x5eed);
      addTearDown(fs.debugVolume);
      await incomingShare(SharePermission.edit);
      await engine.tick();
      final row = store.entries['Shared']!;
      final birth = row.localBirth;
      expect(birth, isNotNull);
      Directory('${tree.root.path}/Shared').deleteSync(recursive: true);
      Directory('${tree.root.path}/Shared').createSync();
      final fresh = tree.statItem('Shared')!;
      row
        ..localIdentity = fresh.identity
        ..localBirth = birth;
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(text('Shared/Photos/a.txt'), 'owner bytes');
    });

    test('a slow rm -rf Shared never leaves a share in it (F-M2)', () async {
      await incomingShare(SharePermission.edit);
      tree.ensureDirectory('Shared/Mine');
      local('Shared/Mine/x.txt').writeAsStringSync('mine');
      local('Shared/Mine/y.txt').writeAsStringSync('mine too');
      await engine.tick();
      await engine.tick();
      const step = Duration(seconds: 5); // Shorter than the settle.
      Directory('${tree.root.path}/Shared/Photos').deleteSync(recursive: true);
      now += step;
      await engine.tick();
      local('Shared/Mine/x.txt').deleteSync();
      now += step;
      await engine.tick();
      local('Shared/Mine/y.txt').deleteSync();
      now += step;
      await engine.tick();
      Directory('${tree.root.path}/Shared').deleteSync(recursive: true);
      now += step;
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(text('Shared/Photos/a.txt'), 'owner bytes');
      expect(text('Shared/Mine/x.txt'), 'mine');
    });

    test('decision #160: a share folder deleted and a new folder made in the '
        'same pass on its reused file number is never paired by it: no MOVE, '
        'the share is left, the new folder uploads as this account\'s own', () async {
      await placedShare(SharePermission.edit);
      await engine.tick();
      expect(store.entries['Documents/Taxes']!.localIdentity, isNotNull);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      tree.ensureDirectory('Documents/Receipts');
      local('Documents/Receipts/mine.txt').writeAsStringSync('mine');
      // The number the folder had, now the new folder's (ext4, XFS).
      store.entries['Documents/Taxes']!.localIdentity = tree
          .statItem('Documents/Receipts')!
          .identity!;
      await engine.tick();
      await settle();
      expect(cloud.moves, isEmpty);
      expect(cloud.renamedForEveryone, isEmpty);
      expect(cloud.left, ['7']);
      expect(cloud.deletes, 0);
      expect(
        String.fromCharCodes(cloud.files['Documents/Receipts/mine.txt']!),
        'mine',
      );
    });

    test('a reused file number alone is never a rename: delete the share, create another folder -> left (review G-H1)', () async {
      await placedShare(SharePermission.edit);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      tree.ensureDirectory('Documents/Receipts');
      local('Documents/Receipts/bob-private.txt')
          .writeAsStringSync('bob private');
      // ext4 and XFS can give the new folder the freed number.
      store.entries['Documents/Taxes']!.localIdentity = tree
          .statItem('Documents/Receipts')!
          .identity!;
      await engine.tick();
      await settle();
      expect(cloud.renamedForEveryone, isEmpty);
      expect(cloud.left, ['7']);
      expect(cloud.deletes, 0);
      expect(
        String.fromCharCodes(
          cloud.files['Documents/Receipts/bob-private.txt']!,
        ),
        'bob private',
      );
      expect(engine.incoming, isEmpty);
    });

    test('a View only share made earlier cannot be renamed for everyone: its old name comes back (review G-L2)', () async {
      await placedShare(SharePermission.view);
      cloud.failForEveryone = const CloudFailure(
        'This shared folder is View only',
        status: 403,
      );
      Directory('${tree.root.path}/Documents/Taxes')
          .renameSync('${tree.root.path}/Documents/Taxes 2025');
      await engine.tick();
      await engine.tick();
      expect(
        Directory('${tree.root.path}/Documents/Taxes 2025').existsSync(),
        isFalse,
      );
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      expect(cloud.uploadAttempts, 0);
      expect(cloud.left, isEmpty);
    });

    test('a rename to a name the owner has is refused: the folder here gets its old name back', () async {
      await placedShare(SharePermission.edit);
      await engine.tick();
      cloud.failForEveryone = const CloudFailure(
        'The owner already has a folder with this name',
        status: 409,
      );
      Directory('${tree.root.path}/Documents/Taxes')
          .renameSync('${tree.root.path}/Documents/Other');
      await engine.tick();
      await engine.tick();
      expect(
        Directory('${tree.root.path}/Documents/Other').existsSync(),
        isFalse,
      );
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      expect(cloud.uploadAttempts, 0);
      expect(cloud.left, isEmpty);
      expect(
        cloud.files.keys.where((v) => v.startsWith('Documents/Other')),
        isEmpty,
      );
    });

    test('a move into another folder keeps the share in place; the moved copy is this account\'s own', () async {
      await placedShare(SharePermission.edit);
      await engine.tick();
      tree.ensureDirectory('Documents/Archive');
      Directory('${tree.root.path}/Documents/Taxes')
          .renameSync('${tree.root.path}/Documents/Archive/Taxes');
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.renamedForEveryone, isEmpty);
      expect(cloud.deletes, 0);
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      expect(
        String.fromCharCodes(cloud.files['Documents/Archive/Taxes/a.txt']!),
        'owner bytes',
      );
      expect(engine.incoming.keys, ['Documents/Taxes']);
    });

    for (final (label, mount, list) in [
      for (final (label, mount) in [
        ('placed', 'Documents/Taxes'),
        ('Shared/', 'Shared/Taxes'),
      ])
        for (final list in [
          'listed',
          'list unreadable',
          'placed after the list',
        ])
          (label, mount, list),
    ]) {
      test(
        '$label, $list: a never-synchronized local folder of the same name is set aside, never merged into the share (review H1, D-H1)',
        () async {
          // Bob made this folder on this device; it is not uploaded yet.
          tree.ensureDirectory(mount);
          local('$mount/bob-private.txt').writeAsStringSync('bob private');
          cloud.online = false;
          await engine.tick();
          cloud.online = true;
          for (final folder in [p.posix.dirname(mount), mount]) {
            cloud.directories.add(folder);
            cloud.versions[folder] = '"d-$folder"';
          }
          cloud.put('$mount/a.txt', 'owner bytes');
          cloud.setShare(mount, SharePermission.edit);
          // D-H1: only the listing's `S` says it is a share when the
          // incoming list fails, or was read before the share was placed.
          cloud.incoming = list == 'placed after the list'
              ? []
              : [IncomingShare('7', mount, 'Alice', SharePermission.edit)];
          cloud.failIncoming = list == 'list unreadable';
          await engine.tick();
          await engine.tick();
          expect(cloud.files.keys.where((v) => v.startsWith('$mount/')), [
            '$mount/a.txt',
          ]);
          expect(text('$mount/a.txt'), 'owner bytes');
          expect(local('$mount/bob-private.txt').existsSync(), isFalse);
          expect(text('$mount (this device)/bob-private.txt'), 'bob private');
          expect(
            String.fromCharCodes(
              cloud.files['$mount (this device)/bob-private.txt']!,
            ),
            'bob private',
          );
        },
      );
    }

    // Review D-H2 / D-M1: a non-atomic delete (rm -rf, a permanent delete
    // in a file manager) removes children before their folder, and a pass
    // can run in between. Deletions inside a share folder or a top folder
    // are held for the settle (PR #91's rule) and resolved when sent: for
    // everyone only once the share folder itself is gone with its top
    // folder present; restored when the top folder is gone; ordinary
    // deletes when the folder is still there after the settle.
    test("D-H2: rm -rf of a placed share caught mid-way sends no file DELETE; the share is left", () async {
      await placedShare(SharePermission.edit);
      cloud.put('Documents/Taxes/b.txt', 'owner b');
      await engine.tick();
      local('Documents/Taxes/a.txt').deleteSync();
      await engine.tick(); // Mid-delete: the folder is still here.
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.deletes, 0);
      expect(cloud.left, ['7']);
    });

    test("D-H2: rm -rf of a Shared/ share caught mid-way sends no file DELETE; the share is left", () async {
      await incomingShare(SharePermission.edit);
      cloud.put('Shared/Photos/b.txt', 'owner b');
      await engine.tick();
      local('Shared/Photos/a.txt').deleteSync();
      await engine.tick();
      Directory('${tree.root.path}/Shared/Photos').deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.deletes, 0);
      expect(cloud.left, ['7']);
    });

    test('D-H2: rm -rf Documents caught mid-way deletes nothing and restores all, the share included', () async {
      await placedShare(SharePermission.edit);
      local('Documents/mine.txt').deleteSync();
      local('Documents/Taxes/a.txt').deleteSync();
      await engine.tick();
      Directory('${tree.root.path}/Documents').deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.deletes, 0);
      expect(cloud.left, isEmpty);
      expect(text('Documents/mine.txt'), 'mine');
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
    });

    test('D-M1: the share folder, then Documents, deleted across passes: restored, never left', () async {
      await placedShare(SharePermission.edit);
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      Directory('${tree.root.path}/Documents').deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(engine.incoming.containsKey('Documents/Taxes'), isTrue);
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
    });

    test(
      'a placed share inside Documents, then rm -rf Documents: restored',
      () async {
        await placedShare(SharePermission.edit);
        Directory('${tree.root.path}/Documents').deleteSync(recursive: true);
        await engine.tick();
        await settle();
        expect(cloud.left, isEmpty);
        expect(cloud.deletes, 0);
        expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      },
    );

    test('the stall case: a file deleted inside a share folder that stays is an ordinary delete after the settle', () async {
      await placedShare(SharePermission.edit);
      local('Documents/Taxes/a.txt').deleteSync();
      await engine.tick();
      expect(cloud.deletes, 0, reason: 'held for the settle');
      await settle();
      expect(cloud.deletes, 1);
      expect(cloud.left, isEmpty);
    });

    test('the stall case in Shared/: an ordinary delete after the settle, the share kept', () async {
      await incomingShare(SharePermission.edit);
      local('Shared/Photos/a.txt').deleteSync();
      await engine.tick();
      expect(cloud.deletes, 0, reason: 'held for the settle');
      await settle();
      expect(cloud.deletes, 1);
      expect(cloud.left, isEmpty);
    });

    test('a conflict inside keeps it: restored, not left', () async {
      await placedShare(SharePermission.edit);
      store.entries['Documents/Taxes/a.txt']!.conflict = 'held for review';
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
      expect(engine.incoming.containsKey('Documents/Taxes'), isTrue);
      expect(
        Directory('${tree.root.path}/Documents/Taxes').existsSync(),
        isTrue,
      );
    });

    test('a disabled owner holds it like a mount in Shared/', () async {
      await placedShare(SharePermission.edit);
      cloud.hidden.add('Documents/Taxes');
      cloud.incoming = [
        const IncomingShare(
          '7',
          'Documents/Taxes',
          'Alice',
          SharePermission.edit,
          ownerUnavailable: true,
        ),
      ];
      await engine.tick();
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
      expect(store.entries['Documents/Taxes']!.status, ownerUnavailableStatus);
      // Deleting it while held deletes nothing, for anyone.
      Directory('${tree.root.path}/Documents/Taxes')
          .deleteSync(recursive: true);
      await engine.tick();
      await settle();
      expect(cloud.left, isEmpty);
      expect(cloud.deletes, 0);
    });
  });

  group('local moves and storages (spec #33 I1)', () {
    Future<void> ownFile() async {
      local('Own.txt').writeAsStringSync('mine');
      await engine.tick();
      expect(cloud.files['Own.txt'], isNotNull);
    }

    test('into an incoming share: a delete plus a create, never a MOVE '
        '(a cross-storage move gets a new file ID)', () async {
      await incomingShare(SharePermission.edit);
      await ownFile();
      local('Own.txt').renameSync('${tree.root.path}/Shared/Photos/Own.txt');
      await engine.tick();
      await engine.tick();
      expect(cloud.moves, isEmpty);
      expect(cloud.files['Own.txt'], isNull);
      expect(
        String.fromCharCodes(cloud.files['Shared/Photos/Own.txt']!),
        'mine',
      );
      expect(cloud.deletes, 1);
    });

    test(
      'out of an incoming share: a delete plus a create, never a MOVE',
      () async {
        await incomingShare(SharePermission.edit);
        // Written here and synchronized: its identity is recorded.
        local('Shared/Photos/mine.txt').writeAsStringSync('mine');
        await engine.tick();
        expect(
          store.entries['Shared/Photos/mine.txt']!.localIdentity,
          isNotNull,
        );
        local('Shared/Photos/mine.txt')
            .renameSync('${tree.root.path}/Mine.txt');
        await engine.tick();
        // A deletion inside a share folder waits for the settle (#91).
        await settle();
        expect(cloud.moves, isEmpty);
        expect(String.fromCharCodes(cloud.files['Mine.txt']!), 'mine');
        expect(cloud.files['Shared/Photos/mine.txt'], isNull);
      },
    );

    test('into a paused owner\'s folder (#80): parked, the cloud item stays '
        'where it was and nothing is deleted', () async {
      await incomingShare(SharePermission.edit);
      await ownFile();
      cloud.hidden.add('Shared/Photos');
      cloud.incoming = [
        const IncomingShare(
          '7',
          'Shared/Photos',
          'Alice',
          SharePermission.edit,
          ownerUnavailable: true,
        ),
      ];
      await engine.tick(); // Learns the owner is unavailable.
      final deletes = cloud.deletes, uploads = cloud.uploadAttempts;
      local('Own.txt').renameSync('${tree.root.path}/Shared/Photos/Own.txt');
      await engine.tick();
      await engine.tick();
      expect(cloud.moves, isEmpty);
      expect(cloud.deletes, deletes);
      expect(cloud.uploadAttempts, uploads);
      expect(String.fromCharCodes(cloud.files['Own.txt']!), 'mine');
      expect(store.entries['Own.txt']!.status, movedHereStatus);
      expect(text('Shared/Photos/Own.txt'), 'mine');
    });
  });

  group('owner unavailable (decision #80 (2))', () {
    test('a disabled owner pauses only that folder; nothing is deleted; re-enable resumes', () async {
      await incomingShare(SharePermission.edit);
      local('Own.txt').writeAsStringSync('mine');
      cloud.hidden.add('Shared/Photos');
      cloud.incoming = [
        const IncomingShare(
          '7',
          'Shared/Photos',
          'Alice',
          SharePermission.edit,
          ownerUnavailable: true,
        ),
      ];
      local('Shared/Photos/a.txt').writeAsStringSync('edit while unavailable');
      await engine.tick();
      await engine.tick();
      expect(cloud.deletes, 0);
      expect(
        cloud.uploadAttempts,
        1,
      ); // Own.txt only: the rest of the root syncs.
      expect(text('Shared/Photos/a.txt'), 'edit while unavailable');
      expect(store.entries['Shared/Photos']!.status, ownerUnavailableStatus);
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
      expect(
        store.entries['Shared/Photos/a.txt']!.status,
        isNot(startsWith('deleted')),
      );
      // Re-enabled: the folder syncs normally again.
      cloud.hidden.clear();
      cloud.incoming = [
        IncomingShare('7', 'Shared/Photos', 'Alice', SharePermission.edit),
      ];
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Shared/Photos/a.txt']!),
        'edit while unavailable',
      );
      expect(store.entries['Shared/Photos']!.status, 'current local');
    });

    test('an unreadable incoming list pauses a vanished mount instead of inferring deletion', () async {
      await incomingShare(SharePermission.view);
      cloud.hidden.add('Shared/Photos');
      cloud.failIncoming = true;
      await engine.tick();
      expect(text('Shared/Photos/a.txt'), 'owner bytes');
      expect(
        store.entries['Shared/Photos/a.txt']!.status,
        isNot(startsWith('deleted')),
      );
    });
  });

  test('the shared indicator names are fetched when shared folders change, not every pass', () async {
    tree.ensureDirectory('Family');
    await engine.tick();
    cloud.shared.add('Family');
    cloud.outgoing = [
      const OutgoingShare('1', 'Family', 'bob', 'Bob', SharePermission.edit),
      const OutgoingShare('2', 'Family', 'alex', 'Alex', SharePermission.view),
    ];
    cloud.versions['Family'] = '"changed"';
    await engine.tick();
    expect(store.entries['Family']!.sharedOut, isTrue);
    expect(engine.outgoingNames['Family'], ['Alex', 'Bob']);
    final calls = cloud.outgoingCalls;
    await engine.tick();
    await engine.tick();
    expect(cloud.outgoingCalls, calls);
    expect(cloud.incomingCalls, greaterThanOrEqualTo(3));
  });

  test(
    'pause: the gate refuses every sharing call before any request',
    () async {
      final gate = PausableCloud(cloud)..paused = true;
      final calls = <Future<Object?> Function()>[
        gate.incomingShares,
        gate.outgoingShares,
        gate.householdUsers,
        () => gate.createShare('Family', 'bob', SharePermission.edit),
        () => gate.updateShare('1', SharePermission.view),
        () => gate.removeShare('1'),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<CloudFailure>()));
      }
      expect(cloud.sharingCalls, 0);
      expect(gate.refused, calls.length);
    },
  );
}
