import 'dart:io';

import '../local/root_tree.dart' show uniqueId;
import '../ports/phone_folders.dart';
import '../ports/release_guard.dart';
import '../ports/root_filesystem.dart';
import '../state/manifest.dart';

/// The status line, once, after the move (spec #52 step 5).
const phoneFoldersMovedNotice =
    "Music, Videos and Documents are now in your phone's folders.";

/// Manifest setting: `moving` while the move runs, `done` after it.
const phoneFolderMoveKey = 'phoneFolderMoveV1';

/// Manifest setting: the [phoneFoldersMovedNotice] is still owed.
const phoneFolderNoticeKey = 'phoneFolderMoveNoticeV1';

/// The one-time move of an existing install's app-private Music, Videos and
/// Documents into the phone's own folders (spec #52 Moving an Existing
/// Install). It runs in the sync worker before the root is opened, so sync
/// is paused for those folders while it runs, and only with All files
/// access (an unpaused [PhoneFolderLayout]).
///
/// Each private file is copied through shared staging (the phone folders'
/// volume), verified by hash and renamed into place without replacing
/// anything; only then is the private copy removed. Nothing is downloaded:
/// the engine finds the same bytes at the same paths. A file the phone
/// already has at that path decides by the existing-contents table: the
/// same bytes link, and different bytes are both kept (the phone's file is
/// never overwritten). Every step can be repeated, so a crash or kill
/// resumes by running again: a phone file holding exactly the private
/// bytes is a step that finished. Working copies and other staged bytes
/// stay in private staging and are installed across volumes later
/// (`MappedRootFs`).
class PhoneFolderMove {
  PhoneFolderMove(
    this.manifest,
    this.native, {
    required this.privateRoot,
    required this.layout,
    this.onProgress,
  });

  final Manifest manifest;
  final RootFilesystem native;
  final String privateRoot;
  final PhoneFolderLayout layout;
  final void Function(String message)? onProgress;

  /// Test seam: called after each step that changes the disk, with a name
  /// (`installed`, `recorded`, `removed`).
  void Function(String step, String path)? debugStep;

  /// Moves whatever is left of the private top folders; returns the number
  /// of files moved or linked.
  int run() {
    if (!Directory(privateRoot).existsSync()) return 0;
    final tops = [
      for (final top in phoneFolderNames.keys)
        if (FileSystemEntity.typeSync(
              '$privateRoot/$top',
              followLinks: false,
            ) ==
            FileSystemEntityType.directory)
          top,
    ];
    if (tops.isEmpty) {
      if (manifest.setting(phoneFolderMoveKey) != 'done') {
        manifest.setSetting(phoneFolderMoveKey, 'done');
      }
      return 0;
    }
    manifest.setSetting(phoneFolderMoveKey, 'moving');
    final privateFd = native.openRoot(privateRoot);
    final staging = Directory(layout.staging)..createSync(recursive: true);
    native.privateDir(layout.staging);
    final marker = File('${staging.path}/.nomedia');
    if (!marker.existsSync()) marker.writeAsStringSync('');
    final baseFd = native.openRoot(layout.base);
    final stageFd = native.openRoot(layout.staging);
    final guard = native.releaseGuard();
    var moved = 0;
    try {
      final items = [
        for (final item in native.scan(privateFd))
          if (tops.contains((item['path'] as String).split('/').first)) item,
      ]..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
      final files = items.where((i) => i['kind'] == 'file').toList();
      // The phone folders and every folder beneath them first.
      for (final top in tops) {
        native.makeDir(baseFd, _phone(top));
        // The top folder is now the phone's folder: recorded as such, so
        // the #150 / #163 identity check does not read the move as the
        // folder being deleted and replaced.
        final row = manifest.entries[top];
        if (row != null) {
          row
            ..localIdentity = native.directoryIdentity(baseFd, _phone(top))
            ..localBirth = null;
        }
      }
      manifest.save();
      for (final item in items.where((i) => i['kind'] == 'directory')) {
        native.makeDir(baseFd, _phone(item['path'] as String));
      }
      for (final item in files) {
        final path = item['path'] as String;
        onProgress?.call(
          'Moving Music, Videos and Documents to your phone\'s folders '
          '(${moved + 1} of ${files.length})…',
        );
        _moveFile(path, privateFd, baseFd, stageFd, guard);
        moved++;
      }
      // The private top folders go, deepest first; anything that is not an
      // ordinary file or folder (none is expected) keeps its folder.
      final folders =
          items
              .where((i) => i['kind'] == 'directory')
              .map((i) => i['path'] as String)
              .toList()
            ..sort((a, b) => b.length.compareTo(a.length));
      for (final folder in [...folders, ...tops]) {
        try {
          Directory('$privateRoot/$folder').deleteSync();
        } on FileSystemException {
          // Not empty: left, and the move runs again at the next start.
        }
      }
    } finally {
      for (final fd in [privateFd, baseFd, stageFd]) {
        native.closeFd(fd);
      }
    }
    final left = phoneFolderNames.keys.any(
      (top) =>
          FileSystemEntity.typeSync('$privateRoot/$top') !=
          FileSystemEntityType.notFound,
    );
    if (!left) {
      manifest.setSetting(phoneFolderMoveKey, 'done');
      // Said once, when there was something to move (a new install's empty
      // folders move silently).
      if (moved > 0) manifest.setSetting(phoneFolderNoticeKey, '1');
    }
    return moved;
  }

