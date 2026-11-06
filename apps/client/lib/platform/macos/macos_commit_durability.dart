import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/ports/commit_durability.dart';

/// macOS [CommitDurability] (flag SC-051): F_BARRIERFSYNC orders a manifest
/// commit, F_FULLFSYNC flushes the drive at a commit point (decision #129).
/// Through libc directly, on a descriptor of the manifest's own file: the
/// fcntls act on the file and the device, not on the descriptor SQLite
/// wrote through. Loads no Flutter library.
class MacosCommitDurability implements CommitDurability {
  const MacosCommitDurability();

  static const _fullFsync = 51; // F_FULLFSYNC
  static const _barrierFsync = 85; // F_BARRIERFSYNC
  static const _readOnly = 0x0000; // O_RDONLY
  static const _closeOnExec = 0x01000000; // O_CLOEXEC

  static final _libc = DynamicLibrary.process();
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  static final _fcntl = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'fcntl',
      );
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  @override
  void barrier(String path) => _sync(path, _barrierFsync);

  @override
  void flush(String path) => _sync(path, _fullFsync);

  void _sync(String path, int command) {
    final name = path.toNativeUtf8();
    try {
      final fd = _open(name, _readOnly | _closeOnExec);
      if (fd < 0) {
        throw FileSystemException('Cannot open for a durability sync', path);
      }
      try {
        if (_fcntl(fd, command) == -1) {
          throw FileSystemException('Durability sync refused', path);
        }
      } finally {
        _close(fd);
      }
    } finally {
      malloc.free(name);
    }
  }
}
