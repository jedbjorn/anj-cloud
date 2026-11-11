// Spec #33 I3: anj_locate_identity against the real native library on the
// platform running the tests (ANJ_ROOTFS_LIBRARY). Linux and Android report
// it unsupported, so the engine holds an unpaired removal instead (decision
// #140). macOS (fsgetpath) and Windows (OpenFileById): acceptance row 5's
// native evidence, run by tool/macos/check_macos.sh on macOS and by
// tool/windows/native_test.ps1 -Dart on Windows. Decision #143: every
// error is IdentityPlace.uncertain, never folded into notFound or outside.
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final looksUp = Platform.isMacOS || Platform.isWindows;
  late Directory fixture;
  late NativeRootFs native;
  late RootTree tree;

  setUp(() {
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-i3-').resolveSymbolicLinksSync(),
    );
    native = NativeRootFs();
    tree = RootTree.setup(
      (Directory('${fixture.path}/files')..createSync()).path,
      'root',
      native,
    );
  });
  tearDown(() {
    tree.close();
    fixture.deleteSync(recursive: true);
  });

  String at(String relative) =>
      '${tree.root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';
  void write(String relative, String text) => File(at(relative))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text, flush: true);
  IdentityLocation locate(String identity) =>
      native.locateIdentity(tree.fd, tree.stageFd, identity);
  void hardLink(String existing, String link) {
    final result = Platform.isWindows
        ? Process.runSync('cmd', ['/d', '/c', 'mklink', '/H', link, existing])
        : Process.runSync('ln', [existing, link]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  if (!looksUp) {
    test('Linux and Android: no lookup; the export says unsupported', () {
      write('a.txt', 'a');
      expect(native.locatesIdentity, isFalse);
      expect(
        locate(native.fileIdentity(tree.fd, 'a.txt')),
        identityUncertain,
        reason: 'no answer is not proof of anything',
      );
    });
    return;
  }

  test('the platform answers', () {
    expect(native.locatesIdentity, isTrue);
  });

  test('a file renamed into another folder is found at its new path', () {
    write('Docs/a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'Docs/a.txt');
    Directory(at('Other')).createSync();
    File(at('Docs/a.txt')).renameSync(at('Other/b 2026.txt'));
    expect(locate(id), (
      place: IdentityPlace.inside,
      path: 'Other/b 2026.txt',
      links: 1,
    ));
  });

  test('a folder moved, and a file beneath it, are found at their new '
      'paths', () {
    write('Photos/Trip/deep/c.jpg', 'c');
    final folder = native.directoryIdentity(tree.fd, 'Photos/Trip');
    final file = native.fileIdentity(tree.fd, 'Photos/Trip/deep/c.jpg');
    Directory(at('Archive')).createSync();
    Directory(at('Photos/Trip')).renameSync(at('Archive/Trip 2026'));
    expect(locate(folder), (
      place: IdentityPlace.inside,
      path: 'Archive/Trip 2026',
      links: 1,
    ));
    expect(locate(file).path, 'Archive/Trip 2026/deep/c.jpg');
  });

  test('a non-ASCII name comes back as the scan spells it', () {
    write('Café/Ünïcode ñ.txt', 'u');
    final id = native.fileIdentity(tree.fd, 'Café/Ünïcode ñ.txt');
    File(at('Café/Ünïcode ñ.txt')).renameSync(at('Café/Résumé ✓.txt'));
    final scanned = native
        .scan(tree.fd)
        .map((item) => item['path'] as String)
        .where((path) => path.startsWith('Caf') && path.contains('/'))
        .single;
    expect(locate(id).path, scanned);
  });

  test('moved out of the root (elsewhere on its volume): outside', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    final elsewhere = Directory('${fixture.path}/elsewhere')..createSync();
    File(at('a.txt')).renameSync('${elsewhere.path}/a.txt');
    expect(locate(id), (place: IdentityPlace.outside, path: null, links: 0));
  });

  test('deleted: not found', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    File(at('a.txt')).deleteSync();
    expect(locate(id), identityNotFound);
  });

  test('a malformed identity, another volume, an unknown inode: not found, '
      'never a crash', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    final volume = id.split(':').first;
    for (final bad in [
      '',
      'nonsense',
      '$volume:',
      ':12',
      '$volume:abc',
      '$volume:12:34',
      '${volume}x:${id.split(':').last}',
      '$volume:9223372036854775',
    ]) {
      expect(locate(bad), identityNotFound, reason: bad);
    }
  });

  test('a closed root: uncertain, never a crash', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    expect(native.locateIdentity(-1, -1, id), identityUncertain);
    expect(native.locateIdentity(999999, tree.stageFd, id), identityUncertain);
  });

  test('moved to a sibling whose name extends the root\'s (root2): '
      'outside', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    final sibling = Directory('${tree.root.path}2')..createSync();
    File(at('a.txt'))
        .renameSync('${sibling.path}${Platform.pathSeparator}a.txt');
    expect(locate(id), (place: IdentityPlace.outside, path: null, links: 0));
  });

  test('moved out of the root, with a link inside the root to where it '
      'went: outside', () {
    write('Trip/a.jpg', 'a');
    final folder = native.directoryIdentity(tree.fd, 'Trip');
    final file = native.fileIdentity(tree.fd, 'Trip/a.jpg');
    final away = '${fixture.path}${Platform.pathSeparator}Trip';
    Directory(at('Trip')).renameSync(away);
    if (Platform.isWindows) {
      // A junction: an unelevated user may make one, not a symlink.
      final made = Process.runSync('cmd', [
        '/d',
        '/c',
        'mklink',
        '/J',
        at('Trip link'),
        away,
      ]);
      expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
    } else {
      Link(at('Trip link')).createSync(away);
    }
    const outside = (place: IdentityPlace.outside, path: null, links: 0);
    expect(locate(folder), outside);
    expect(locate(file), outside);
  });

  test('case-only and normalization-only renames come back spelled as the '
      'scan lists them now', () {
    write('Docs/case.txt', 'c');
    final cased = native.fileIdentity(tree.fd, 'Docs/case.txt');
    File(at('Docs/case.txt')).renameSync(at('Docs/CASE.TXT'));
    String listed(String prefix) => native
        .scan(tree.fd)
        .map((item) => item['path'] as String)
        .singleWhere((path) => path.startsWith('Docs/$prefix'));
    expect(listed('CASE'), 'Docs/CASE.TXT');
    expect(locate(cased), (
      place: IdentityPlace.inside,
      path: 'Docs/CASE.TXT',
      links: 1,
    ));
    const nfc = 'Caf\u00e9.txt', nfd = 'Cafe\u0301.txt';
    write('Docs/$nfc', 'n');
    final normal = native.fileIdentity(tree.fd, 'Docs/$nfc');
    File(at('Docs/$nfc')).renameSync(at('Docs/$nfd'));
    final found = locate(normal);
    stdout.writeln('I3 evidence: NFC renamed to NFD -> $found');
    expect(found.place, IdentityPlace.inside);
    expect(found.path, listed('Caf'));
  });

  test('a file with a second link in the root reports both links', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    hardLink(at('a.txt'), at('a-link.txt'));
    File(at('a.txt')).renameSync(at('b.txt'));
    final found = locate(id);
    expect(found.place, IdentityPlace.inside);
    expect({'b.txt', 'a-link.txt'}, contains(found.path));
    expect(found.links, 2);
  });

  test('a download (installed by hard link from its staging copy) renamed, '
      'then deleted', () {
    final staged = '${tree.staging.path}${Platform.pathSeparator}down.part';
    File(staged).writeAsStringSync('from the cloud', flush: true);
    native.install(tree.fd, 'down.txt', staged);
    final id = native.fileIdentity(tree.fd, 'down.txt');
    Directory(at('Docs')).createSync();
    File(at('down.txt')).renameSync(at('Docs/down.txt'));
    final renamed = locate(id);
    // Windows enumerates every link; macOS names one, which may be the
    // staging copy (the engine then holds the removal).
    printOnFailure('renamed download: $renamed');
    stdout.writeln('I3 evidence: renamed download -> $renamed');
    if (Platform.isWindows) {
      expect(renamed, (
        place: IdentityPlace.inside,
        path: 'Docs/down.txt',
        links: 2,
      ));
    } else {
      expect(renamed.links, 2);
      expect(
        renamed ==
                (
                  place: IdentityPlace.inside,
                  path: 'Docs/down.txt',
                  links: 2,
                ) ||
            renamed == (place: IdentityPlace.staging, path: null, links: 2),
        isTrue,
      );
    }
    File(at('Docs/down.txt')).deleteSync();
    final gone = locate(id);
    stdout.writeln('I3 evidence: deleted download -> $gone');
    expect(
      gone,
      Platform.isWindows
          ? (place: IdentityPlace.outside, path: null, links: 0)
          : (place: IdentityPlace.staging, path: null, links: 1),
    );
  });

  test('bounded: 500 lookups well inside a pass', () {
    write('a.txt', 'a');
    final id = native.fileIdentity(tree.fd, 'a.txt');
    File(at('a.txt')).renameSync(at('b.txt'));
    final clock = Stopwatch()..start();
    for (var i = 0; i < 500; i++) {
      expect(locate(id).path, 'b.txt');
    }
    clock.stop();
    stdout.writeln(
      'I3 evidence: 500 lookups in ${clock.elapsedMilliseconds} ms',
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
