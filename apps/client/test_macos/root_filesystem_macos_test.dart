// Mac-side M1 tests (spec #31): the macOS adapter's root filesystem over the
// Darwin dylib, through the shared ports. Run on mac-test by
// tool/macos/check_macos.sh (ANJ_MACOS_ROOTFS_LIBRARY). The full native
// mapping is tool/native_test.sh; the shared suites run with the same dylib.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/release_guard.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;

  setUp(() {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    // Canonical: the root may not sit under a symlink (/var -> /private/var).
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-m1-').resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('the adapter opens a root on APFS with a stable volume key', () {
    final fs = const MacosPlatformAdapters().rootFilesystem(library);
    final tree = RootTree.setup(fixture.path, 'root', fs);
    try {
      final info = fs.rootInfo(tree.fd);
      expect(info.stable, isTrue);
      expect(info.identity, matches(RegExp(r'^u[0-9a-f]{32}:\d+:b\d+\.\d+$')));
      expect(fs.stagePath(tree.stageFd), tree.staging.path);
      expect(fs.releaseGuard().strength, ReleaseGuardStrength.busyAndUnchanged);
    } finally {
      tree.close();
    }
  });

  test('refusals carry the macOS errno space', () {
    final fs = const MacosPlatformAdapters().rootFilesystem(library);
    final tree = RootTree.setup(fixture.path, 'root', fs);
    try {
      Link('${tree.root.path}/link').createSync('/etc');
      expect(
        () => fs.fileIdentity(tree.fd, 'link/hosts'),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e.osError?.message, 'label', 'macOS errno')
              .having((e) => e.osError?.errorCode, 'ELOOP', 62),
        ),
      );
    } finally {
      tree.close();
    }
  });

  test('a release is refused while any other descriptor holds the file', () {
    final fs = const MacosPlatformAdapters().rootFilesystem(library);
    final tree = RootTree.setup(fixture.path, 'root', fs);
    final guard = fs.releaseGuard();
    try {
      final fd = guard.create(tree.stageFd, 'held');
      fs.closeFd(fd);
      File('${tree.staging.path}/held').writeAsStringSync('bytes');
      final reader = File('${tree.staging.path}/held').openSync();
      try {
        // Refused at the guard, before anything moves (as the Linux lease).
        expect(
          () => guard.guard(
            tree.stageFd,
            'held',
            guard.info(tree.stageFd, 'held'),
            links: 1,
          ),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'EBUSY',
              16,
            ),
          ),
        );
      } finally {
        reader.closeSync();
      }
      // A descriptor opened after the guard fails the final unlink instead.
      final late = guard.guard(
        tree.stageFd,
        'held',
        guard.info(tree.stageFd, 'held'),
        links: 1,
      );
      final opened = File('${tree.staging.path}/held').openSync();
      try {
        expect(guard.hash(late), isNotEmpty);
        expect(
          () => guard.unlink(late, tree.stageFd, 'held'),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        guard.close(late);
        opened.closeSync();
      }
      expect(File('${tree.staging.path}/held').readAsStringSync(), 'bytes');
      // Nothing holds it now: the release goes through.
      final again = guard.guard(
        tree.stageFd,
        'held',
        guard.info(tree.stageFd, 'held'),
        links: 1,
      );
      try {
        guard.unlink(again, tree.stageFd, 'held');
      } finally {
        guard.close(again);
      }
      expect(File('${tree.staging.path}/held').existsSync(), isFalse);
    } finally {
      tree.close();
    }
  });
}
