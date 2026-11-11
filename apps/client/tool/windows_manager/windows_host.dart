/// The Windows [Host] of the manager: HKCU registry values and the Start
/// menu shortcut, the profile lifetime lock through a release's
/// anj_rootfs.dll, read-only release files and detached client starts.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'manager.dart';

const _run = r'Software\Microsoft\Windows\CurrentVersion\Run';
const _uninstall =
    r'Software\Microsoft\Windows\CurrentVersion\Uninstall\AnJ Cloud';
final _hkcu = Pointer<Void>.fromAddress(0x80000001);
const _keyRead = 0x20019, _keyWrite = 0x20006;
const _regSz = 1, _regDword = 4;
const _errorFileNotFound = 2;

final _advapi = DynamicLibrary.open('advapi32.dll');
final _kernel = DynamicLibrary.open('kernel32.dll');
final _regCreate = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Utf16>,
        int,
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint32>,
      )
    >('RegCreateKeyExW');
final _regOpen = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Pointer<Void>>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Utf16>,
        int,
        int,
        Pointer<Pointer<Void>>,
      )
    >('RegOpenKeyExW');
final _regSet = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Uint8>,
        Uint32,
      ),
      int Function(Pointer<Void>, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
    >('RegSetValueExW');
final _regQuery = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint8>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint8>,
        Pointer<Uint32>,
      )
    >('RegQueryValueExW');
final _regDeleteValue = _advapi
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)
    >('RegDeleteValueW');
final _regDeleteTree = _advapi
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)
    >('RegDeleteTreeW');
final _regClose = _advapi
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'RegCloseKey',
    );
final _openToken = _advapi
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
      int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
    >('OpenProcessToken');
final _tokenInfo = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        Pointer<Uint32>,
        Uint32,
        Pointer<Uint32>,
      ),
      int Function(Pointer<Void>, int, Pointer<Uint32>, int, Pointer<Uint32>)
    >('GetTokenInformation');
final _currentProcess = _kernel
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetCurrentProcess',
    );
final _closeHandle = _kernel
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'CloseHandle',
    );
final _setAttributes = _kernel
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, int)
    >('SetFileAttributesW');
final _openProcess = _kernel
    .lookupFunction<
      Pointer<Void> Function(Uint32, Int32, Uint32),
      Pointer<Void> Function(int, int, int)
    >('OpenProcess');
// Leaf calls, so nothing the Dart runtime does lies between the failed open
// and reading its error.
final _openProcessLeaf = _kernel
    .lookupFunction<
      Pointer<Void> Function(Uint32, Int32, Uint32),
      Pointer<Void> Function(int, int, int)
    >('OpenProcess', isLeaf: true);
final _lastError = _kernel.lookupFunction<Uint32 Function(), int Function()>(
  'GetLastError',
  isLeaf: true,
);
final _wait = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('WaitForSingleObject');

class WindowsHost implements Host {
  @override
  Map<String, String> get environment => Platform.environment;

  @override
  bool get elevated {
    final token = calloc<Pointer<Void>>();
    final value = calloc<Uint32>();
    final length = calloc<Uint32>();
    try {
      // TOKEN_QUERY; TokenElevation = 20.
      // Fails closed: a token that cannot be read counts as elevated.
      if (_openToken(_currentProcess(), 0x8, token) == 0) return true;
      final ok = _tokenInfo(token.value, 20, value, 4, length) != 0;
      _closeHandle(token.value);
      return !ok || value.value != 0;
    } finally {
      calloc.free(token);
      calloc.free(value);
      calloc.free(length);
    }
  }

