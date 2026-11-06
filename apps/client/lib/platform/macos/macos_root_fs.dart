import '../../core/ports/root_filesystem.dart';
import '../native/native_root_fs.dart';
import 'macos_platform_adapters.dart' show macosFullVerificationInterval;

/// macOS [RootFilesystem]: the shared POSIX binding over the bundle's
/// libanj_rootfs.dylib, with macOS answers to the stamp-reuse questions:
///
/// - [writeback]: none. macOS has no /proc/sys/vm and no periodic writeback
///   parameters the client can read, so the stamp fast path stays off
///   (decision #39).
/// - [trustedFsMagic]: empty; with no writeback signal no filesystem's stamps
///   are trusted.
/// - [fullVerificationInterval]: [macosFullVerificationInterval], so with
///   the FSEvents watcher passes hash event-driven (decision #135).
class MacosRootFs extends NativeRootFs {
  MacosRootFs(String library)
    : super(library, 'macOS errno', macosFullVerificationInterval);

  @override
  WritebackParameters? writeback({String? directory}) =>
      directory == null ? null : super.writeback(directory: directory);

  @override
  Set<int> get trustedFsMagic => const {};
}
