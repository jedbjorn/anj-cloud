/// Port: root identity (decision #74).
///
/// The synchronized root is recognised across restarts and reboots by a
/// `volume:ino` identity the platform derives from the filesystem. Linux:
/// statfs f_fsid on ext2/3/4 and btrfs, otherwise st_dev, plus the inode and
/// statx birth time (`volume_key` / `anj_root_info` in native/posix/rootfs.cc,
/// bound by `NativeRootFs` in lib/platform/native/native_root_fs.dart).
library;

typedef RootInfo = ({String identity, String legacy, bool stable});

abstract interface class RootIdentitySource {
  /// `volume:ino` of an open descriptor.
  String identity(int fd);

  /// `volume:ino:size:mtime_ns:ctime_ns` of an open descriptor.
  String stamp(int fd);

  /// Identity of the synchronized root as persisted in `rootIdentity`
  /// ([RootInfo.identity]), the pre-fix `st_dev:st_ino` form
  /// ([RootInfo.legacy], for migration only) and whether the volume key is
  /// an on-disk fsid that survives reboot ([RootInfo.stable]).
  RootInfo rootInfo(int fd);
}