  @override
  T withProfileLock<T>(String profile, String library, T Function() action) {
    final dll = DynamicLibrary.open(library);
    final chmod = dll
        .lookupFunction<
          Int32 Function(Pointer<Utf8>),
          int Function(Pointer<Utf8>)
        >('anj_chmod_private');
    final lock = dll
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('anj_profile_lock');
    final close = dll.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'anj_close',
    );
    final error = dll.lookupFunction<Int32 Function(), int Function()>(
      'anj_error',
    );
    final name = dll
        .lookupFunction<
          Pointer<Utf8> Function(Int32),
          Pointer<Utf8> Function(int)
        >('anj_error_name');
    final directory = Directory(profile)..createSync(recursive: true);
    final canonical = directory.resolveSymbolicLinksSync();
    final path = canonical.toNativeUtf8();
    try {
      if (chmod(path) < 0) {
        throw Refused(
          'The profile directory could not be made private (errno ${error()}).',
        );
      }
      final fd = lock(path, -1);
      if (fd < 0) {
        final code = error();
        if (name(code).toDartString() == 'wouldBlock') throw Busy();
        throw Refused('The profile lifetime lock was refused (errno $code).');
      }
      try {
        return action();
      } finally {
        close(fd);
      }
    } finally {
      malloc.free(path);
    }
  }

  // ---- registry ----------------------------------------------------------

  T _withKey<T>(
    String path, {
    required bool write,
    required T Function(Pointer<Void>) action,
    required T absent,
  }) {
    final key = calloc<Pointer<Void>>();
    final name = path.toNativeUtf16();
    try {
      final status = write
          ? _regCreate(
              _hkcu,
              name,
              0,
              nullptr,
              0,
              _keyWrite | _keyRead,
              nullptr,
              key,
              nullptr,
            )
          : _regOpen(_hkcu, name, 0, _keyRead, key);
      // Only a missing key is absent; any other failure is an error, never
      // "missing" (which would let the manager overwrite a foreign entry).
      if (status != 0) {
        if (!write && status == _errorFileNotFound) return absent;
        throw Refused(
          'Registry key $path could not be opened (error $status).',
        );
      }
      try {
        return action(key.value);
      } finally {
        _regClose(key.value);
      }
    } finally {
      calloc.free(key);
      calloc.free(name);
    }
  }

  /// A REG_SZ value: absent only when the key or the value does not exist;
  /// present with `text` null when it has another type (foreign).
  ({bool exists, String? text}) _readString(String path, String value) =>
      _withKey(
        path,
        write: false,
        absent: (exists: false, text: null),
        action: (key) {
          final name = value.toNativeUtf16();
          final type = calloc<Uint32>();
          final size = calloc<Uint32>()..value = 0;
          try {
            final status = _regQuery(key, name, nullptr, type, nullptr, size);
            if (status == _errorFileNotFound) {
              return (exists: false, text: null);
            }
            if (status != 0) {
              throw Refused(
                'Registry value $value could not be read (error $status).',
              );
            }
            if (type.value != _regSz) return (exists: true, text: null);
            final buffer = calloc<Uint8>(size.value + 2);
            try {
              if (_regQuery(key, name, nullptr, type, buffer, size) != 0) {
                throw Refused('Registry value $value could not be read.');
              }
              return (
                exists: true,
                text: buffer
                    .cast<Utf16>()
                    .toDartString(length: size.value ~/ 2)
                    .replaceAll('\u0000', ''),
              );
            } finally {
              calloc.free(buffer);
            }
          } finally {
            calloc.free(name);
            calloc.free(type);
            calloc.free(size);
          }
        },
      );

  /// Whether the key exists at all.
  bool _keyExists(String path) =>
      _withKey(path, write: false, absent: false, action: (_) => true);

  void _write(String path, Map<String, Object> values) => _withKey(
    path,
    write: true,
    absent: null,
    action: (key) {
      for (final MapEntry(key: valueName, value: value) in values.entries) {
        final name = valueName.toNativeUtf16();
        try {
          final int status;
          if (value is int) {
            final data = calloc<Uint32>()..value = value;
            status = _regSet(key, name, 0, _regDword, data.cast(), 4);
            calloc.free(data);
          } else {
            final data = '$value'.toNativeUtf16();
            status = _regSet(
              key,
              name,
              0,
              _regSz,
              data.cast(),
              ('$value'.length + 1) * 2,
            );
            calloc.free(data);
          }
          if (status != 0) {
            throw Refused(
              'Registry value $valueName could not be written ($status).',
            );
          }
        } finally {
          calloc.free(name);
        }
      }
      return;
    },
  );

  @override
  ({bool exists, String? text}) readRun() => _readString(_run, runValueName);
  @override
  void writeRun(String value) => _write(_run, {runValueName: value});
  @override
  void deleteRun() => _withKey(
    _run,
    write: true,
    absent: null,
    action: (key) {
      final name = runValueName.toNativeUtf16();
      _regDeleteValue(key, name);
      calloc.free(name);
      return;
    },
  );

  @override
  ({bool exists, String? text}) readUninstallLocation() {
    final location = _readString(_uninstall, 'InstallLocation');
    // A key without our InstallLocation is still someone's entry.
    if (!location.exists && _keyExists(_uninstall)) {
      return (exists: true, text: null);
    }
    return location;
  }

  @override
  void writeUninstall(Map<String, Object> values) => _write(_uninstall, values);

  /// RegDeleteTreeW with a subkey deletes that key and everything under it.
  @override
  void deleteUninstall() {
    final name = _uninstall.toNativeUtf16();
    _regDeleteTree(_hkcu, name);
    calloc.free(name);
  }

  // ---- shortcut (WScript.Shell, as Explorer writes them) ------------------

  /// PowerShell gets every path and argument through environment
  /// variables, never interpolated into the script, so no quoting rule
  /// (including PowerShell's typographic quotes) can break or extend it.
  static ProcessResult _shell(String script, Map<String, String> values) =>
      Process.runSync('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ], environment: values);

  @override
  ({String target, String arguments})? readShortcut(String path) {
    if (!File(path).existsSync()) return null;
    final result = _shell(
      r'$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:ANJ_LNK); '
      r'$s.TargetPath; $s.Arguments',
      {'ANJ_LNK': path},
    );
    final lines = '${result.stdout}'.split(RegExp(r'\r?\n'));
    if (result.exitCode != 0 || lines.isEmpty) {
      return (target: '', arguments: '');
    }
    return (
      target: lines[0].trim(),
      arguments: lines.length > 1 ? lines[1].trim() : '',
    );
  }

  @override
  void writeShortcut(
    String path, {
    required String target,
    required String arguments,
    required String directory,
    required String icon,
  }) {
    final result = _shell(
      r'$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:ANJ_LNK); '
      r'$s.TargetPath = $env:ANJ_TARGET; $s.Arguments = $env:ANJ_ARGUMENTS; '
      r'$s.WorkingDirectory = $env:ANJ_DIRECTORY; $s.IconLocation = $env:ANJ_ICON; '
      r"$s.Description = 'AnJ Cloud'; $s.Save()",
      {
        'ANJ_LNK': path,
        'ANJ_TARGET': target,
        'ANJ_ARGUMENTS': arguments,
        'ANJ_DIRECTORY': directory,
        'ANJ_ICON': '$icon,0',
      },
    );
    if (result.exitCode != 0) {
      throw Refused(
        'The Start menu shortcut could not be written: ${result.stderr}',
      );
    }
  }

  @override
  void seal(String directory, {required bool readOnly}) {
    for (final entity in Directory(
      directory,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path.toNativeUtf16();
      // FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_NORMAL.
      _setAttributes(path, readOnly ? 0x1 : 0x80);
      calloc.free(path);
    }
  }

  @override
  Future<int> start(String executable, List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: p.dirname(executable),
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }

  @override
  bool processAlive(int pid) {
    // SYNCHRONIZE; a wait of 0 ms times out (0x102) while it runs.
    final handle = _openProcessLeaf(0x00100000, 0, pid);
    if (handle == nullptr) {
      // Only "no such process" (ERROR_INVALID_PARAMETER) means it has
      // exited. Access denied, or anything else, is "cannot tell": treated
      // as still running, so the update waits rather than concluding that
      // the app was started again.
      return _lastError() != 87;
    }
    final state = _wait(handle, 0);
    _closeHandle(handle);
    return state == 0x102;
  }
}

/// Waits (up to [timeout]) for process [pid] to end.
void waitForProcess(int pid, {Duration timeout = const Duration(seconds: 30)}) {
  // SYNCHRONIZE.
  final handle = _openProcess(0x00100000, 0, pid);
  if (handle == nullptr) return;
  _wait(handle, timeout.inMilliseconds);
  _closeHandle(handle);
}
