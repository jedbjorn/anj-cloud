@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/artifacts.dart';
import 'package:anj_cloud/core/ports/release_guard.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Spec #32 W2: the shared ports and RootTree against the real
/// anj_rootfs.dll on the Windows seat (ANJ_ROOTFS_LIBRARY, set by
/// tool/windows/native_test.ps1 -Dart). Run unelevated: ownership depends on
/// it. The native tests (native/windows/test) cover links, aliases and other
/// processes in depth; this proves the Dart binding, the errno contract and
/// RootTree's use of them.
void main() {
  late Directory temp;
  late RootFilesystem fs;
  late RootTree tree;

  Matcher errno(int code) => isA<FileSystemException>().having(
    (e) => e.osError?.errorCode,
    'errno',
    code,
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anj-w2-dart-');
    fs = platformAdapters().rootFilesystem();
    tree = RootTree.setup(temp.path, 'w2', fs);
  });
  tearDown(() {
    tree.close();
    temp.deleteSync(recursive: true);
  });

  File inRoot(String relative) => File(p.join(tree.root.path, relative));

  test('setup creates the root, private staging and default folders', () {
    final items = tree.scanItems();
    for (final name in ['Music', 'Videos', 'Documents']) {
      expect(items[name]?.kind, ItemKind.directory);
    }
    final info = fs.rootInfo(tree.fd);
    expect(info.stable, isTrue);
    expect(info.identity, fs.identity(tree.fd));
    expect(info.identity, matches(RegExp(r'^w[0-9a-f]{16}:-?\d+$')));
    expect(fs.fsMagic(tree.fd, ''), 0x5346544E);
    expect(tree.trustsStamps(info.identity.split(':').first, ''), isFalse);
    // Same volume as the root, so links and no-replace renames work.
    expect(
      fs.identity(tree.stageFd).split(':').first,
      info.identity.split(':').first,
    );
  });

  test('snapshot hashes through the boundary and scan stamps match', () async {
    inRoot('Documents/a.txt').writeAsStringSync('hello');
    final items = await tree.snapshot();
    final item = items['Documents/a.txt']!;
    expect(item.hash, sha256.convert(utf8.encode('hello')).toString());
    final single = tree.statItem('Documents/a.txt')!;
    expect(single.scanStamp, item.scanStamp);
    expect(single.identity, item.identity);
    final read = fs.copyAndHashStamped(tree.fd, 'Documents/a.txt', null);
    final parts = read.stamp.split(':');
    expect('${parts[0]}:${parts[1]}', item.identity);
  });

  test('staged files are reached through stagePath', () {
    final through = fs.stagePath(tree.stageFd);
    expect(through, tree.staging.path);
    final staged = tree.stagedFile(tree.newStagedFile().path)
      ..writeAsStringSync('staged', flush: true);
    tree.installAbsent('Documents/from-stage.txt', staged);
    expect(inRoot('Documents/from-stage.txt').readAsStringSync(), 'staged');
  });

  test('staged and artifact paths are fully qualified drive paths', () {
    // PR #55 review F2: never a POSIX-style /proc/self/fd path, which
    // Windows would resolve against the current drive.
    final drivePath = RegExp(r'^[A-Za-z]:\\');
    final staged = tree.stagedFile(tree.newStagedFile().path);
    expect(staged.path, matches(drivePath));
    expect(staged.path.contains('/proc'), isFalse);
    final manifest = Manifest(Directory(p.join(temp.path, 'profile')));
    try {
      final artifacts = Artifacts(manifest, tree);
      final created = artifacts.reserve('Documents/a.txt', 'working');
      expect(created.path, matches(drivePath));
      created.writeAsStringSync('working copy');
      expect(
        artifacts.resolve(created.path).readAsStringSync(),
        'working copy',
      );
    } finally {
      manifest.close();
    }
  });

  test('refusals carry Linux errno numbers', () {
    inRoot('Case.txt').writeAsStringSync('c');
    expect(() => fs.copyAndHash(tree.fd, 'case.txt', null), throwsA(errno(2)));
    expect(() => fs.copyAndHash(tree.fd, 'nul.txt', null), throwsA(errno(22)));
    expect(() => fs.copyAndHash(tree.fd, 'a:b', null), throwsA(errno(22)));
    expect(() => fs.copyAndHash(tree.fd, 'x.', null), throwsA(errno(22)));
    expect(tree.statItem('case.txt'), isNull);
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    File(p.join(outside.path, 'secret.txt')).writeAsStringSync('secret');
    final made = Process.runSync('cmd', [
      '/c',
      'mklink',
      '/J',
      p.join(tree.root.path, 'jdir'),
      outside.path,
    ]);
    expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
    expect(
      () => fs.copyAndHash(tree.fd, 'jdir/secret.txt', null),
      throwsA(errno(40)),
    );
    expect(tree.scanItems()['jdir']?.kind, ItemKind.unsupported);
    expect(tree.scanItems().keys.any((k) => k.contains('secret')), isFalse);
    expect(tree.statItem('jdir/secret.txt'), isNull);
    expect(() => tree.directoryLocation('jdir'), throwsA(errno(40)));
    Directory(p.join(tree.root.path, 'jdir')).deleteSync();
  });

  test('install and preserve never replace', () {
    inRoot('Documents/taken.txt').writeAsStringSync('old');
    final staged = tree.newStagedFile()..writeAsStringSync('new', flush: true);
    expect(
      () => tree.installAbsent('Documents/taken.txt', staged),
      throwsA(errno(17)),
    );
    expect(
      () => tree.installAbsent('Documents/TAKEN.TXT', staged),
      throwsA(errno(17)),
    );
    expect(inRoot('Documents/taken.txt').readAsStringSync(), 'old');
    tree.installAbsent('Documents/deep/new.txt', staged);
    expect(inRoot('Documents/deep/new.txt').readAsStringSync(), 'new');
    final copy = tree.preserve('Documents/deep/new.txt');
    expect(inRoot('Documents/deep/new.txt').existsSync(), isFalse);
    expect(copy.readAsStringSync(), 'new');
    expect(p.dirname(copy.path), tree.staging.path);
  });

  test('empty directories are removed by identity only', () {
    tree.ensureDirectory('Music/Albums');
    final identity = fs.directoryIdentity(tree.fd, 'Music/Albums');
    inRoot('Music/Albums/x').writeAsStringSync('x');
    expect(
      () => tree.removeEmptyDirectory('Music/Albums', identity),
      throwsA(errno(39)),
    );
    inRoot('Music/Albums/x').deleteSync();
    expect(
      () => tree.removeEmptyDirectory('Music/Albums', 'w0:1'),
      throwsA(errno(116)),
    );
    tree.removeEmptyDirectory('Music/Albums', identity);
    expect(
      Directory(p.join(tree.root.path, 'Music/Albums')).existsSync(),
      isFalse,
    );
  });

  group('release guard', () {
    late ReleaseGuard guard;
    setUp(() => guard = fs.releaseGuard());

    test('reports the exclusive-open strength', () {
      expect(guard.strength, ReleaseGuardStrength.exclusiveOpen);
    });

    test('an exclusive open releases a file nobody holds', () {
      final bytes = List.filled(128 * 1024, 7);
      inRoot('Videos/clip.bin').writeAsBytesSync(bytes, flush: true);
      final info = guard.info(tree.fd, 'Videos/clip.bin');
      expect(info.owned, isTrue);
      expect(info.links, 1);
      final fd = guard.guard(tree.fd, 'Videos/clip.bin', info, links: 1);
      try {
        expect(guard.hash(fd), sha256.convert(bytes).toString());
        // Opens during the window fail with a sharing violation.
        expect(
          () => inRoot('Videos/clip.bin').readAsBytesSync(),
          throwsA(isA<FileSystemException>()),
        );
        guard.quarantine(fd, tree.fd, 'Videos/clip.bin', tree.stageFd, 'q');
        expect(inRoot('Videos/clip.bin').existsSync(), isFalse);
        expect(guard.hash(fd), sha256.convert(bytes).toString());
        guard.unlink(fd, tree.stageFd, 'q');
        expect(File(p.join(tree.staging.path, 'q')).existsSync(), isFalse);
      } finally {
        guard.close(fd);
      }
    });

    test('a file another handle holds is busy', () {
      inRoot('Videos/open.bin').writeAsStringSync('open', flush: true);
      final info = guard.info(tree.fd, 'Videos/open.bin');
      final held = inRoot('Videos/open.bin').openSync();
      try {
        expect(
          () => guard.guard(tree.fd, 'Videos/open.bin', info, links: 1),
          throwsA(errno(16)),
        );
      } finally {
        held.closeSync();
      }
      final fd = guard.guard(tree.fd, 'Videos/open.bin', info, links: 1);
      guard.close(fd);
    });

    test('owned staging files are created, installed and restored', () {
      final fd = guard.create(tree.stageFd, 'owned');
      final created = guard.infoFd(fd);
      tree.native.closeFd(fd);
      expect(created.owned, isTrue);
      File(p.join(tree.staging.path, 'owned')).writeAsStringSync('o');
      expect(guard.preview(tree.stageFd, 'owned').size, 1);
      inRoot('Documents/here.txt').writeAsStringSync('x');
      expect(
        () =>
            guard.restore(tree.fd, 'Documents/here.txt', tree.stageFd, 'owned'),
        throwsA(errno(17)),
      );
      guard.restore(tree.fd, 'Documents/back.txt', tree.stageFd, 'owned');
      expect(inRoot('Documents/back.txt').readAsStringSync(), 'o');
      guard.preserve(tree.fd, 'Documents/back.txt', tree.stageFd, 'again');
      guard.install(tree.fd, 'Documents/linked.txt', tree.stageFd, 'again');
      expect(guard.info(tree.stageFd, 'again').links, 2);
    });
  });
}
