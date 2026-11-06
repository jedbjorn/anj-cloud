import 'dart:io';

import 'package:path/path.dart' as p;

import '../ports/root_filesystem.dart';
import '../state/manifest.dart';
import 'root_identity.dart';
import 'root_tree.dart';

/// Moves an existing profile's staging out of sight (spec #34 P3.2): a
/// profile created before P3 stages in `.anj-cloud-<profileId>/` beside its
/// root. At worker start, before the root is opened, staging that holds no
/// pending work moves to where a new profile's staging goes
/// ([RootTree.stagingFor]) and the empty sibling is removed. While work is
/// pending (any file in it, or any journaled operation naming a file there)
/// it stays and the move is retried at the next start.
///
/// The move needs a definite answer about the root that was accepted: the
/// root's current identity must equal the stored `rootIdentity` (otherwise
/// the root checks pause the worker and nothing moves), and the probe must
/// say `inside` or `otherDevice`; an unknown answer (a read-only root, a
/// full disk) keeps the current staging and retries at the next start.
/// Pending work includes recovery copies named by entries
/// (`preservedCopies`, `remoteCopy`), so none becomes undismissable.
///
/// Journaled in the profile's settings: `staging` and `stagingMovedFrom` are
/// written in one transaction before the old folder is removed, and a start
/// after an interruption finishes the removal. Only an empty directory is
/// ever removed (rmdir); a folder that gained an entry is kept in use.
/// Returns the staging path to use.
String settleStaging(
  Manifest manifest,
  String profileDir,
  RootFilesystem native,
) {
  final movedFrom = manifest.setting('stagingMovedFrom');
  if (movedFrom != null) {
    _removeEmpty(movedFrom);
    manifest.deleteSetting('stagingMovedFrom');
  }
  final root = manifest.setting('root');
  final staging = manifest.setting('staging');
  final profileId = manifest.setting('profileId');
  if (root == null || staging == null || profileId == null) {
    return staging ?? '';
  }
  final accepted = _acceptedRoot(manifest, root, native);
  // A probe folder an interrupted earlier probe left at the top of the root
  // (excluded from sync) is removed when empty.
  if (accepted) RootTree.sweepProbes(Directory(root));
  // Only the pre-P3 sibling moves; a P3 location stays where it was chosen.
  final legacy = p.join(p.dirname(root), '.anj-cloud-$profileId');
  if (!p.equals(p.normalize(staging), legacy)) return staging;
  if (_pending(manifest, staging)) return staging;
  if (!Directory(root).existsSync()) return staging;
  if (!accepted) return staging;
  final target = switch (RootTree.probeStaging(
    Directory(root),
    profileDir,
    native,
  )) {
    StagingProbe.inside => p.join(profileDir, 'staging'),
    StagingProbe.otherDevice => RootTree.siblingStaging(
      Directory(root),
      profileId,
    ).path,
    StagingProbe.unknown => staging,
  };
  if (p.equals(target, staging)) return staging;
  final existing = Directory(target);
  if (existing.existsSync() && existing.listSync().isNotEmpty) {
    // Not ours to merge into; the sibling keeps working.
    return staging;
  }
  // The new folder exists, private, before anything is switched to it: if it
  // cannot be made (a parent that is not writable), the old one stays.
  try {
    existing.createSync();
    native.privateDir(target);
  } on FileSystemException {
    return staging;
  }
  manifest.transaction(() {
    manifest.setSetting('staging', target);
    manifest.setSetting('stagingMovedFrom', staging);
  });
  if (!_removeEmpty(staging)) {
    // Something appeared in the old folder: keep using it, change nothing.
    manifest.transaction(() {
      manifest.setSetting('staging', staging);
      manifest.deleteSetting('stagingMovedFrom');
    });
    return staging;
  }
  manifest.deleteSetting('stagingMovedFrom');
  return target;
}

bool _pending(Manifest manifest, String staging) {
  final folder = Directory(staging);
  if (folder.existsSync() && folder.listSync().isNotEmpty) return true;
  bool inside(String? path) => path != null && p.isWithin(staging, path);
  return manifest.operations.values.any((o) => inside(o.staged)) ||
      manifest.entries.values.any(
        (e) => inside(e.remoteCopy) || e.preservedCopies.any(inside),
      );
}

/// The root at [root] is the one this profile recorded (the same check the
/// worker's root acceptance makes first); anything else decides nothing.
bool _acceptedRoot(Manifest manifest, String root, RootFilesystem native) {
  final stored = manifest.setting('rootIdentity');
  if (stored == null) return false;
  int? fd;
  try {
    fd = native.openRoot(root);
    return sameRootIdentity(stored, native.rootInfo(fd).identity);
  } on Object {
    return false;
  } finally {
    if (fd != null && fd >= 0) native.closeFd(fd);
  }
}

/// rmdir only: true when [path] is gone (removed now or already absent).
bool _removeEmpty(String path) {
  final folder = Directory(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return true;
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return false;
  }
  try {
    folder.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}
