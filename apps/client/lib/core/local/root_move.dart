import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ports/root_filesystem.dart';
import '../ports/root_identity_source.dart';
import '../state/manifest.dart';
import 'desktop_shortcut.dart';
import 'root_identity.dart';
import 'root_tree.dart';

/// The journal of an unfinished move (JSON), kept in the profile's settings.
const rootMoveSetting = 'rootMove';

/// The synced folder's name: the client syncs `<parent>/anj-cloud/`.
const syncedFolderName = 'anj-cloud';

/// A move that was not made. Nothing was changed unless [journalKept]: then
/// the journal in the profile explains where the folder is, and running the
/// command again (or the next app start) finishes or undoes it.
class RootMoveRefused implements Exception {
  const RootMoveRefused(
    this.message, {
    this.entries = const [],
    this.journalKept = false,
  });
  final String message;

  /// The unexpected entries that prevented a nested move.
  final List<String> entries;
  final bool journalKept;

  @override
  String toString() => message;
}

/// Moves a profile's synced folder to another place on the same filesystem
/// (Linux `linux_install.py move-root`; Feature #19, after spec #34). Run
/// with the profile's lifetime lock held (the app is not running).
///
/// Only rename(2) with RENAME_NOREPLACE, so the folder keeps its inode and
/// birth time and `rootIdentity` still matches: no file is copied, uploaded,
/// downloaded or deleted, and the next start accepts the root as
/// [RootOutcome.matched]. A target on another filesystem or btrfs subvolume
/// is refused, never copied.
///
/// Two layouts: the ordinary one (`~/AnJ Cloud/anj-cloud` to
/// `~/anj-cloud`, a single rename), and the nested one, where the target is
/// the folder's own parent (`~/anj-cloud/anj-cloud`) holding only the
/// folder and this profile's empty staging sibling: the folder is renamed
/// aside to a temporary name, the emptied parent removed and the folder
/// renamed into its place.
///
/// Crash safety: the intended move is journaled in [rootMoveSetting] before
/// the first rename. Each later step is found from where the folder is (its
/// identity at the journaled source, temporary or target path): a re-run
/// ([move]) completes it, the next app start ([resumeAtStart]) completes
/// it once the folder has left its source, or drops the journal when the
/// folder was not renamed yet (after finishing a staging move that began).
/// The `staging` switch and the `root` switch are each one transaction; the
/// journal is removed only after the clean-up.
///
/// Staging finishes where spec #34 P3 puts it: inside the profile when
/// renames reach the root from there, otherwise the dot-named sibling beside
/// the new folder. A staging folder outside the profile moves first, by
/// rename as a whole (its completed transfer copies, hard-link aliases and
/// kept copies with it), and `staging` plus every path recorded inside it
/// switch in one transaction; unfinished operations naming it refuse the
/// move. The old parent folder is removed only when empty and not one of
/// [keep] (the home folder and the desktop's user directories).
class RootMover {
  RootMover(
    this.manifest,
    String profileDir,
    this.native, {
    this.desktop,
    Set<String> keep = const {},
    List<String> knownRoots = const [],
    this.step,
  }) : profileDir = Directory(profileDir).resolveSymbolicLinksSync(),
       keep = {for (final k in keep) p.normalize(k)},
       knownRoots = [for (final k in knownRoots) p.normalize(k)];

  final Manifest manifest;
  final String profileDir;
  final RootFilesystem native;

  /// Where the `AnJ Cloud` shortcut goes (spec #34 P2); null: none.
  final String? desktop;
  final Set<String> keep;

  /// Paths of other profiles and synchronizers the target must not overlap.
  final List<String> knownRoots;

  /// Test seam: called after each durable step (a crash there is modelled
  /// by throwing).
  final void Function(String step)? step;

  /// Moves the synced folder to [target] (an absolute path ending in
  /// `anj-cloud`), or finishes an interrupted move to the same target.
  Future<Map<String, Object?>> move(String target) async {
    final pending = manifest.setting(rootMoveSetting);
    if (pending != null) {
      final journal = _Journal.decode(pending);
      if (!p.equals(_canonicalTarget(target), journal.to)) {
        throw RootMoveRefused(
          'An interrupted move to ${journal.to} is not finished. Run '
          'move-root --to "${journal.to}" to finish it first.',
          journalKept: true,
        );
      }
      return journal.phase == _cleanup
          ? await _cleanUp(journal)
          : await _forward(journal);
    }
    final journal = _plan(target);
    if (journal == null) {
      return {'moved': false, 'root': manifest.setting('root')};
    }
    manifest.setSetting(rootMoveSetting, journal.encode());
    step?.call('journaled');
    return await _forward(journal);
  }

