// The native portability seam (spec #31 S2) on the platform running the
// tests, against the real libanj_rootfs (ANJ_ROOTFS_LIBRARY): symbolic
// errors, the staging path, the guard kind and the SQLite durability mode.
// Runs on Linux (tool/check.sh), on mac-test (tool/macos/check_macos.sh) and
// on W10C-Testing (tool/windows/native_test.ps1 -Dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/release_guard.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

void main() {
  late Directory fixture;
  setUp(() {
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-s2-').resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('errors are named symbolically, whatever the platform number', () {
    final native = NativeRootFs();
    // EWOULDBLOCK is 11 on Linux and 35 on Darwin; EEXIST and ENOENT agree.
    expect(native.errorName(Platform.isMacOS ? 35 : 11), 'wouldBlock');
    expect(native.errorName(17), 'exists');
    expect(native.errorName(2), 'notFound');
    expect(native.errorName(16), 'busy');
    expect(native.errorName(Platform.isMacOS ? 62 : 40), 'loop');
    expect(native.errorName(Platform.isMacOS ? 66 : 39), 'notEmpty');
    if (Platform.isMacOS) expect(native.errorName(107), 'escape');
    expect(native.errorName(0), 'none');
    expect(native.errorName(100000), 'other');
  });

  test('staged files are reached through the boundary, not a Dart path rule', () {
    final native = NativeRootFs();
    final tree = RootTree.setup(fixture.path, 's2', native);
    try {
      final through = native.stagePath(tree.stageFd);
      if (Platform.isLinux) {
        expect(through, '/proc/self/fd/${tree.stageFd}');
      } else {
        // The directory's current path, proven to open the same directory.
        expect(through, tree.staging.path);
      }
      final staged = tree.stagedFile('${tree.staging.path}/probe');
      staged.writeAsStringSync('bytes');
      expect(File('${tree.staging.path}/probe').readAsStringSync(), 'bytes');
      expect(tree.stagedFile('$through/probe').path, staged.path);
      expect(
        () => tree.stagedFile('${fixture.path}/elsewhere'),
        throwsA(isA<FileSystemException>()),
      );
      if (Platform.isWindows) {
        // The held staging handle does not share delete: the directory
        // cannot be moved away while the client runs (spec #32 W2).
        expect(
          () => tree.staging.renameSync('${fixture.path}/moved'),
          throwsA(isA<FileSystemException>()),
        );
        return;
      }
      // Moving the staging directory away: Linux still reaches it through
      // the descriptor; Darwin follows its new name. Neither resolves to a
      // directory that took the old name.
      final moved = tree.staging.renameSync('${fixture.path}/moved');
      final imposter = Directory(tree.staging.path)..createSync();
      expect(
        File('${native.stagePath(tree.stageFd)}/probe').readAsStringSync(),
        'bytes',
      );
      imposter.deleteSync();
      moved.renameSync(tree.staging.path);
    } finally {
      tree.close();
    }
  });

  test('the guard reports its strength', () {
    final native = NativeRootFs();
    final tree = RootTree.setup(fixture.path, 'guard', native);
    try {
      expect(
        native.releaseGuard().strength,
        Platform.isMacOS
            ? ReleaseGuardStrength.busyAndUnchanged
            : Platform.isWindows
            ? ReleaseGuardStrength.exclusiveOpen
            : ReleaseGuardStrength.lease,
      );
    } finally {
      tree.close();
    }
  });

  test('the manifest syncs SQLite with F_FULLFSYNC where it exists', () {
    // Per commit, SQLite uses F_FULLFSYNC unless the platform groups commits
    // (macOS, flag SC-051, decision #135): then each commit is a plain fsync
    // ordered by a barrier and every group ends in a full flush. WAL
    // checkpoints stay F_FULLFSYNC either way.
    for (final grouped in [true, false]) {
      final manifest = Manifest(
        Directory('${fixture.path}/profile-$grouped'),
        groupCommits: grouped,
      );
      try {
        int pragma(String name) =>
            manifest.db.select('PRAGMA $name').first.values.first as int;
        expect(manifest.groupsCommits, grouped && Platform.isMacOS);
        expect(
          pragma('fullfsync'),
          manifest.groupsCommits ? 0 : 1,
          reason: 'groupCommits: $grouped',
        );
        expect(pragma('checkpoint_fullfsync'), 1);
        expect(pragma('synchronous'), 2);
      } finally {
        manifest.close();
      }
    }
  });
}
