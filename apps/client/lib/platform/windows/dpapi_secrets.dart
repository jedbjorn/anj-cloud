import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/ports/secret_store.dart';

/// Windows [SecretStore] (spec #32 Device Identity and Secrets): DPAPI with
/// user scope (`CryptProtectData`), one blob file per key under
/// `%LOCALAPPDATA%\anj-cloud\secrets`, a private directory (user and SYSTEM
/// only). Like the Linux keyring it is user-only and encrypted at rest, and
/// not bound to the app: another process of the same user can decrypt it
/// (parity, not an improvement). A blob does not decrypt for another
/// Windows user or on another machine.
///
/// Not flutter_secure_storage's Windows backend: that keeps its file under
/// Roaming AppData (it roams with the user's DPAPI keys, which the spec
/// avoids where possible) and deletes a file it cannot decrypt, which would
/// lose the device key on a transient DPAPI failure. Here a blob that does
/// not decrypt is an error and is kept. Each blob's entropy names its key, so
/// a blob copied to another key's file does not decrypt. Writes replace the
/// file atomically; values never reach logs.
class DpapiSecrets implements SecretStore {
  DpapiSecrets({String? directory, this.makePrivate})
    : directory =
          directory ??
          p.join(
            Platform.environment['LOCALAPPDATA'] ??
                (throw StateError('LOCALAPPDATA is not set')),
            'anj-cloud',
            'secrets',
          );

  final String directory;

  /// Makes the directory private (anj_rootfs.dll's privateDir).
  final void Function(String path)? makePrivate;
  bool _ready = false;

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_Blob>,
          Pointer<Utf16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_Blob>,
        ),
        int Function(
          Pointer<_Blob>,
          Pointer<Utf16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_Blob>,
        )
      >('CryptProtectData');
  static final _unprotect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_Blob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_Blob>,
        ),
        int Function(
          Pointer<_Blob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_Blob>,
        )
      >('CryptUnprotectData');
  static final _localFree = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  static final _lastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  /// CRYPTPROTECT_UI_FORBIDDEN: never prompt (background sync).
  static const _uiForbidden = 0x1;

  /// The blob file of [key] (its name never reveals the key).
  File fileOf(String key) => File(
    p.join(directory, '${sha256.convert(utf8.encode(key)).toString()}.dpapi'),
  );

  static List<int> _entropy(String key) =>
      utf8.encode('anj-cloud secret store v1\u0000$key');

  void _prepare() {
    if (_ready) return;
    Directory(directory).createSync(recursive: true);
    makePrivate?.call(directory);
    _ready = true;
  }

  @override
  Future<String?> read(String key) async {
    final file = fileOf(key);
    if (!file.existsSync()) return null;
    return utf8.decode(_run(file.readAsBytesSync(), key, protect: false));
  }

  @override
  Future<void> write(String key, String value) async {
    _prepare();
    final blob = _run(utf8.encode(value), key, protect: true);
    final file = fileOf(key);
    final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
    final temporary = File('${file.path}.tmp-$suffix');
    try {
      temporary.writeAsBytesSync(blob, flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = fileOf(key);
    if (file.existsSync()) file.deleteSync();
  }

  List<int> _run(List<int> data, String key, {required bool protect}) {
    final entropy = _entropy(key);
    final input = calloc<_Blob>();
    final salt = calloc<_Blob>();
    final output = calloc<_Blob>();
    final inputBytes = calloc<Uint8>(max(1, data.length));
    final saltBytes = calloc<Uint8>(entropy.length);
    try {
      inputBytes.asTypedList(max(1, data.length)).setAll(0, data);
      saltBytes.asTypedList(entropy.length).setAll(0, entropy);
      input.ref
        ..size = data.length
        ..data = inputBytes;
      salt.ref
        ..size = entropy.length
        ..data = saltBytes;
      final ok = protect
          ? _protect(
              input,
              nullptr,
              salt,
              nullptr,
              nullptr,
              _uiForbidden,
              output,
            )
          : _unprotect(
              input,
              nullptr,
              salt,
              nullptr,
              nullptr,
              _uiForbidden,
              output,
            );
      if (ok == 0) {
        throw FileSystemException(
          protect ? 'The Windows secret store could not encrypt a secret.' : 'A stored secret could not be decrypted for this Windows user; it was kept.',
          fileOf(key).path,
          OSError('Windows error', _lastError()),
        );
      }
      try {
        return List<int>.of(output.ref.data.asTypedList(output.ref.size));
      } finally {
        if (!protect) {
          // Plaintext: cleared before it is returned to the system.
          output.ref.data
              .asTypedList(output.ref.size)
              .fillRange(0, output.ref.size, 0);
        }
        _localFree(output.ref.data.cast());
      }
    } finally {
      inputBytes
          .asTypedList(max(1, data.length))
          .fillRange(0, max(1, data.length), 0);
      calloc.free(inputBytes);
      calloc.free(saltBytes);
      calloc.free(input);
      calloc.free(salt);
      calloc.free(output);
    }
  }
}

/// DATA_BLOB.
final class _Blob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> data;
}