  /// At app start, before the root is used: finishes a move that was
  /// interrupted after the folder left its source, or drops the journal of
  /// one that renamed nothing yet. Null when no move was pending. A move
  /// that can be neither finished nor undone throws [RootMoveRefused] and
  /// keeps its journal.
  Future<Map<String, Object?>?> resumeAtStart() async {
    final pending = manifest.setting(rootMoveSetting);
    if (pending == null) return null;
    final journal = _Journal.decode(pending);
    if (journal.phase == _cleanup) return await _cleanUp(journal);
    // A staging move that began is finished first: staging in its P3 place
    // with the synced folder still at its source is a consistent profile.
    // One that did not begin is not started.
    if (_stagingMoveBegan(journal)) _moveStaging(journal);
    if (_locate(journal) == _Where.from) {
      manifest.deleteSetting(rootMoveSetting);
      return {'moved': false, 'undone': true, 'root': journal.from};
    }
    return await _forward(journal);
  }

  _Journal? _plan(String target) {
    final root = manifest.setting('root');
    final staging = manifest.setting('staging');
    final stored = manifest.setting('rootIdentity');
    final profileId = manifest.setting('profileId');
    if (root == null ||
        staging == null ||
        stored == null ||
        profileId == null) {
      throw const RootMoveRefused(
        'This profile has no synced folder yet; there is nothing to move.',
      );
    }
    final to = _canonicalTarget(target);
    if (p.equals(to, root)) return null;
    if (p.isWithin(root, to)) {
      throw RootMoveRefused('$to is inside the synced folder $root.');
    }
    for (final other in [...knownRoots, profileDir]) {
      if (p.equals(to, other) ||
          p.isWithin(to, other) ||
          p.isWithin(other, to)) {
        throw RootMoveRefused(
          '$to overlaps $other, which belongs to another profile, '
          'synchronizer or this profile\'s private state.',
        );
      }
    }
    final RootInfo info;
    try {
      info = _rootInfo(root);
    } on FileSystemException catch (error) {
      throw RootMoveRefused(
        'The synced folder $root cannot be opened (${_reason(error)}). Start '
        'AnJ Cloud to see why.',
      );
    }
    if (!sameRootIdentity(stored, info.identity)) {
      throw RootMoveRefused(
        'The folder at $root is not the one this profile recorded (its '
        'identity does not match). Start AnJ Cloud once: it checks the '
        'folder and records it, then quit and run move-root again.',
      );
    }
    final volume = info.identity.split(':').first;
    for (final folder in [p.dirname(root), p.dirname(to)]) {
      if (_volume(folder) != volume) {
        throw RootMoveRefused(
          '$to is not on the same filesystem (or btrfs subvolume) as $root. '
          'move-root only renames the folder and never copies it.',
        );
      }
    }
    final nested = p.equals(to, p.dirname(root));
    if (nested) {
      final allowed = {
        syncedFolderName,
        if (p.equals(p.dirname(staging), to)) p.basename(staging),
      };
      final others = [
        for (final entry in Directory(to).listSync(followLinks: false))
          if (!allowed.contains(p.basename(entry.path))) entry.path,
      ]..sort();
      if (others.isNotEmpty) {
        throw RootMoveRefused(
          '$to holds more than the synced folder, so it cannot become the '
          'synced folder. Move these elsewhere first: ${others.join(', ')}',
          entries: others,
        );
      }
    } else if (FileSystemEntity.typeSync(to, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw RootMoveRefused(
        '$to already exists. move-root never merges into or replaces an '
        'existing folder; move it away (or choose another --to) and retry.',
      );
    }
    final via = nested
        ? p.join(p.dirname(to), '.anj-cloud-move-$profileId')
        : null;
    if (via != null &&
        FileSystemEntity.typeSync(via, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw RootMoveRefused(
        '$via exists; it is not AnJ Cloud\'s to replace. Remove it and retry.',
      );
    }
    String? stagingTo;
    if (!p.isWithin(profileDir, staging)) {
      final busy = _stagingWork(staging);
      if (busy != null) throw RootMoveRefused(busy);
      stagingTo = _stagingTarget(root, to, profileId);
    }
    return _Journal(
      from: root,
      to: to,
      via: via,
      phase: _move,
      stagingFrom: staging,
      stagingTo: stagingTo,
    );
  }

  /// Where staging goes (spec #34 P3): `<profile>/staging` when renames
  /// reach the root from there, otherwise the dot-named sibling beside the
  /// new folder. It must be absent or an empty folder.
  String _stagingTarget(String root, String to, String profileId) {
    final target =
        RootTree.probeStaging(Directory(root), profileDir, native) ==
            StagingProbe.inside
        ? p.join(profileDir, 'staging')
        : RootTree.siblingStaging(Directory(to), profileId).path;
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type == FileSystemEntityType.notFound ||
        (type == FileSystemEntityType.directory &&
            Directory(target).listSync(followLinks: false).isEmpty)) {
      return target;
    }
    throw RootMoveRefused(
      '$target is already in use, so the staging folder cannot move there. '
      'Nothing was changed.',
    );
  }

  /// Unfinished work naming [staging]: any operation other than a finished
  /// staging record (a completed transfer copy, a retained copy, the
  /// archived history of an excluded path). Finished records, kept copies
  /// and their files move with the folder.
  String? _stagingWork(String staging) {
    bool inside(String? value) =>
        value != null &&
        (p.equals(value, staging) || p.isWithin(staging, value));
    bool mentions(Object? value) => value is String
        ? inside(value)
        : value is Map
        ? value.values.any(mentions)
        : value is List && value.any(mentions);
    final busy = [
      for (final o in manifest.operations.values)
        if ((inside(o.staged) || mentions(o.data)) &&
            !(o.kind == 'artifact' && o.phase == 'complete') &&
            o.kind != 'retained' &&
            // Archived history of an excluded path (an operation or an
            // entry), never replayed; its recorded paths move with the
            // folder like the others.
            o.kind != 'excluded-operation' &&
            o.kind != 'excluded-entry')
          o,
    ];
    if (busy.isEmpty) return null;
    final kinds = {for (final o in busy) o.kind}.toList()..sort();
    return 'AnJ Cloud still has unfinished work in its staging folder '
        '$staging (${busy.length} operations: ${kinds.join(', ')}). Open '
        'AnJ Cloud, let it finish syncing (and Finish editing any file open '
        'for editing), quit it, then run move-root again.';
  }

  /// Moves the staging folder by rename to its journaled place, then points
  /// `staging` and every recorded path inside it there in one transaction.
  /// Idempotent: a step already made is recognised and skipped.
  void _moveStaging(_Journal journal) {
    final from = journal.stagingFrom;
    final to = journal.stagingTo;
    if (from == null || to == null || p.equals(from, to)) return;
    if (p.equals(manifest.setting('staging') ?? '', to)) return;
    final fromType = FileSystemEntity.typeSync(from, followLinks: false);
    final toType = FileSystemEntity.typeSync(to, followLinks: false);
    if (fromType == FileSystemEntityType.directory && _holdsEntries(to)) {
      // The rename was made and the old place was made again since (a
      // start that used the old setting). An empty one is removed and the
      // switch finishes; one holding files keeps the move recorded.
      if (!_removeEmpty(from)) {
        throw RootMoveRefused(
          'The staging folder was moved to $to, but $from holds files again. '
          'The interrupted move stays recorded and AnJ Cloud does not sync '
          'until it is finished: move the files from $from into $to, then '
          'run move-root again.',
          journalKept: true,
        );
      }
    } else if (fromType == FileSystemEntityType.directory) {
      if ((toType == FileSystemEntityType.directory && !_removeEmpty(to)) ||
          (toType != FileSystemEntityType.directory &&
              toType != FileSystemEntityType.notFound)) {
        _stagingFailed(journal, '$to is already in use');
      }
      try {
        _rename(from, to);
      } on FileSystemException catch (error) {
        _stagingFailed(journal, _reason(error));
      }
      step?.call('stagingMoved');
    } else if (toType != FileSystemEntityType.directory) {
      // Neither exists: the staging folder was removed; start it empty.
      Directory(to).createSync();
    }
    native.privateDir(to);
    String? convert(String? value) {
      if (value == null) return null;
      if (p.equals(value, from)) return to;
      return p.isWithin(from, value)
          ? p.join(to, p.relative(value, from: from))
          : null;
    }

    var changed = false;
    Object? walk(Object? value) {
      if (value is String) {
        final next = convert(value);
        if (next == null) return value;
        changed = true;
        return next;
      }
      if (value is Map) {
        return {for (final e in value.entries) e.key: walk(e.value)};
      }
      if (value is List) return [for (final v in value) walk(v)];
      return value;
    }

    for (final op in manifest.operations.values) {
      final staged = convert(op.staged);
      if (staged != null) op.staged = staged;
      changed = false;
      final data = walk(op.data) as Map;
      if (changed) op.data = Map<String, dynamic>.from(data);
    }
    for (final entry in manifest.entries.values) {
      final remote = convert(entry.remoteCopy);
      if (remote != null) entry.remoteCopy = remote;
      final working = convert(entry.workingCopy);
      if (working != null) entry.workingCopy = working;
      if (entry.preservedCopies.any((c) => convert(c) != null)) {
        entry.preservedCopies = [
          for (final c in entry.preservedCopies) convert(c) ?? c,
        ];
      }
    }
    // One transaction: the setting and every path inside it.
    manifest.save(settings: {'staging': to});
    step?.call('stagingSwitched');
  }

  /// Whether the staging move of [journal] began and is not switched yet:
  /// the old folder is gone, or the new one holds what was moved.
  bool _stagingMoveBegan(_Journal journal) {
    final from = journal.stagingFrom;
    final to = journal.stagingTo;
    if (from == null || to == null || p.equals(from, to)) return false;
    if (p.equals(manifest.setting('staging') ?? '', to)) return false;
    return FileSystemEntity.typeSync(from, followLinks: false) !=
            FileSystemEntityType.directory ||
        _holdsEntries(to);
  }

  static bool _holdsEntries(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    try {
      return Directory(path).listSync(followLinks: false).isNotEmpty;
    } on FileSystemException {
      return true;
    }
  }

  /// A failed staging move. The journal is dropped only when provably
  /// nothing moved: the synced folder and the staging folder are both where
  /// the profile records them and the new staging place is empty or absent.
  Never _stagingFailed(_Journal journal, String reason) {
    final stagingFrom = journal.stagingFrom!;
    if (_locate(journal) == _Where.from &&
        p.equals(manifest.setting('staging') ?? '', stagingFrom) &&
        FileSystemEntity.typeSync(stagingFrom, followLinks: false) ==
            FileSystemEntityType.directory &&
        !_holdsEntries(journal.stagingTo!)) {
      _abandon();
      throw RootMoveRefused(
        'The staging folder ${journal.stagingFrom} could not be moved to '
        '${journal.stagingTo} ($reason). Nothing was changed.',
      );
    }
    throw RootMoveRefused(
      'The staging folder ${journal.stagingFrom} could not be moved to '
      '${journal.stagingTo} ($reason). The interrupted move stays recorded; '
      'run move-root again to finish it.',
      journalKept: true,
    );
  }

  /// Renames toward the target from wherever the folder is now.
  Future<Map<String, Object?>> _forward(_Journal journal) async {
    _moveStaging(journal);
    var where = _locate(journal);
    if (where == _Where.from) {
      final via = journal.via;
      if (via != null) {
        _renameOrAbandon(journal.from, via);
        step?.call('renamedAside');
        where = _Where.via;
      } else {
        _renameOrAbandon(journal.from, journal.to);
        step?.call('renamed');
        where = _Where.to;
      }
    }
    if (where == _Where.via) {
      final via = journal.via!;
      final type = FileSystemEntity.typeSync(journal.to, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        try {
          Directory(journal.to).deleteSync();
        } on FileSystemException {
          // Something appeared in the parent since it was checked: put the
          // folder back where it was and change nothing else.
          final entries = [
            for (final e in Directory(journal.to).listSync(followLinks: false))
              e.path,
          ]..sort();
          _putBack(via, journal.from);
          throw RootMoveRefused(
            '${journal.to} gained entries during the move, so the folder was '
            'put back at ${journal.from}: ${entries.join(', ')}',
            entries: entries,
          );
        }
        step?.call('parentRemoved');
      } else if (type != FileSystemEntityType.notFound) {
        throw RootMoveRefused(
          'The synced folder is at $via (a move was interrupted), and '
          '${journal.to} is now a file or link. Remove it and run move-root '
          'again to finish.',
          journalKept: true,
        );
      }
      try {
        _rename(via, journal.to);
      } on FileSystemException catch (error) {
        throw RootMoveRefused(
          'The synced folder is at $via (a move was interrupted) and could '
          'not be renamed to ${journal.to} (${_reason(error)}). Run move-root '
          'again to finish.',
          journalKept: true,
        );
      }
      step?.call('renamed');
      where = _Where.to;
    }
    if (where == _Where.to) return await _commit(journal);
    throw RootMoveRefused(
      'The synced folder of this profile is not at ${journal.from}'
      '${journal.via == null ? '' : ', ${journal.via}'} or ${journal.to}. '
      'The interrupted move stays recorded in the profile; restore the '
      'folder to one of those paths and run move-root again.',
      journalKept: true,
    );
  }

  /// The folder is at the target: switch `root` (staging already moved).
  Future<Map<String, Object?>> _commit(_Journal journal) async {
    manifest.transaction(() {
      manifest.setSetting('root', journal.to);
      manifest.setSetting(
        rootMoveSetting,
        _Journal(
          from: journal.from,
          to: journal.to,
          via: journal.via,
          phase: _cleanup,
          stagingFrom: journal.stagingFrom,
          stagingTo: journal.stagingTo,
        ).encode(),
      );
    });
    step?.call('committed');
    return await _cleanUp(journal);
  }

  /// After the switch: the emptied old parent goes (rmdir only), the
  /// desktop shortcut is made or pointed at the new folder, then the journal
  /// is removed. Every step may run again.
  Future<Map<String, Object?>> _cleanUp(_Journal journal) async {
    final removed = <String>[];
    final parent = p.dirname(journal.from);
    if (!keep.contains(p.normalize(parent)) &&
        !p.equals(parent, journal.to) &&
        !p.isWithin(parent, journal.to) &&
        FileSystemEntity.typeSync(parent, followLinks: false) ==
            FileSystemEntityType.directory &&
        _removeEmpty(parent)) {
      removed.add(parent);
    }
    step?.call('parentCleaned');
    // A link this profile made to the old place follows the folder (or is
    // reported stale); without one recorded, the P2 link is made once.
    var shortcut = await retargetDesktopShortcut(
      manifest,
      journal.from,
      journal.to,
    );
    if (manifest.setting('desktopShortcut') == null) {
      shortcut = await makeDesktopShortcut(journal.to, desktop);
      saveDesktopShortcutOutcome(manifest, shortcut);
    }
    manifest.deleteSetting(rootMoveSetting);
    step?.call('done');
    return {
      'moved': true,
      'from': journal.from,
      'to': journal.to,
      'staging': manifest.setting('staging'),
      if (journal.stagingTo != null &&
          !p.equals(journal.stagingFrom!, journal.stagingTo!))
        'stagingFrom': journal.stagingFrom,
      'removed': removed,
      // What this run did to the link; `unchanged:` when it left an earlier
      // outcome alone (a link the user changed or removed is not touched).
      'desktopShortcut':
          shortcut ?? 'unchanged:${manifest.setting('desktopShortcut')}',
    };
  }

  String _canonicalTarget(String target) {
    if (!p.isAbsolute(target)) {
      throw RootMoveRefused('The target must be an absolute path: $target');
    }
    final normalized = p.normalize(target);
    if (p.basename(normalized) != syncedFolderName) {
      throw RootMoveRefused(
        'The target must be a folder named $syncedFolderName (for example '
        '\$HOME/$syncedFolderName), not $normalized.',
      );
    }
    final parent = p.dirname(normalized);
    if (FileSystemEntity.typeSync(parent) != FileSystemEntityType.directory) {
      throw RootMoveRefused('$parent is not an existing folder.');
    }
    return p.join(
      Directory(parent).resolveSymbolicLinksSync(),
      syncedFolderName,
    );
  }

  _Where? _locate(_Journal journal) {
    for (final (where, path) in [
      (_Where.from, journal.from),
      if (journal.via != null) (_Where.via, journal.via!),
      (_Where.to, journal.to),
    ]) {
      if (_isRoot(path)) return where;
    }
    return null;
  }

  /// [path] is a directory (no link) accepted by the stored identity.
  bool _isRoot(String path) {
    final stored = manifest.setting('rootIdentity');
    if (stored == null ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return false;
    }
    try {
      return sameRootIdentity(stored, _rootInfo(path).identity);
    } on FileSystemException {
      return false;
    }
  }

  RootInfo _rootInfo(String path) {
    final fd = native.openRoot(path);
    try {
      return native.rootInfo(fd);
    } finally {
      native.closeFd(fd);
    }
  }

  String _volume(String path) {
    final fd = native.openRoot(path);
    try {
      return native.identity(fd).split(':').first;
    } finally {
      native.closeFd(fd);
    }
  }

  /// rename(2) with RENAME_NOREPLACE through the closest common folder, only
  /// while [from] is still the same folder; never replaces [to].
  void _rename(String from, String to) {
    final a = p.split(p.dirname(from));
    final b = p.split(p.dirname(to));
    var n = 0;
    while (n < a.length && n < b.length && a[n] == b[n]) {
      n++;
    }
    final anchor = p.joinAll(a.take(n));
    final source = native.openRoot(from);
    final String identity;
    try {
      identity = native.identity(source);
    } finally {
      native.closeFd(source);
    }
    final fd = native.openRoot(anchor);
    try {
      native.renameExclusive(
        fd,
        p.relative(from, from: anchor),
        p.relative(to, from: anchor),
        identity,
      );
    } finally {
      native.closeFd(fd);
    }
  }

  /// The first rename: on failure nothing has moved, so the journal goes.
  void _renameOrAbandon(String from, String to) {
    try {
      _rename(from, to);
    } on FileSystemException catch (error) {
      _abandon();
      if (error.osError?.errorCode == _exdev) {
        throw RootMoveRefused(
          '$to is not on the same filesystem (or btrfs subvolume) as $from. '
          'move-root only renames the folder and never copies it.',
        );
      }
      throw RootMoveRefused(
        '$from could not be renamed to $to (${_reason(error)}). Nothing was '
        'changed.',
      );
    }
  }

  void _putBack(String via, String from) {
    try {
      _rename(via, from);
    } on FileSystemException catch (error) {
      throw RootMoveRefused(
        'The synced folder is at $via (a move was interrupted) and could not '
        'be put back at $from (${_reason(error)}). Run move-root again to '
        'finish.',
        journalKept: true,
      );
    }
    _abandon();
  }

  void _abandon() => manifest.deleteSetting(rootMoveSetting);

  static String _reason(FileSystemException error) {
    final os = error.osError;
    return os == null
        ? error.message
        : '${error.message}: errno ${os.errorCode}';
  }

  /// EXDEV ("Invalid cross-device link").
  static const _exdev = 18;
}

/// rmdir only: true when [path] is gone (removed now or already absent).
bool _removeEmpty(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return true;
  if (type != FileSystemEntityType.directory) return false;
  try {
    Directory(path).deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

enum _Where { from, via, to }

const _move = 'move';
const _cleanup = 'cleanup';

class _Journal {
  const _Journal({
    required this.from,
    required this.to,
    required this.via,
    required this.phase,
    this.stagingFrom,
    this.stagingTo,
  });

  factory _Journal.decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    return _Journal(
      from: json['from'] as String,
      to: json['to'] as String,
      via: json['via'] as String?,
      phase: json['phase'] as String,
      stagingFrom: json['stagingFrom'] as String?,
      stagingTo: json['stagingTo'] as String?,
    );
  }

  final String from;
  final String to;

  /// The temporary name beside the target (the nested case only).
  final String? via;
  final String phase;

  /// The staging folder before the move, and where it goes (null: it stays,
  /// already inside the profile).
  final String? stagingFrom;
  final String? stagingTo;

  String encode() => jsonEncode({
    'from': from,
    'to': to,
    'via': via,
    'phase': phase,
    'stagingFrom': stagingFrom,
    'stagingTo': stagingTo,
  });
}
