import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/ports/root_location.dart';

/// The facts about a volume the location policy needs, from `statfs(2)`.
class MacosVolume {
  const MacosVolume({
    required this.type,
    required this.local,
    required this.mountPoint,
    this.readOnly = false,
  });

  /// `f_fstypename`, for example `apfs`, `hfs`, `msdos`, `exfat`, `smbfs`.
  final String type;

  /// `MNT_LOCAL` in `f_flags`: false for network filesystems.
  final bool local;

  /// `f_mntonname`.
  final String mountPoint;

  /// `MNT_RDONLY` in `f_flags`.
  final bool readOnly;

  /// Darwin arm64 `struct statfs` (64-bit inodes; `<sys/mount.h>`):
  /// f_flags at 64, f_fstypename[16] at 72, f_mntonname[1024] at 88,
  /// 2168 bytes in all.
  static const structSize = 2168;
  static const _flagsOffset = 64;
  static const _typeOffset = 72;
  static const _mountOffset = 88;
  static const _mntLocal = 0x00001000;
  static const _mntReadOnly = 0x00000001;

  static MacosVolume fromStatfs(Uint8List bytes) {
    String text(int offset, int length) {
      final field = bytes.sublist(offset, offset + length);
      final end = field.indexOf(0);
      return utf8.decode(
        end < 0 ? field : field.sublist(0, end),
        allowMalformed: true,
      );
    }

    final flags = ByteData.sublistView(bytes)
        .getUint32(_flagsOffset, Endian.little);
    return MacosVolume(
      type: text(_typeOffset, 16),
      local: flags & _mntLocal != 0,
      readOnly: flags & _mntReadOnly != 0,
      mountPoint: text(_mountOffset, 1024),
    );
  }

  @override
  String toString() => '$type${local ? '' : ' (network)'} at $mountPoint';
}

typedef _StatfsPath = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatfsFd = Int32 Function(Int32, Pointer<Uint8>);

/// `statfs`/`fstatfs` from libSystem (already loaded in every process).
/// Null when the call fails.
MacosVolume? _statfs(int Function(Pointer<Uint8>) call) {
  final buffer = calloc<Uint8>(MacosVolume.structSize);
  try {
    if (call(buffer) != 0) return null;
    return MacosVolume.fromStatfs(
      Uint8List.fromList(buffer.asTypedList(MacosVolume.structSize)),
    );
  } finally {
    calloc.free(buffer);
  }
}

MacosVolume? macosVolumeAt(String path) {
  final statfs = DynamicLibrary.process()
      .lookupFunction<_StatfsPath, int Function(Pointer<Utf8>, Pointer<Uint8>)>(
        'statfs',
      );
  final native = path.toNativeUtf8();
  try {
    return _statfs((buffer) => statfs(native, buffer));
  } finally {
    malloc.free(native);
  }
}

MacosVolume? macosVolumeOf(int fd) {
  final fstatfs = DynamicLibrary.process()
      .lookupFunction<_StatfsFd, int Function(int, Pointer<Uint8>)>('fstatfs');
  return _statfs((buffer) => fstatfs(fd, buffer));
}

/// macOS root location policy (spec #31 "Root and Storage", planner
/// proposal): the root picker and the engine refuse, with a plain reason, a
/// root in or under
///
/// - `~/Desktop`, `~/Documents`, `~/Downloads` (privacy-protected, and
///   synced by iCloud when "Desktop & Documents" is on);
/// - `~/Library/Mobile Documents` and `~/Library/CloudStorage` (other sync
///   providers);
/// - a Time Machine snapshot or backup volume;
/// - a read-only volume, a network volume, or a local volume that is not
///   APFS.
///
/// External APFS volumes are allowed; `~/anj-cloud` (the home folder as the
/// root setting, #82) is outside every protected folder, so it raises no
/// privacy prompt. Paths compare without case, as APFS does by default, and
/// the home folder is also matched through its `/System/Volumes/Data` firmlink.
class MacosRootLocation implements RootLocationPolicy {
  MacosRootLocation({
    String? home,
    MacosVolume? Function(String path)? volumeAt,
    MacosVolume? Function(int fd)? volumeOf,
  }) : home = home ?? Platform.environment['HOME'],
       _volumeAt = volumeAt ?? macosVolumeAt,
       _volumeOf = volumeOf ?? macosVolumeOf;

  final String? home;
  final MacosVolume? Function(String path) _volumeAt;
  final MacosVolume? Function(int fd) _volumeOf;

  /// Where macOS mounts Time Machine local snapshots and backup volumes.
  static const timeMachine = [
    '/Volumes/com.apple.TimeMachine.localsnapshots',
    '/Volumes/.timemachine',
  ];
  static const _data = '/System/Volumes/Data';
  static const _suggestion =
      'Choose another parent folder, such as your home folder.';

  static bool _under(String path, String folder) {
    final a = path.toLowerCase();
    final b = folder.toLowerCase();
    return a == b || p.isWithin(b, a);
  }

  @override
  String? refuseRoot(String rootPath, {int? fd}) {
    final root = p.normalize(rootPath);
    final homes = [
      ?home,
      if (home != null && home!.startsWith('/') && !home!.startsWith(_data))
        '$_data$home',
    ];
    for (final base in homes) {
      for (final name in ['Desktop', 'Documents', 'Downloads']) {
        if (_under(root, p.join(base, name))) {
          return 'macOS protects your $name folder, and iCloud may sync it. '
              '$_suggestion';
        }
      }
      for (final name in ['Mobile Documents', 'CloudStorage']) {
        if (_under(root, p.join(base, 'Library', name))) {
          return 'This folder belongs to another sync service (iCloud Drive '
              'or a cloud storage provider). $_suggestion';
        }
      }
    }
    if (timeMachine.any((folder) => _under(root, folder))) {
      return 'This folder is inside a Time Machine snapshot. $_suggestion';
    }
    final volume = fd != null ? _volumeOf(fd) : _volumeAt(_existing(root));
    if (volume == null) {
      return 'The volume holding this folder could not be checked. '
          '$_suggestion';
    }
    if (timeMachine.any((folder) => _under(volume.mountPoint, folder))) {
      return 'This folder is inside a Time Machine snapshot. $_suggestion';
    }
    if (volume.readOnly) {
      return 'This folder is on a read-only volume. $_suggestion';
    }
    if (!volume.local) {
      return 'This folder is on a network volume (${volume.type}). AnJ Cloud '
          'syncs only folders on a local APFS volume. $_suggestion';
    }
    if (volume.type != 'apfs') {
      return 'This folder is on a ${volume.type} volume, not APFS. AnJ Cloud '
          'syncs only folders on a local APFS volume. $_suggestion';
    }
    return null;
  }

  /// The nearest existing directory at or above [path] (the picker checks
  /// a root that does not exist yet).
  static String _existing(String path) {
    var current = path;
    while (!Directory(current).existsSync()) {
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return current;
  }
}
