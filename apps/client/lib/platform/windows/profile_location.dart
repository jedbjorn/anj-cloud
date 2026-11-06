/// Where the Windows profile lives (spec #32 Locations, #134), shared by the
/// client and the manager (tool/windows_manager), so it imports only
/// dart:io and path.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The managed profile: `%LOCALAPPDATA%\anj-cloud\profile`.
String windowsProfile(String localAppData) =>
    p.join(localAppData, 'anj-cloud', 'profile');

/// The pre-W5 default: the Roaming application support directory
/// (`%APPDATA%\<CompanyName>\<ProductName>`, windows/runner/Runner.rc) plus
/// `anj-cloud\default`.
String windowsLegacyProfile(String roamingAppData) =>
    p.join(roamingAppData, 'cloud.anj', 'anj_cloud', 'anj-cloud', 'default');

/// A profile directory that holds nothing yet: absent, or only the lock file
/// a manager or a client takes before anything is written.
bool unusedProfile(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) return true;
  return directory
      .listSync(followLinks: false)
      .every((entity) => p.basename(entity.path) == '.instance.lock');
}

/// Moves a pre-W5 Roaming profile to [target] once, when [target] is still
/// unused. Returns the profile to use and, when something was left alone or
/// could not move, why. A move that fails (the old profile is in use) leaves
/// both where they are; the caller decides whether to go on with the old one.
({String profile, bool moved, String? note}) adoptLegacyProfile({
  required String target,
  required String legacy,
}) {
  if (FileSystemEntity.typeSync(legacy, followLinks: false) !=
      FileSystemEntityType.directory) {
    return (profile: target, moved: false, note: null);
  }
  if (!unusedProfile(target)) {
    return (
      profile: target,
      moved: false,
      note:
          'An earlier profile in Roaming AppData ($legacy) was left alone: '
          '$target is already in use.',
    );
  }
  try {
    final lock = File(p.join(target, '.instance.lock'));
    if (lock.existsSync()) lock.deleteSync();
    if (Directory(target).existsSync()) Directory(target).deleteSync();
    Directory(p.dirname(target)).createSync(recursive: true);
    Directory(legacy).renameSync(target);
    return (profile: target, moved: true, note: null);
  } on FileSystemException catch (error) {
    return (
      profile: legacy,
      moved: false,
      note:
          'The earlier profile in Roaming AppData could not be moved yet '
          '(${error.osError?.message ?? error.message}); is an older AnJ Cloud running?',
    );
  }
}
