/// Port: where a platform allows the sync root (spec #31 "Root and
/// Storage"). Linux and Windows accept any location the root checks accept
/// ([AnyRootLocation]); macOS refuses folders that privacy controls
/// protect, other sync providers' folders, Time Machine snapshots and
/// volumes that are not local APFS (`MacosRootLocation`).
library;

abstract interface class RootLocationPolicy {
  /// Why [rootPath] (the canonical path of the `anj-cloud` root, symlinks
  /// resolved) may not be the sync root on this platform, as a sentence for
  /// the user; null when it may.
  ///
  /// [fd] is an open descriptor on the root itself (the engine, at every
  /// start); without it (the root picker, before anything is created) the
  /// volume is that of the nearest existing directory above [rootPath].
  /// A volume that cannot be read is refused, never assumed.
  String? refuseRoot(String rootPath, {int? fd});
}

/// No platform rule beyond the shared root checks (Linux, Windows).
class AnyRootLocation implements RootLocationPolicy {
  const AnyRootLocation();

  @override
  String? refuseRoot(String rootPath, {int? fd}) => null;
}
