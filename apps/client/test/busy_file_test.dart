import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A boundary whose reads of [busy] paths fail as Windows' do while another
/// program holds the file without read sharing (EBUSY, SC-048 F5).
class _BusyFs extends NativeRootFs {
  final busy = <String>{};
  @override
  ({String hash, String stamp}) copyAndHashStamped(
    int root,
    String relative,
    File? destination, {
    String purpose = 'content',
  }) {
    if (busy.contains(relative)) {
      throw FileSystemException(
        'Filesystem boundary refused operation',
        relative,
        const OSError('Linux errno', fileBusyErrno),
      );
    }
    return super.copyAndHashStamped(
      root,
      relative,
      destination,
      purpose: purpose,
    );
  }
}

/// Runs [onListing] when the engine lists the server: after this pass's
/// local scan, before its delete dispatch.
class _HookCloud extends FakeCloud {
  void Function()? onListing;
  @override
  Future<List<RemoteItem>> snapshot() async {
    onListing?.call();
    return super.snapshot();
  }
}

/// Spec #32 W4, SC-048 F5: a file another program holds open is skipped,
/// shown as busy and retried; the pass goes on for everything else.
void main() {
  late Directory fixture;
  late _BusyFs fs;
  late RootTree tree;
  late Manifest store;
  late _HookCloud cloud;
  late SyncEngine engine;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-busy-test-');
    final parent = Directory('${fixture.path}/a')..createSync();
    fs = _BusyFs();
    tree = RootTree.setup(parent.path, 'a', fs);
    store = Manifest(Directory('${fixture.path}/profile-a'));
    store.setSetting('retention', 'local');
    cloud = _HookCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) =>
      File('${tree.root.path}/$path')..parent.createSync(recursive: true);
  String remote(String path) => utf8.decode(cloud.files[path]!);

  test(
    'a busy file is skipped, shown busy, and synced once released',
    () async {
      local('Documents/held.txt').writeAsStringSync('v1');
      local('Documents/other.txt').writeAsStringSync('o1');
      await engine.tick();
      expect(remote('Documents/held.txt'), 'v1');
      local('Documents/held.txt').writeAsStringSync('v2');
      local('Documents/other.txt').writeAsStringSync('o2');
      fs.busy.add('Documents/held.txt');
      await engine.tick();
      // The pass went on: the other file synced; the busy one waits.
      expect(remote('Documents/other.txt'), 'o2');
      expect(remote('Documents/held.txt'), 'v1');
      expect(store.entries['Documents/held.txt']!.status, fileBusyStatus);
      expect(tree.busy, {'Documents/held.txt'});
      fs.busy.clear();
      await engine.tick();
      expect(remote('Documents/held.txt'), 'v2');
      expect(
        isBusyStatus(store.entries['Documents/held.txt']!.status),
        isFalse,
      );
      expect(tree.busy, isEmpty);
    },
  );

  test('a busy file is never taken for deleted', () async {
    local('Documents/held.txt').writeAsStringSync('v1');
    await engine.tick();
    fs.busy.add('Documents/held.txt');
    await engine.tick();
    await engine.tick();
    expect(cloud.files.containsKey('Documents/held.txt'), isTrue);
    expect(cloud.deletes, 0);
    expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
  });

  test('a remote change to a busy file waits; the local bytes stay', () async {
    local('Documents/held.txt').writeAsStringSync('v1');
    await engine.tick();
    fs.busy.add('Documents/held.txt');
    cloud.put('Documents/held.txt', 'remote v2');
    await engine.tick();
    expect(local('Documents/held.txt').readAsStringSync(), 'v1');
    fs.busy.clear();
    await engine.tick();
    expect(local('Documents/held.txt').readAsStringSync(), 'remote v2');
  });

  test(
    'a new file that is busy is not uploaded until it can be read',
    () async {
      await engine.tick();
      local('Documents/new.txt').writeAsStringSync('n1');
      fs.busy.add('Documents/new.txt');
      await engine.tick();
      expect(cloud.files.containsKey('Documents/new.txt'), isFalse);
      // It has a busy row although it was never synchronized.
      expect(store.entries['Documents/new.txt']!.status, fileBusyStatus);
      fs.busy.clear();
      await engine.tick();
      expect(remote('Documents/new.txt'), 'n1');
    },
  );

  test('a new busy file removed while busy leaves no busy row', () async {
    await engine.tick();
    local('Documents/new.txt').writeAsStringSync('n1');
    fs.busy.add('Documents/new.txt');
    await engine.tick();
    expect(store.entries['Documents/new.txt']!.status, fileBusyStatus);
    local('Documents/new.txt').deleteSync();
    fs.busy.clear();
    await engine.tick();
    expect(store.entries['Documents/new.txt']!.status, 'removed locally');
    expect(cloud.deletes, 0);
  });

  test('a partial listing decides its paths afresh (scanTree)', () async {
    local('Documents/held.txt').writeAsStringSync('v1');
    local('Other/keep.txt').writeAsStringSync('k1');
    fs.busy.addAll({'Documents/held.txt', 'Other/keep.txt'});
    await tree.snapshot();
    expect(tree.busy, {'Documents/held.txt', 'Other/keep.txt'});
    fs.busy.clear();
    tree.scanTree('Documents', recursive: true);
    // Released and listed again: no longer busy. Outside the listing the
    // last decision stands until that path is read again.
    expect(tree.busy, {'Other/keep.txt'});
    tree.scanTree('', recursive: true);
    expect(tree.busy, isEmpty);
  });

  test('a busy file deleted, then seen only by a partial scan of its '
      'folder, leaves no busy path', () async {
    local('Documents/held.txt').writeAsStringSync('v1');
    local('Other/keep.txt').writeAsStringSync('k1');
    fs.busy.addAll({'Documents/held.txt', 'Other/keep.txt'});
    await tree.snapshot();
    expect(tree.busy, {'Documents/held.txt', 'Other/keep.txt'});
    // Gone while busy: no read of it can clear the busy path, only the
    // listing of its folder deciding afresh.
    local('Documents/held.txt').deleteSync();
    final listed = tree.scanTree('Documents', recursive: false).items;
    expect(listed.containsKey('Documents/held.txt'), isFalse);
    expect(tree.busy, {'Other/keep.txt'});
  });

  test('a delete and recreate between passes is an edit, not a delete '
      '(Paint saves this way)', () async {
    local('Pictures/pic.png').writeAsStringSync('p1');
    await engine.tick();
    final first = cloud.versions['Pictures/pic.png'];
    final id = cloud.fileIds['Pictures/pic.png'];
    // The editor deletes the file; the pass that sees it gone cannot reach
    // the server, so the inferred delete stays queued.
    local('Pictures/pic.png').deleteSync();
    cloud.online = false;
    await engine.tick();
    expect(
      store.operations.values.where((o) => o.kind == 'delete'),
      hasLength(1),
    );
    // The new file lands under the same name before the next pass.
    local('Pictures/pic.png').writeAsStringSync('p2');
    cloud.online = true;
    await engine.tick();
    await engine.tick();
    expect(cloud.deletes, 0);
    expect(remote('Pictures/pic.png'), 'p2');
    // Uploaded over the same server file: a new version of it.
    expect(cloud.versions['Pictures/pic.png'], isNot(first));
    expect(cloud.fileIds['Pictures/pic.png'], id);
    expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    expect(store.entries['Pictures/pic.png']!.status, 'current local');
  });

  test('a recreate between the scan and the delete dispatch withdraws the '
      'delete', () async {
    local('Pictures/pic.png').writeAsStringSync('p1');
    await engine.tick();
    final id = cloud.fileIds['Pictures/pic.png'];
    local('Pictures/pic.png').deleteSync();
    // The scan of this pass sees it gone; it is back before the dispatch.
    cloud.onListing = () => local('Pictures/pic.png').writeAsStringSync('p2');
    await engine.tick();
    cloud.onListing = null;
    await engine.tick();
    expect(cloud.deletes, 0);
    expect(remote('Pictures/pic.png'), 'p2');
    expect(cloud.fileIds['Pictures/pic.png'], id);
  });

  /// Both orders of a delete and recreate (a Paint save) racing another
  /// device's edit of the same file: an edit/edit conflict on a present file,
  /// which Keep both resolves, never a delete/edit conflict stuck on it.
  Future<void> keepBothResolves(String localBytes) async {
    final entry = store.entries['Pictures/pic.png']!;
    expect(entry.conflict, isNotNull);
    expect(entry.conflict, isNot(contains('Delete/edit')));
    expect(entry.expectedPresent, isTrue);
    expect(cloud.deletes, 0);
    await engine.keepBoth('Pictures/pic.png');
    await engine.tick();
    await engine.tick();
    expect(entry.conflict, isNull);
    expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    // The other device's bytes stay under the name; this device's save is
    // kept beside them, on disk and on the server.
    expect(remote('Pictures/pic.png'), 'r2-other-device');
    expect(local('Pictures/pic.png').readAsStringSync(), 'r2-other-device');
    final copies = cloud.files.keys
        .where((k) => k.startsWith('Pictures/pic.png.conflict-'))
        .toList();
    expect(copies, hasLength(1));
    expect(remote(copies.single), localBytes);
    expect(local(copies.single).readAsStringSync(), localBytes);
  }

  test('a recreate between passes meeting a server edit is an edit/edit '
      'conflict that Keep both resolves', () async {
    local('Pictures/pic.png').writeAsStringSync('p1');
    await engine.tick();
    local('Pictures/pic.png').deleteSync();
    cloud.online = false;
    await engine.tick();
    local('Pictures/pic.png').writeAsStringSync('p2-local');
    cloud.put('Pictures/pic.png', 'r2-other-device');
    cloud.online = true;
    await engine.tick();
    await engine.tick();
    await keepBothResolves('p2-local');
  });

  test('a recreate between the scan and the send meeting a server edit is '
      'an edit/edit conflict that Keep both resolves', () async {
    local('Pictures/pic.png').writeAsStringSync('p1');
    await engine.tick();
    local('Pictures/pic.png').deleteSync();
    cloud.onListing = () {
      local('Pictures/pic.png').writeAsStringSync('p2-local');
      cloud.put('Pictures/pic.png', 'r2-other-device');
    };
    await engine.tick();
    cloud.onListing = null;
    await engine.tick();
    await keepBothResolves('p2-local');
  });
}
