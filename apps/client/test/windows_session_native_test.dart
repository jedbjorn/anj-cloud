@TestOn('windows')
library;

import 'dart:io';

import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/platform/windows/dpapi_secrets.dart';
import 'package:anj_cloud/platform/windows/windows_profile_lock.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Spec #32 W3 on W10C-Testing, unelevated, against the real anj_rootfs.dll
/// (ANJ_ROOTFS_LIBRARY) and DPAPI: the profile lifetime lock and the secret
/// store. Run by tool/windows/native_test.ps1 -Dart.
void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('anj-w3-'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('profile lifetime lock', () {
    test('creates a private profile and holds a no-sharing lock file', () {
      final path = p.join(temp.path, 'profile');
      final lock = WindowsProfileLock.acquire(path);
      addTearDown(lock.release);
      expect(lock.profile.path, Directory(path).resolveSymbolicLinksSync());
      final file = File(p.join(path, '.instance.lock'));
      expect(file.existsSync(), isTrue);
      // No sharing: even reading the lock file is refused while held.
      expect(file.readAsBytesSync, throwsA(isA<FileSystemException>()));
    });

    test('a second holder is refused as already running, then allowed', () {
      final first = WindowsProfileLock.acquire(temp.path);
      try {
        expect(
          () => WindowsProfileLock.acquire(temp.path, pause: Duration.zero),
          throwsA(isA<ProfileInUseException>()),
        );
      } finally {
        first.release();
      }
      WindowsProfileLock.acquire(temp.path).release();
    });

    test('a second process is refused while the first runs', () async {
      final lock = WindowsProfileLock.acquire(temp.path);
      try {
        // Another process opening the lock file meets the sharing violation.
        final probe = await Process.run('cmd', [
          '/c',
          'type',
          p.join(lock.profile.path, '.instance.lock'),
        ]);
        expect(probe.exitCode, isNot(0));
      } finally {
        lock.release();
      }
    });

    test('an inherited lock (the Linux manager) is refused', () {
      expect(
        () => WindowsProfileLock.acquire(temp.path, inherited: 5),
        throwsUnsupportedError,
      );
    });
  });

  group('DPAPI secret store', () {
    late DpapiSecrets secrets;
    setUp(
      () => secrets = DpapiSecrets(
        directory: p.join(temp.path, 'secrets'),
        makePrivate: (path) => windowsRootFilesystem().privateDir(path),
      ),
    );

    test('round trip, encrypted at rest, delete', () async {
      const key = 'anj-cloud:w3:device-key';
      const value = '-----BEGIN PRIVATE KEY-----\nw3-secret-material\n';
      expect(await secrets.read(key), isNull);
      await secrets.write(key, value);
      expect(await secrets.read(key), value);
      final bytes = secrets.fileOf(key).readAsBytesSync();
      expect(
        String.fromCharCodes(bytes),
        isNot(contains('w3-secret-material')),
      );
      expect(String.fromCharCodes(bytes), isNot(contains('PRIVATE KEY')));
      await secrets.write(key, 'replaced');
      expect(await secrets.read(key), 'replaced');
      await secrets.delete(key);
      expect(await secrets.read(key), isNull);
      await secrets.delete(key);
    });

    test('a blob moved to another key does not decrypt and is kept', () async {
      await secrets.write('a', 'secret-a');
      secrets.fileOf('a').copySync(secrets.fileOf('b').path);
      await expectLater(secrets.read('b'), throwsA(isA<FileSystemException>()));
      expect(secrets.fileOf('b').existsSync(), isTrue);
      expect(await secrets.read('a'), 'secret-a');
    });

    test('the directory is private: user and SYSTEM only', () async {
      await secrets.write('k', 'v');
      final acl =
          Process.runSync('icacls', [secrets.directory]).stdout as String;
      final grants = acl
          .split('\n')
          .map((line) => line.replaceFirst(secrets.directory, '').trim())
          .where((line) => line.contains(':('))
          .toList();
      expect(grants, hasLength(2), reason: acl);
      expect(
        grants.any((g) => g.startsWith('NT AUTHORITY\\SYSTEM:')),
        isTrue,
        reason: acl,
      );
      expect(grants.any((g) => g.contains('BUILTIN\\')), isFalse, reason: acl);
    });
  });
}
