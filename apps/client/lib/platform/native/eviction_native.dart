import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../../core/local/root_tree.dart';
import '../../core/ports/release_guard.dart';
import '../../core/ports/root_filesystem.dart';
import 'native_root_fs.dart';

typedef _InfoC = Pointer<Utf8> Function(Int32, Pointer<Utf8>);
typedef _InfoD = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _GuardC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _GuardD = int Function(int, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _MoveC = Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef _MoveD = int Function(int, Pointer<Utf8>, int, Pointer<Utf8>);
typedef _QuarantineC = Int32 Function(
  Int32,
  Int32,
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
);
typedef _QuarantineD = int Function(
  int,
  int,
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
);

/// Platform-neutral [ReleaseGuard] binding: the guard compiled into the same
/// native library as [NativeRootFs] (Linux guard_lease.inc), so it binds
/// that library and reports which it is
/// ([strength], from `anj_guard_kind`).
class EvictionNative implements ReleaseGuard {
  EvictionNative(RootFilesystem fs) : fs = fs as NativeRootFs;
  final NativeRootFs fs;
  late final _info = fs.lib.lookupFunction<_InfoC, _InfoD>('anj_info_at');
  late final _kind = fs.lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'anj_guard_kind',
      );
  @override
  late final ReleaseGuardStrength strength = ReleaseGuardStrength.values.byName(
    _kind().toDartString(),
  );
  late final _preview = fs.lib.lookupFunction<_InfoC, _InfoD>(
    'anj_preview_editor',
  );
  @override
  NativeFileInfo preview(int directory, String name) =>
      arg(name, (v) => parse(_preview(directory, v)));
  late final _infoFd = fs.lib
      .lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('anj_info_fd');
  late final _free = fs.lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('anj_free');
  late final _error = fs.lib.lookupFunction<Int32 Function(), int Function()>(
    'anj_error',
  );
  late final _create = fs.lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('anj_create_owned');
  late final _guard = fs.lib.lookupFunction<_GuardC, _GuardD>('anj_guard_open');
  late final _valid = fs.lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'anj_guard_valid',
      );
  late final _close = fs.lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'anj_guard_close',
      );
  late final _rewind = fs.lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('anj_rewind');
  late final _read = fs.lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('anj_read');
  late final _move = fs.lib.lookupFunction<_MoveC, _MoveD>(
    'anj_preserve_owned',
  );
  late final _install = fs.lib.lookupFunction<_MoveC, _MoveD>(
    'anj_install_owned',
  );
  late final _restore = fs.lib.lookupFunction<_MoveC, _MoveD>(
    'anj_restore_owned',
  );
  late final _quarantine = fs.lib.lookupFunction<_QuarantineC, _QuarantineD>(
    'anj_guard_quarantine',
  );
  late final _unlink = fs.lib
      .lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Utf8>),
        int Function(int, int, Pointer<Utf8>)
      >('anj_guard_unlink');
  Never fail() => throw FileSystemException(
    'Cloud pending: filesystem guard refused; file is busy, changed, linked or unsupported.',
    '',
    OSError(fs.errnoLabel, _error()),
  );
  T arg<T>(String text, T Function(Pointer<Utf8>) action) {
    validateRelative(text);
    final value = text.toNativeUtf8();
    try {
      return action(value);
    } finally {
      malloc.free(value);
    }
  }

  NativeFileInfo parse(Pointer<Utf8> value) {
    if (value == nullptr) {
      fail();
    }
    try {
      return NativeFileInfo(
        jsonDecode(value.toDartString()) as Map<String, dynamic>,
      );
    } finally {
      _free(value.cast());
    }
  }

  @override
  NativeFileInfo info(int directory, String path) =>
      arg(path, (value) => parse(_info(directory, value)));
  @override
  NativeFileInfo infoFd(int fd) => parse(_infoFd(fd));
  @override
  int create(int directory, String name) => arg(name, (value) {
    final fd = _create(directory, value);
    if (fd < 0) {
      fail();
    }
    return fd;
  });
  @override
  int guard(
    int directory,
    String path,
    NativeFileInfo expected, {
    required int links,
  }) => arg(path, (value) {
    final stamp = expected.stamp.toNativeUtf8();
    try {
      final fd = _guard(directory, value, stamp, links);
      if (fd < 0) {
        fail();
      }
      return fd;
    } finally {
      malloc.free(stamp);
    }
  });
  @override
  void valid(int fd) {
    if (_valid(fd) < 0) {
      fail();
    }
  }

  @override
  void close(int fd) {
    if (_close(fd) < 0) {
      fail();
    }
  }

  @override
  String hash(int fd, {String purpose = 'eviction'}) {
    var total = 0;
    try {
      return _hash(fd, (n) => total += n);
    } finally {
      fs.meter.record(purpose, total);
    }
  }

  String _hash(int fd, void Function(int) counted) {
    valid(fd);
    if (_rewind(fd) < 0) {
      fail();
    }
    final before = infoFd(fd).stamp;
    final bytes = malloc<Uint8>(256 * 1024);
    final result = _Digest();
    final sink = sha256.startChunkedConversion(result);
    try {
      while (true) {
        valid(fd);
        final n = _read(fd, bytes, 256 * 1024);
        if (n < 0) {
          fail();
        }
        if (n == 0) {
          break;
        }
        counted(n);
        sink.add(bytes.asTypedList(n));
      }
      sink.close();
      valid(fd);
      if (infoFd(fd).stamp != before) {
        fail();
      }
      return result.value!;
    } finally {
      malloc.free(bytes);
    }
  }

  @override
  void preserve(int root, String path, int stage, String name) {
    fs.beforeDestructiveChange?.call(); // Decision #137 (1).
    arg(
      path,
      (value) => arg(name, (target) {
        if (_move(root, value, stage, target) < 0) {
          fail();
        }
      }),
    );
  }

  @override
  void install(int root, String path, int stage, String name) => arg(
    path,
    (value) => arg(name, (target) {
      if (_install(root, value, stage, target) < 0) {
        fail();
      }
    }),
  );

  /// Renames staging [name] to root [path]; never replaces an existing
  /// path (EEXIST). Both directories are fsynced before it returns.
  @override
  void restore(int root, String path, int stage, String name) => arg(
    path,
    (value) => arg(name, (target) {
      if (_restore(root, value, stage, target) < 0) {
        fail();
      }
    }),
  );
  @override
  void quarantine(int guardFd, int root, String path, int stage, String name) {
    fs.beforeDestructiveChange?.call(); // Decision #137 (1).
    arg(
      path,
      (value) => arg(name, (target) {
        if (_quarantine(guardFd, root, value, stage, target) < 0) {
          fail();
        }
      }),
    );
  }

  @override
  void unlink(int guardFd, int stage, String name) {
    fs.beforeDestructiveChange?.call(); // Decision #137 (1).
    arg(name, (target) {
      if (_unlink(guardFd, stage, target) < 0) {
        fail();
      }
    });
  }
}

class _Digest implements Sink<Digest> {
  String? value;
  @override
  void add(Digest digest) {
    value = digest.toString();
  }

  @override
  void close() {}
}
