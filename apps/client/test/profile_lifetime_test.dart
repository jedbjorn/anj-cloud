import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/platform/linux/profile_lifetime.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  test(
    'missing inherited-handoff profile stays absent and retains original lock',
    () {
      final fixture = Directory.systemTemp.createTempSync(
        'anj-lifetime-handoff-',
      );
      final original = '${fixture.path}/profile';
      final lifetime = ProfileLifetime.acquire(original);
      final retained = lifetime.profile.renameSync(
        '${fixture.path}/unavailable-profile',
      );
      try {
        expect(
          () =>
              ProfileLifetime.acquire(original, inherited: lifetime.descriptor),
          throwsA(isA<FileSystemException>()),
        );
        expect(Directory(original).existsSync(), false);
        expect(
          () => ProfileLifetime.acquire(retained.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        NativeRootFs().closeFd(lifetime.descriptor);
        final again = ProfileLifetime.acquire(retained.path);
        NativeRootFs().closeFd(again.descriptor);
        fixture.deleteSync(recursive: true);
      }
    },
  );

  test('process guard survives repeated initialize and stopped controller disposal', () async {
    final fixture = Directory.systemTemp.createTempSync(
      'anj-lifetime-controller-',
    );
    final lifetime = ProfileLifetime.acquire('${fixture.path}/profile');
    final controller = ClientController(
      lifetime.profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    try {
      await controller.initialize();
      await controller.initialize();
      expect(
        () => ProfileLifetime.acquire(lifetime.profile.path),
        throwsA(
          isA<ProfileInUseException>().having(
            (e) => e.osError?.errorCode,
            'errno',
            // EWOULDBLOCK: 11 on Linux, 35 on macOS.
            Platform.isMacOS ? 35 : 11,
          ),
        ),
      );
      final parent = Directory('${fixture.path}/files')..createSync();
      await controller.configureRoot(parent.path);
      expect(
        () => ProfileLifetime.acquire(lifetime.profile.path),
        throwsA(isA<FileSystemException>()),
      );
      await controller.stop();
      controller.dispose();
      // The production owner is main/process lifetime, never controller.dispose.
      expect(
        () => ProfileLifetime.acquire(lifetime.profile.path),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await controller.stop();
      // Explicit release is only fixture cleanup after its worker has stopped.
      NativeRootFs().closeFd(lifetime.descriptor);
      fixture.deleteSync(recursive: true);
    }
  });

  test(
    'failed controller initialization cannot release the process guard',
    () async {
      final fixture = Directory.systemTemp.createTempSync(
        'anj-lifetime-failure-',
      );
      final lifetime = ProfileLifetime.acquire('${fixture.path}/profile');
      final controller = ClientController(
        lifetime.profile,
        nativeLibrary: '${fixture.path}/absent.so',
        secrets: MemorySecrets(),
      );
      try {
        await expectLater(controller.initialize(), throwsA(anything));
        await expectLater(controller.initialize(), throwsA(anything));
        await controller.stop();
        controller.dispose();
        expect(
          () => ProfileLifetime.acquire(lifetime.profile.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await controller.stop();
        NativeRootFs().closeFd(lifetime.descriptor);
        final again = ProfileLifetime.acquire(lifetime.profile.path);
        NativeRootFs().closeFd(again.descriptor);
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
