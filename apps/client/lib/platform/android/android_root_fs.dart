import '../../core/ports/release_guard.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/sync/open_documents.dart';
import '../../core/ports/phone_folders.dart';
import '../native/mapped_root_fs.dart';
import '../native/native_root_fs.dart';

/// The longest an Android root goes without a full verification pass while
/// the app is open (decision #130 (3)).
const androidFullVerificationInterval = Duration(minutes: 15);

/// Android [RootFilesystem] (spec #28 A2): the same `anj_*` ABI as Linux,
/// built with the NDK from native/posix/rootfs.cc with compat_android.h (no
/// openat2, no linkat; decision #123), and bound by the shared FFI binding.
///
/// The app sandbox cannot read /proc/sys/vm (A1), so [writeback] reports
/// nothing and the stamp fast path stays off: every file is hashed every
/// pass, the existing rule (#39, decision #123 (6)). It does not try the
/// read either, which would log an SELinux denial at every pass.
///
/// Hashing every file every pass costs about 5 s per GiB on the emulator, so
/// ordinary passes hash only what the inotify watcher reported and a full
/// verification runs at most every [fullVerificationInterval] (decision
/// #130 (3)).
class AndroidRootFs extends NativeRootFs {
  AndroidRootFs([String? library])
    : super(library, 'Linux errno', androidFullVerificationInterval);

  /// The F_SETLEASE guard (the Android default, #123 (3)) behind the
  /// documents provider's open-descriptor registry (defence in depth).
  @override
  ReleaseGuard releaseGuard() => RegisteredReleaseGuard(super.releaseGuard());

  /// linkat is refused in the app sandbox (A1): ordinary installs rename the
  /// staged file (decision #123 (2)).
  @override
  bool get hardLinks => false;

  @override
  WritebackParameters? writeback({String? directory}) =>
      directory == null ? null : super.writeback(directory: directory);
}

/// [AndroidRootFs] with the phone folders mapped (spec #52): Music, Videos
/// and Documents resolve in shared storage ([MappedRootFs]); the rest of
/// the root stays app-private. The same Android facts as [AndroidRootFs].
class AndroidPhoneRootFs extends MappedRootFs {
  AndroidPhoneRootFs(PhoneFolderLayout layout, [String? library])
    : super(layout, library, 'Linux errno', androidFullVerificationInterval);

  /// The mapped guard, behind the documents provider's open-descriptor
  /// registry; in shared storage, where no lease can be taken, the native
  /// guard is the weaker unchanged-content guard (#108 Q15).
  @override
  ReleaseGuard releaseGuard() => RegisteredReleaseGuard(super.releaseGuard());

  @override
  bool get hardLinks => false;

  @override
  WritebackParameters? writeback({String? directory}) =>
      directory == null ? null : super.writeback(directory: directory);
}
