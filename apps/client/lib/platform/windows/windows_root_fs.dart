import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ports/root_filesystem.dart';
import '../native/native_root_fs.dart';

/// Where the Windows [RootFilesystem] loads `anj_rootfs.dll` from
/// (native/windows/rootfs_win.cc, spec #32 W2): `ANJ_ROOTFS_LIBRARY` when set
/// (tests, the seat recipe), otherwise beside the executable, where the
/// runner's CMake installs it.
String windowsRootfsLibrary({
  String? executable,
  Map<String, String>? environment,
}) =>
    (environment ?? Platform.environment)['ANJ_ROOTFS_LIBRARY'] ??
    p.windows.join(
      p.windows.dirname(executable ?? Platform.resolvedExecutable),
      'anj_rootfs.dll',
    );

/// The Windows [RootFilesystem] and its release guard: the shared binding
/// (lib/platform/native/) over `anj_rootfs.dll`, which implements the same
/// `anj_*` C ABI as libanj_rootfs (native/posix/exports.txt) with
/// handle-table descriptors. Its error numbers are Linux's, so the label
/// says so.
///
/// NTFS gives no trusted stamps (Linux's writeback rule does not apply), so
/// with a working watcher the engine hashes event-driven, as on macOS
/// (decision #135): every file at start, after lost events (an overflow,
/// the root's watch failing, a suspend), when the watcher restarts, and at
/// least every [windowsFullVerificationInterval]; the 5-minute stat audit
/// (decision #51) is unchanged.
RootFilesystem windowsRootFilesystem([String? library]) => NativeRootFs(
  library ?? windowsRootfsLibrary(),
  'Linux errno (anj_rootfs.dll)',
  windowsFullVerificationInterval,
);

/// The longest an event-driven Windows root goes without a full
/// verification pass (macOS uses the same 60 minutes, decision #135).
const windowsFullVerificationInterval = Duration(minutes: 60);
