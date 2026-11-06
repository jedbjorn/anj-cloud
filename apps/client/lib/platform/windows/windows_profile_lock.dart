import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../core/ports/desktop_session.dart';
import '../native/native_root_fs.dart';
import 'windows_root_fs.dart';

/// Windows [ProfileLock]: `<profile>\.instance.lock` opened with no sharing
/// by `anj_profile_lock` in anj_rootfs.dll (native/windows/rootfs_win.cc)
/// and held for the whole process; there is deliberately no finalizer. The
/// kernel closes it when the process ends, so tray Quit, logoff, shutdown
/// and a crash all release it.
class WindowsProfileLock implements ProfileLock {
  WindowsProfileLock._(this.profile, this.descriptor, this._native);
  @override
  final Directory profile;
  final int descriptor;
  final NativeRootFs _native;

  /// Tests only: the app holds the lock until the process exits.
  @visibleForTesting
  void release() => _native.closeFd(descriptor);

  /// A held lock refuses with a sharing violation. A virus scanner opening
  /// the lock file for a moment looks the same, so a refusal is retried
  /// briefly before it means "already running".
  static WindowsProfileLock acquire(
    String path, {
    int inherited = -1,
    String? library,
    int attempts = 4,
    Duration pause = const Duration(milliseconds: 150),
  }) {
    if (inherited != -1) {
      throw UnsupportedError(
        'An inherited profile lock is a Linux manager feature; the Windows '
        'manager arrives in spec #32 W5.',
      );
    }
    final native = NativeRootFs(
      library ?? windowsRootfsLibrary(),
      'Linux errno (anj_rootfs.dll)',
    );
    final requested = Directory(path).absolute;
    if (!requested.existsSync()) requested.createSync(recursive: true);
    // Idempotent: an already private directory is left untouched.
    native.privateDir(requested.path);
    final profile = Directory(requested.resolveSymbolicLinksSync());
    final lock = native.lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('anj_profile_lock');
    final error = native.lib.lookupFunction<Int32 Function(), int Function()>(
      'anj_error',
    );
    final pointer = profile.path.toNativeUtf8();
    try {
      for (var attempt = 1; ; attempt++) {
        final descriptor = lock(pointer, -1);
        if (descriptor >= 0) {
          return WindowsProfileLock._(profile, descriptor, native);
        }
        final code = error();
        if (native.errorName(code) == 'wouldBlock') {
          if (attempt < attempts) {
            sleep(pause);
            continue;
          }
          throw ProfileInUseException(
            'This profile is already running. Quit AnJ Cloud from its '
            'notification-area icon before launching or updating.',
            profile.path,
            OSError('Linux errno (anj_rootfs.dll)', code),
          );
        }
        throw FileSystemException(
          'Profile lifetime lock refused. Use a private directory owned by this user.',
          profile.path,
          OSError('Linux errno (anj_rootfs.dll)', code),
        );
      }
    } finally {
      malloc.free(pointer);
    }
  }
}