  /// The phone path (beneath [PhoneFolderLayout.base]) of engine [path].
  static String _phone(String path) {
    final slash = path.indexOf('/');
    final top = slash < 0 ? path : path.substring(0, slash);
    return '${phoneFolderNames[top]}${path.substring(top.length)}';
  }

  void _moveFile(
    String path,
    int privateFd,
    int baseFd,
    int stageFd,
    ReleaseGuard guard,
  ) {
    final phone = _phone(path);
    final temp = '.anj-install-move-${uniqueId()}';
    final tempFile = File('${layout.staging}/$temp');
    try {
      // One read: the private bytes are copied and hashed together, then
      // the copy is read back from the phone folders' volume.
      final hash = native.copyAndHash(
        privateFd,
        path,
        tempFile,
        purpose: 'phone-move',
      );
      if (native.copyAndHash(stageFd, temp, null, purpose: 'phone-move') !=
          hash) {
        throw FileSystemException('The copy did not verify', path);
      }
      var placed = false;
      try {
        guard.restore(baseFd, phone, stageFd, temp);
        placed = true;
        debugStep?.call('installed', path);
      } on FileSystemException catch (error) {
        if (!_exists(error)) rethrow;
      }
      if (!placed) {
        _alreadyThere(path, phone, hash, baseFd, stageFd, guard, temp);
      }
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
    }
    // The phone copy is verified and recorded: the private copy goes.
    File('$privateRoot/$path').deleteSync();
    debugStep?.call('removed', path);
  }

  /// The phone folder already has a file at [phone] (spec #52 existing
  /// contents): the same bytes are this file (a link, or an earlier run
  /// of this move); different bytes are both kept, never overwritten.
  void _alreadyThere(
    String path,
    String phone,
    String hash,
    int baseFd,
    int stageFd,
    ReleaseGuard guard,
    String temp,
  ) {
    final there = native.copyAndHash(
      baseFd,
      phone,
      null,
      purpose: 'phone-move',
    );
    if (there == hash) return;
    final entry = manifest.entries[path];
    final synced = entry != null && entry.etag != null;
    if (!synced || entry.baselineHash != hash) {
      // Bytes the cloud does not have (never synchronized, or an unsynced
      // edit): kept beside the phone's file under a conflict-copy name,
      // and uploaded from there.
      for (var attempt = 0; ; attempt++) {
        final copy = '$phone.conflict-${uniqueId().substring(0, 8)}';
        try {
          guard.restore(baseFd, copy, stageFd, temp);
          break;
        } on FileSystemException catch (error) {
          if (!_exists(error) || attempt > 8) rethrow;
        }
      }
    }
    if (synced) {
      // The phone's different file meets the cloud's version: the existing
      // conflict rule decides on the next pass (both versions kept).
      entry.refreshRemote = true;
      manifest.save();
    }
    debugStep?.call('recorded', path);
  }

  static bool _exists(FileSystemException error) =>
      error.osError?.errorCode == 17;
}
