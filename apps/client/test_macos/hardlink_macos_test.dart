// Hard links on APFS under the FSEvents watcher (PR #68 review finding 1,
// decisions #135 and #137): a second name for a synced file, edited under
// that name, must never read as a delete of the first. The fake-backed
// the VM host test is case_rename_test; this is the real APFS check. The M4
// mac-test run list (tool/macos/m4_window.sh) runs it against origin/main,
// where #68 lives. Run on mac-test with ANJ_MACOS_ROOTFS_LIBRARY.
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';

import '../test/fakes.dart';

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;

  setUp(() {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-hl-').resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'a hard link edited under its second name sends no cloud delete',
    () async {
      final parent = Directory('${fixture.path}/files')..createSync();
      final tree = RootTree.setup(
        parent.path,
        'root',
        const MacosPlatformAdapters().rootFilesystem(library),
      );
      final store = Manifest(Directory('${fixture.path}/profile'))
        ..setSetting('retention', 'local');
      final cloud = FakeCloud();
      final engine = SyncEngine(store, tree, cloud);
      try {
        await engine.startWatching();
        expect(engine.watcher, isNotNull, reason: 'APFS root: FSEvents');
        (engine.watcher! as LocalWatcher)
          ..quiet = const Duration(milliseconds: 150)
          ..maxDelay = const Duration(seconds: 2);
        // Passes until the watcher has nothing queued (bounded).
        Future<void> settle() async {
          for (var i = 0; i < 40; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            await engine.tick();
            if (i >= 3 && engine.watcher!.nextDeadline() == null) return;
          }
        }

        final a = File('${tree.root.path}/Documents/a.txt')
          ..writeAsStringSync('first');
        await settle();
        expect(String.fromCharCodes(cloud.files['Documents/a.txt']!), 'first');
        final linked = await Process.run('/bin/ln', [
          a.path,
          '${tree.root.path}/Documents/b.txt',
        ]);
        expect(linked.exitCode, 0, reason: '${linked.stderr}');
        await settle();
        File('${tree.root.path}/Documents/b.txt')
            .writeAsStringSync(', edited through b', mode: FileMode.append);
        await settle();
        await settle();
        final evidence = {
          'deletes': cloud.deletes,
          'cloud': {
            for (final name in ['Documents/a.txt', 'Documents/b.txt'])
              name: cloud.files[name] == null
                  ? null
                  : String.fromCharCodes(cloud.files[name]!),
          },
          'status': {
            for (final name in ['Documents/a.txt', 'Documents/b.txt'])
              name: store.entries[name]?.status,
          },
          'local': a.readAsStringSync(),
        };
        // ignore: avoid_print
        print('hardlink evidence: ${jsonEncode(evidence)}');
        expect(cloud.deletes, 0);
        expect(cloud.files.containsKey('Documents/a.txt'), isTrue);
        expect(a.existsSync(), isTrue);
        expect(a.readAsStringSync(), 'first, edited through b');
      } finally {
        engine.close();
      }
    },
  );
}
