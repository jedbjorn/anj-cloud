import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ports/root_placement.dart';

/// macOS root placement (spec #31 M8, decision #164: onboarding parity with
/// spec #34 P1-P3).
///
/// - P1: the synced folder goes in the home folder (`~/anj-cloud/`, as #82
///   intends), or in a root the installer reserved for this profile.
/// - P2: the shortcut goes in `~/Desktop` when that folder exists. Desktop
///   is privacy-protected: macOS may ask once whether AnJ Cloud may use it.
///   A refusal makes the link fail, which the shared controller records
///   once (`desktopShortcut`), so it is never asked again and sync is
///   unaffected.
/// - P3: staging goes inside the profile. The shared setup proves it by a
///   rename probe into the root, which only succeeds on the same volume
///   (APFS: the same volume UUID); otherwise it falls back to the dot-named
///   sibling, and existing profiles migrate as on Linux.
///
/// [environment] supplies `HOME` (tests pass a temporary one).
class MacosRootPlacement implements RootPlacement {
  MacosRootPlacement({Map<String, String>? environment, this.reservedParent})
    : environment = environment ?? Platform.environment;
  final Map<String, String> environment;
  final String? reservedParent;

  String? get _home {
    final home = environment['HOME'];
    return home == null || home.isEmpty || !p.isAbsolute(home) ? null : home;
  }

  @override
  String? defaultParent() => reservedParent ?? _home;

  @override
  bool get stagingInProfile => true;

  /// `~/Desktop` when it is a directory. Only the folder itself is looked
  /// at here (a stat, which macOS does not guard); its contents are touched
  /// only when the link is made.
  @override
  String? desktopDirectory() {
    final home = _home;
    if (home == null) return null;
    final desktop = p.join(p.normalize(home), 'Desktop');
    return FileSystemEntity.typeSync(desktop) == FileSystemEntityType.directory
        ? desktop
        : null;
  }

  @override
  Set<String> keptDirectories() {
    final home = _home;
    return home == null ? const {} : standardUserDirectories(home);
  }
}
