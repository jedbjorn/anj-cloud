import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/ports/desktop_session.dart';
import '../native/native_root_fs.dart';

/// Held by the process for its entire life, independently of Manifest instances.
/// There is deliberately no finalizer: garbage collection cannot unlock sync.
class ProfileLifetime implements ProfileLock {
  ProfileLifetime._(this.profile, this.descriptor);
  @override
  final Directory profile;
  final int descriptor;

  static ProfileLifetime acquire(String path, {int inherited = -1}) {
    final requested = Directory(path).absolute;
    final native = NativeRootFs();
    if (!requested.existsSync()) {
      if (inherited >= 0) {
        throw FileSystemException(
          'Selected profile became unavailable during launch. It was not recreated.',
          requested.path,
        );
      }
      requested.createSync(recursive: true);
      native.privateDir(requested.path);
    }
    final profile = Directory(requested.resolveSymbolicLinksSync());
    final pointer = profile.path.toNativeUtf8();
    try {
      final lock = native.lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('anj_profile_lock');
      final descriptor = lock(pointer, inherited);
      if (descriptor < 0) {
        final error = native.lib
            .lookupFunction<Int32 Function(), int Function()>('anj_error')();
        if (native.errorName(error) == 'wouldBlock') {
          throw ProfileInUseException(
            'This profile is already running. Quit AnJ Cloud from its tray or app menu before launching or updating.',
            profile.path,
            OSError('Linux errno', error),
          );
        }
        throw FileSystemException(
          'Profile lifetime lock refused. Use a private directory owned by this user.',
          profile.path,
          OSError('Linux errno', error),
        );
      }
      return ProfileLifetime._(profile, descriptor);
    } finally {
      malloc.free(pointer);
    }
  }
}
