// Spec #33 acceptance row 5 on macOS (I3): an unpaired removal resolved
// by the identity lookup on the FSEvents watcher's APFS root. The watcher's
// clock is frozen, so the events FSEvents reports stay queued and only the
// old side of each change is rescanned (a rename seen from one side only);
// the engine's removal clock never moves, so nothing can be decided by a
// hold. Run on macOS by check_macos.sh.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/fakes.dart';

class _Cloud extends FakeCloud {
  final calls = <String>[];

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    calls.add('PUT $path');
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    calls.add('DELETE $path');
    return super.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) {
    calls.add('MOVE $from -> $to');
    return super.move(from, to, etag: etag);
  }
}

/// The macOS binding, recording every lookup and its answer.
class _Fs extends NativeRootFs {
  _Fs(String library)
    : super(library, 'macOS errno', macosFullVerificationInterval);

  final answers = <IdentityLocation>[];

  @override
  IdentityLocation locateIdentity(int fd, int stageFd, String identity) {
    final found = super.locateIdentity(fd, stageFd, identity);
    answers.add(found);
    return found;
  }
}

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;
  late _Fs fs;
  late _Cloud cloud;
  late SyncEngine engine;
  final trashed = <File>[];

  setUp(() async {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-i3-').resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    fs = _Fs(library);
    final tree = RootTree.setup(parent.path, 'root', fs);
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _Cloud()..foldersQualified = true;
    engine = SyncEngine(store, tree, cloud)
      // Ships disabled (SyncEngine.identityLookupByDefault); switched on here
      // to verify it.
      ..identityLookup = true;
    engine.debugElapsed = () => Duration.zero;
    await engine.startWatching();
    expect(engine.watcher, isNotNull, reason: 'APFS root: FSEvents');
    expect(fs.locatesIdentity, isTrue);
    (engine.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
  });
  tearDown(() {
    engine.close();
    for (final file in trashed) {
      if (file.existsSync()) file.deleteSync();
    }
    trashed.clear();
    fixture.deleteSync(recursive: true);
  });

  String root(String path) => '${engine.tree.root.path}/$path';

  /// Writes [paths] and waits until each is uploaded and the watcher is
  /// quiet, then freezes the watcher.
  Future<LocalWatcher> settled(List<String> paths) async {
    for (final path in paths) {
      File(root(path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(path, flush: true);
    }
    for (var i = 0; i < 60 && !paths.every(cloud.files.containsKey); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
    }
    expect(paths.where((p) => !cloud.files.containsKey(p)), isEmpty);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await engine.tick();
    }
    final w = engine.watcher! as LocalWatcher;
    w.debugNow = () => 0; // Every later event stays queued.
    cloud.calls.clear();
    fs.answers.clear();
    return w;
  }

  Future<void> oldSideOnly(String path) async {
    engine.markDirty(path);
    await engine.tick();
    expect(engine.lastPass!.localScan, 'partial');
  }

  test('a rename seen from one side only is a MOVE, in one pass', () async {
    final ids = <String, int>{};
    await settled(['Docs/a.txt', 'Other/keep.txt']);
    ids.addAll(cloud.fileIds);
    File(root('Docs/a.txt')).renameSync(root('Other/b 2026.txt'));
    await oldSideOnly('Docs/a.txt');
    stdout.writeln('I3 evidence: file rename lookups ${fs.answers}');
    expect(fs.answers.single.place, IdentityPlace.inside);
    expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b 2026.txt']);
    expect(cloud.fileIds['Other/b 2026.txt'], ids['Docs/a.txt']);
  });

  test('a folder moved, seen from one side only, is one MOVE', () async {
    await settled(['Photos/Trip/deep/c.jpg', 'Archive/keep.txt']);
    Directory(root('Photos/Trip')).renameSync(root('Archive/Trip 2026'));
    await oldSideOnly('Photos/Trip');
    stdout.writeln('I3 evidence: folder move lookups ${fs.answers}');
    expect(cloud.calls, ['MOVE Photos/Trip -> Archive/Trip 2026']);
  });

  test('a move to ~/.Trash is a delete within one pass', () async {
    await settled(['Docs/c.txt']);
    final trash = Directory('${Platform.environment['HOME']}/.Trash');
    final target = File('${trash.path}/anj-i3-$pid-c.txt');
    trashed.add(target);
    File(root('Docs/c.txt')).renameSync(target.path);
    await oldSideOnly('Docs/c.txt');
    stdout.writeln('I3 evidence: trash lookups ${fs.answers}');
    expect(fs.answers.single.place, IdentityPlace.outside);
    final entry = engine.manifest.entries['Docs/c.txt'];
    expect(
      entry?.expectedPresent ?? false,
      isFalse,
      reason: 'decided in the first pass, with no hold',
    );
    await engine.tick();
    expect(cloud.calls, ['DELETE Docs/c.txt']);
  });

  test('a downloaded file renamed, seen from one side only, is a MOVE '
      '(at once, or after the bounded hold when fsgetpath names its staging '
      'copy)', () async {
    cloud.put('Docs/down.txt', 'from the cloud');
    for (var i = 0; i < 60 && !File(root('Docs/down.txt')).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
    }
    final w = await settled(['Other/keep.txt']);
    File(root('Docs/down.txt')).renameSync(root('Other/down.txt'));
    await oldSideOnly('Docs/down.txt');
    stdout.writeln('I3 evidence: downloaded rename lookups ${fs.answers}');
    if (fs.answers.single.place == IdentityPlace.staging) {
      expect(cloud.calls, isEmpty, reason: 'held: the other link is unknown');
      w.debugNow = null; // The new side reaches the view.
      for (var i = 0; i < 30 && cloud.calls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
    }
    expect(cloud.calls, ['MOVE Docs/down.txt -> Other/down.txt']);
  });
}
