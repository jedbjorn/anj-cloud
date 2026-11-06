import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/ports/desktop_session.dart';
import 'macos_native_library.dart';

/// macOS [ProfileLock]: the same flock as Linux (native/posix/lifecycle.inc,
/// in the Darwin build of native/posix/rootfs.cc). Held for the whole
/// process; there is deliberately no finalizer.
class MacosProfileLock implements ProfileLock {
  MacosProfileLock._(this.profile, this.descriptor);
  @override
  final Directory profile;
  final int descriptor;

  static MacosProfileLock acquire(
    String path, {
    int inherited = -1,
    String? library,
  }) {
    final requested = Directory(path).absolute;
    final native = openMacosNativeLibrary(library);
    final error = native.lookupFunction<Int32 Function(), int Function()>(
      'anj_error',
    );
    if (!requested.existsSync()) {
      if (inherited >= 0) {
        throw FileSystemException(
          'Selected profile became unavailable during launch. It was not recreated.',
          requested.path,
        );
      }
      requested.createSync(recursive: true);
      final chmod = native
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('anj_chmod_private');
      final pointer = requested.path.toNativeUtf8();
      try {
        if (chmod(pointer) < 0) {
          throw FileSystemException(
            'Profile directory permissions could not be made private.',
            requested.path,
            OSError('macOS errno', error()),
          );
        }
      } finally {
        malloc.free(pointer);
      }
    }
    final profile = Directory(requested.resolveSymbolicLinksSync());
    final pointer = profile.path.toNativeUtf8();
    try {
      final lock = native
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('anj_profile_lock');
      final descriptor = lock(pointer, inherited);
      if (descriptor < 0) {
        final code = error();
        final name = native
            .lookupFunction<
              Pointer<Utf8> Function(Int32),
              Pointer<Utf8> Function(int)
            >('anj_error_name');
        // EWOULDBLOCK (35 on Darwin) is named by the boundary, never
        // compared as a number here (spec #31 S2).
        if (name(code).toDartString() == 'wouldBlock') {
          throw ProfileInUseException(
            'This profile is already running. Quit AnJ Cloud before launching or updating.',
            profile.path,
            OSError('macOS errno', code),
          );
        }
        throw FileSystemException(
          'Profile lifetime lock refused. Use a private directory owned by this user.',
          profile.path,
          OSError('macOS errno', code),
        );
      }
      return MacosProfileLock._(profile, descriptor);
    } finally {
      malloc.free(pointer);
    }
  }
}
