/// Port: where a new profile's synced folder and its desktop shortcut go
/// (spec #34 P1, P2).
///
/// Linux: `XdgRootPlacement` (lib/platform/linux/xdg_root_placement.dart):
/// the home folder (or the installer's reserved root) and the XDG desktop
/// directory. macOS: `MacosRootPlacement` (spec #31 M8, decision #164): the
/// home folder and `~/Desktop`. Windows has no automatic root yet (spec #32
/// gains it when it next revises) and keeps the folder picker.
library;

import 'package:path/path.dart' as p;

abstract interface class RootPlacement {
  /// The folder in which a new profile's `anj-cloud/` is created without a
  /// picker, or null when this platform has no automatic root.
  String? defaultParent();

  /// The directory a desktop shortcut to the synced folder goes in, or null
  /// when there is none (no shortcut is made).
  String? desktopDirectory();

  /// Whether staging goes inside the profile when renames reach the root,
  /// and an existing profile's sibling staging moves there (spec #34 P3).
  /// False keeps the earlier `.anj-cloud-<profileId>` sibling untouched.
  bool get stagingInProfile;

  /// Folders AnJ Cloud never removes, even when empty: the home folder and
  /// the user directories of the desktop (Desktop, Documents, Music, …).
  /// Moving the synced folder (Linux `move-root`) removes its old parent
  /// only when it is empty and not one of these.
  Set<String> keptDirectories();
}

/// No automatic root, no shortcut and the earlier staging sibling: the
/// folder picker only (Windows until spec #32 revises).
class PickerOnlyPlacement implements RootPlacement {
  const PickerOnlyPlacement();

  @override
  String? defaultParent() => null;

  @override
  String? desktopDirectory() => null;

  @override
  bool get stagingInProfile => false;

  @override
  Set<String> keptDirectories() => const {};
}

/// The usual user directories under [home] (xdg-user-dirs' defaults and the
/// macOS home folders), and [home] itself.
Set<String> standardUserDirectories(String home) => {
  p.normalize(home),
  for (final name in const [
    'Desktop',
    'Documents',
    'Downloads',
    'Music',
    'Pictures',
    'Public',
    'Templates',
    'Videos',
    'Movies',
  ])
    p.join(p.normalize(home), name),
};
