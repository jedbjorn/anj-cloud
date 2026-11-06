import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';

void main() {
  test('failed saved editor upload needs attention with reason and ancestor attention across restart, then clears', () async {
    final fixture = Directory.systemTemp.createTempSync('anj-ui-upload-error-');
    final parent = Directory('${fixture.path}/files')..createSync();
    var tree = RootTree.setup(parent.path, 'ui-errors', NativeRootFs());
    final rootPath = tree.root.path;
    final stagePath = tree.staging.path;
    final profile = Directory('${fixture.path}/profile');
    var store = Manifest(profile)..setSetting('retention', 'cloud');
    final cloud = FakeCloud()..put('Library/edited.txt', 'original');
    var engine = SyncEngine(store, tree, cloud);
    try {
      await engine.tick();
      final copy = File(await engine.openFile('Library/edited.txt'));
      copy.writeAsStringSync('saved result', flush: true);
      cloud.failUpload = true;
      await engine.tick();
      var projection = Map<String, dynamic>.from(
        await projectEntry(engine, store.entries['Library/edited.txt']!),
      );
      expect(fileBadge(projection), 'Needs attention');
      expect(libraryStatus(projection), contains('injected I/O failure'));
      expect(
        (projection['presentationErrors'] as List).single,
        contains('injected I/O failure'),
      );
      expect(
        libraryRows(
          [projection],
          LibraryTab.home,
          {'Library'},
        ).single.attention,
        true,
      );
      expect(
        String.fromCharCodes(cloud.files['Library/edited.txt']!),
        'original',
      );
      expect(copy.readAsStringSync(), 'saved result');
      engine.close();
      tree = RootTree(
        Directory(rootPath),
        Directory(stagePath),
        NativeRootFs(),
      );
      store = Manifest(profile);
      engine = SyncEngine(store, tree, cloud);
      projection = Map<String, dynamic>.from(
        await projectEntry(engine, store.entries['Library/edited.txt']!),
      );
      expect(fileBadge(projection), 'Needs attention');
      expect(needsAttention(projection), true);
      cloud.failUpload = false;
      await engine.tick();
      projection = Map<String, dynamic>.from(
        await projectEntry(engine, store.entries['Library/edited.txt']!),
      );
      expect(projection['presentationErrors'], isEmpty);
      // The editor copy is still open.
      expect(fileBadge(projection), 'Editing');
      expect(needsAttention(projection), false);
      expect(
        String.fromCharCodes(cloud.files['Library/edited.txt']!),
        'saved result',
      );
      expect(engine.retention('Library/edited.txt').name, 'cloud');
    } finally {
      engine.close();
      fixture.deleteSync(recursive: true);
    }
  });
  test('durable completion request remains in Editing after working row was removed', () async {
    final fixture = Directory.systemTemp.createTempSync(
      'anj-ui-finish-projection-',
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    final tree = RootTree.setup(parent.path, 'ui-finish', NativeRootFs());
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'cloud');
    final cloud = FakeCloud()..put('Library/edit.txt', 'synthetic result');
    final engine = SyncEngine(store, tree, cloud);
    try {
      await engine.tick();
      await engine.openFile('Library/edit.txt');
      final sessions = engine
          .workingCopies('Library/edit.txt')
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      engine.editing.request('Library/edit.txt', sessions);
      store.operations.remove(sessions.single['id']);
      store.save();
      final projection = Map<String, dynamic>.from(
        await projectEntry(engine, store.entries['Library/edit.txt']!),
      );
      expect(projection['workingCopies'], isEmpty);
      expect(projection['finishPending'], true);
      expect(
        libraryRows([projection], LibraryTab.editing, {}).map((r) => r.path),
        ['Library', 'Library/edit.txt'],
      );
      // The amber bar stays; the badge names the pending finish.
      expect(fileBadge(projection), 'Editing');
      expect(needsAttention(projection), true);
      expect(hasProblem(projection), false);
    } finally {
      engine.close();
      fixture.deleteSync(recursive: true);
    }
  });
}
