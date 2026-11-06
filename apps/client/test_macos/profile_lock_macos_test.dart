// Mac-side tests (spec #31 M0, M1): the Darwin dylib's profile lifetime lock.
// Run on mac-test by tool/macos/check_macos.sh, which builds the dylib and
// sets ANJ_MACOS_ROOTFS_LIBRARY. Not part of the Linux suite.
@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/macos/macos_profile_lock.dart';

final _close = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;

  setUp(() {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    fixture = Directory.systemTemp.createTempSync('anj-m0-lock-');
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('platformAdapters() selects the macOS set', () {
    expect(platformAdapters(), isA<MacosPlatformAdapters>());
  });

  test('a new profile is created private and locked', () {
    final lock = MacosProfileLock.acquire(
      '${fixture.path}/profile',
      library: library,
    );
    try {
      // The lock is taken on the canonical path (the default temp directory
      // is under /var, a symlink to /private/var).
      expect(
        lock.profile.path,
        Directory('${fixture.path}/profile').resolveSymbolicLinksSync(),
      );
      expect(lock.profile.statSync().mode & 0x1ff, 0x1c0); // 0700
      final slot = File('${lock.profile.path}/.instance.lock');
      expect(slot.statSync().mode & 0x1ff, 0x180); // 0600
    } finally {
      _close(lock.descriptor);
    }
  });

  test('a held profile is refused as already running (EWOULDBLOCK 35)', () {
    final path = '${fixture.path}/profile';
    final lock = MacosProfileLock.acquire(path, library: library);
    try {
      expect(
        () => MacosProfileLock.acquire(path, library: library),
        throwsA(
          isA<ProfileInUseException>()
              .having((e) => e.osError?.errorCode, 'errno', 35)
              .having((e) => e.message, 'message', contains('already running')),
        ),
      );
    } finally {
      _close(lock.descriptor);
    }
    // Released with its descriptor: the next launch acquires it.
    final again = MacosProfileLock.acquire(path, library: library);
    _close(again.descriptor);
  });

  test('a profile other users can read is refused', () {
    final shared = Directory('${fixture.path}/shared')..createSync();
    Process.runSync('chmod', ['0755', shared.path]);
    expect(
      () => MacosProfileLock.acquire(shared.path, library: library),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('lock refused'),
        ),
      ),
    );
    expect(File('${shared.path}/.instance.lock').existsSync(), false);
  });

  test('a missing profile handed over by a launcher is not recreated', () {
    final path = '${fixture.path}/gone';
    expect(
      () => MacosProfileLock.acquire(path, inherited: 3, library: library),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(path).existsSync(), false);
  });
}
