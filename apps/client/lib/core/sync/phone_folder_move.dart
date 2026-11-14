import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../local/root_tree.dart' show uniqueId;
import '../ports/phone_folders.dart';
import '../ports/release_guard.dart';
import '../ports/root_filesystem.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'name_policy.dart';
import 'name_rule.dart';

/// The status line, once, after the move (spec #52 step 5).
const phoneFoldersMovedNotice =
    "Music, Videos and Documents are now in your phone's folders.";

/// Manifest setting: `moving` while the move runs, `done` after it.
const phoneFolderMoveKey = 'phoneFolderMoveV1';

/// Manifest setting: the [phoneFoldersMovedNotice] is still owed.
const phoneFolderNoticeKey = 'phoneFolderMoveNoticeV1';

/// Manifest setting: the move's journal, JSON `{private path: {"to": engine
/// path on the phone, "conflict": engine path of a kept copy, "hash"}}`.
/// Written before the disk changes it describes; removed when the move ends.
const phoneFolderPlanKey = 'phoneFolderMovePlanV1';

/// The one-time move of an existing install's app-private Music, Videos and
/// Documents into the phone's own folders (spec #52 Moving an Existing
/// Install). It runs in the sync worker before anything syncs those folders:
/// at start, or when All files access arrives while the app runs; never
/// without access. While it is unfinished the folders stay paused.
///
/// First every private item gets its place on the phone, once, in the
/// journal ([phoneFolderPlanKey]): the engine's own phone name rule (spec #49
/// R3 step 1 and the case clash, decision #202) over the synchronized
/// siblings, so `Where Is My Mind?.mp3` lands as `Where Is My Mind？.mp3`; an
/// unsynchronized item takes its lookalike name and a ` (n)` when it would
/// meet another; a name that only differs in case from something already in
/// the phone folder gets a ` (n)` too. Rows and operations follow their items
/// to the new names and keep the cloud name, so nothing reads as a deletion.
///
/// Then each private file is copied through shared staging (the phone
/// folders' volume), verified by hash and renamed into place without
/// replacing anything; only then is its row moved and the private copy
/// removed. Nothing is downloaded. A file the phone already has at that
/// place decides by the existing-contents table: the same bytes link;
/// different bytes are both kept, the phone's file is never overwritten, and
/// the copy's name is journaled before it is written, so a crash or kill
/// adopts that copy (by hash) instead of making another. Every step can be
/// repeated: running again resumes. Working copies and other staged bytes
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

  /// Absolute phone paths this move placed: the caller asks the media
  /// library to scan them (spec #52 Media library).
  final List<String> placed = [];

  /// Test seam: called after each step that changes the disk, with a name
  /// (`installed`, `conflict-installed`, `recorded`, `removed`).
  void Function(String step, String path)? debugStep;

  /// Whether private Music, Videos or Documents are still there to move.
  bool get pending => _tops().isNotEmpty;

  List<String> _tops() => [
    if (Directory(privateRoot).existsSync())
      for (final top in phoneFolderNames.keys)
        if (FileSystemEntity.typeSync(
              '$privateRoot/$top',
              followLinks: false,
            ) ==
            FileSystemEntityType.directory)
          top,
  ];

  /// Moves whatever is left of the private top folders; returns the number
  /// of files moved or linked. Throws when something could not be moved: the
  /// private copies then stay, and the caller keeps the folders paused.
  int run() {
    final tops = _tops();
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
      final plan = _plan(tops, items, baseFd);
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
        final to = plan[item['path']]?['to'] as String?;
        if (to != null) native.makeDir(baseFd, _phone(to));
      }
      var unplaced = 0;
      for (final item in files) {
        final path = item['path'] as String;
        final journal = plan[path];
        if (journal == null || journal['to'] == null) {
          unplaced++;
          continue;
        }
        onProgress?.call(
          'Moving Music, Videos and Documents to your phone\'s folders '
          '(${moved + 1} of ${files.length})…',
        );
        _moveFile(path, journal, plan, privateFd, baseFd, stageFd, guard);
        moved++;
      }
      // Folder rows follow their folders (deepest last, so a parent's row
      // never lands on a child's path).
      for (final item in items.where((i) => i['kind'] == 'directory')) {
        final path = item['path'] as String;
        final to = plan[path]?['to'] as String?;
        if (to != null) _rekey(path, to);
      }
      manifest.save();
      // The private top folders go, deepest first; anything left (a file no
      // name fits) keeps its folder, and the move is not done.
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
      if (unplaced > 0) {
        throw FileSystemException(
          '$unplaced file${unplaced == 1 ? '' : 's'} with a name too long for '
          'the phone stay in app storage',
        );
      }
    } finally {
      for (final fd in [privateFd, baseFd, stageFd]) {
        native.closeFd(fd);
      }
    }
    if (_tops().isEmpty) {
      manifest.setSetting(phoneFolderMoveKey, 'done');
      manifest.save(settings: {phoneFolderPlanKey: '{}'});
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

  Map<String, Map<String, dynamic>> _journal() {
    try {
      final value = jsonDecode(manifest.setting(phoneFolderPlanKey) ?? '{}');
      return {
        for (final MapEntry(:key, :value) in (value as Map).entries)
          key as String: Map<String, dynamic>.from(value as Map),
      };
    } on Object {
      return {};
    }
  }

  void _saveJournal(Map<String, Map<String, dynamic>> plan) =>
      manifest.setSetting(phoneFolderPlanKey, jsonEncode(plan));

  /// Every private item's place on the phone (see the class comment); kept
  /// from an earlier run, completed for items it did not know. Journaled
  /// before anything is copied.
  Map<String, Map<String, dynamic>> _plan(
    List<String> tops,
    List<Map<String, dynamic>> items,
    int baseFd,
  ) {
    final plan = _journal();
    final byParent = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      byParent
          .putIfAbsent(p.posix.dirname(item['path'] as String), () => [])
          .add(item);
    }
    final destination = <String, String>{for (final top in tops) top: top};
    var changed = false;
    // Parents before children: sorted paths list a folder before its items.
    final parents = [...tops, ...items.map((i) => i['path'] as String)];
    for (final parent in parents) {
      final children = byParent[parent];
      final to = destination[parent];
      if (children == null || to == null) continue;
      final known = <String, String>{};
      for (final child in children) {
        final path = child['path'] as String;
        final dest = plan[path]?['to'] as String?;
        if (dest != null) known[path] = dest;
      }
      final placed = _placeChildren(children, known, to, baseFd);
      for (final MapEntry(key: path, value: dest) in placed.entries) {
        if (dest != null) destination[path] = dest;
        if (!plan.containsKey(path)) {
          plan[path] = {'to': dest};
          changed = true;
        }
      }
    }
    if (changed) _saveJournal(plan);
    return plan;
  }

  /// Names for one folder's private [children] in the phone folder [to]
  /// (an engine path); [known] are the places an earlier run journaled.
  /// Null where no name fits.
  Map<String, String?> _placeChildren(
    List<Map<String, dynamic>> children,
    Map<String, String> known,
    String to,
    int baseFd,
  ) {
    String cloudName(String path) =>
        manifest.entries[path]?.cloudName ?? p.posix.basename(path);
    bool isFolder(Map<String, dynamic> c) => c['kind'] == 'directory';
    // What the phone folder already holds, by fold key (case, accents).
    final onPhone = <String, Set<String>>{};
    final folder = Directory('${layout.base}/${_phone(to)}');
    if (folder.existsSync()) {
      for (final item in folder.listSync(followLinks: false)) {
        final name = p.basename(item.path);
        onPhone.putIfAbsent(NamePolicy.foldKey(name), () => {}).add(name);
      }
    }
    final taken = <String>{
      for (final dest in known.values)
        NamePolicy.foldKey(p.posix.basename(dest)),
    };
    final result = <String, String?>{
      for (final MapEntry(:key, :value) in known.entries) key: value,
    };
    // A name that meets a phone item only by case or accents is another
    // item: never linked to it, never written over it.
    String? avoidPhone(String name, bool folder) {
      final same = onPhone[NamePolicy.foldKey(name)];
      if (same == null || same.contains(name)) return name;
      return NameRule.suffixed(name, [
        ...taken,
        for (final names in onPhone.values) ...names,
      ], folder: folder);
    }

    // Synchronized items: exactly the names the engine gives them.
    final synced = [
      for (final c in children)
        if (!known.containsKey(c['path']) &&
            manifest.entries[c['path']]?.etag != null)
          c,
    ];
    final names = NameRule.localNames([
      for (final c in synced)
        NameEntry(
          cloudName(c['path'] as String),
          fileId: manifest.entries[c['path']]!.fileId,
          folder: isFolder(c),
        ),
    ], NameOs.phone);
    for (final c in synced) {
      var name = names[cloudName(c['path'] as String)];
      if (name != null) name = avoidPhone(name, isFolder(c));
      if (name != null) taken.add(NamePolicy.foldKey(name));
      result[c['path'] as String] = name == null ? null : '$to/$name';
    }
    // Never synchronized: the lookalike name, made unique.
    for (final c in children) {
      final path = c['path'] as String;
      if (result.containsKey(path)) continue;
      final own = cloudName(path);
      String? name = NameRule.localNames([
        NameEntry(own, folder: isFolder(c)),
      ], NameOs.phone)[own];
      if (name != null && taken.contains(NamePolicy.foldKey(name))) {
        name = NameRule.suffixed(name, [
          for (final r in result.values)
            if (r != null) p.posix.basename(r),
        ], folder: isFolder(c));
      }
      if (name != null) name = avoidPhone(name, isFolder(c));
      if (name != null) taken.add(NamePolicy.foldKey(name));
      result[path] = name == null ? null : '$to/$name';
    }
    return result;
  }

  void _moveFile(
    String path,
    Map<String, dynamic> journal,
    Map<String, Map<String, dynamic>> plan,
    int privateFd,
    int baseFd,
    int stageFd,
    ReleaseGuard guard,
  ) {
    final to = journal['to'] as String;
    final phone = _phone(to);
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
        _alreadyThere(
          path,
          phone,
          hash,
          journal,
          plan,
          baseFd,
          stageFd,
          guard,
          temp,
        );
      }
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
    }
    placed.add('${layout.base}/$phone');
    // The phone copy is verified: its row follows it, then the private copy
    // goes.
    _rekey(path, to);
    manifest.save();
    debugStep?.call('recorded', path);
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
    Map<String, dynamic> journal,
    Map<String, Map<String, dynamic>> plan,
    int baseFd,
    int stageFd,
    ReleaseGuard guard,
    String temp,
  ) {
    final there = _hashOf(baseFd, phone);
    if (there == hash) return;
    final entry = manifest.entries[path];
    final synced = entry != null && entry.etag != null;
    if (!synced || entry.baselineHash != hash) {
      // Bytes the cloud does not have (never synchronized, or an unsynced
      // edit): kept beside the phone's file under a conflict-copy name, and
      // uploaded from there. The name is journaled first; a copy an earlier
      // run already wrote under it (same bytes) is adopted, never repeated.
      final recorded = journal['conflict'] as String?;
      if (recorded != null &&
          journal['hash'] == hash &&
          _hashOf(baseFd, recorded) == hash) {
        debugStep?.call('conflict-adopted', path);
      } else {
        for (var attempt = 0; ; attempt++) {
          final copy = recorded != null && attempt == 0
              ? recorded
              : '$phone.conflict-${uniqueId().substring(0, 8)}';
          journal
            ..['conflict'] = copy
            ..['hash'] = hash;
          _saveJournal(plan);
          try {
            guard.restore(baseFd, copy, stageFd, temp);
            placed.add('${layout.base}/$copy');
            debugStep?.call('conflict-installed', path);
            break;
          } on FileSystemException catch (error) {
            if (!_exists(error) || attempt > 8) rethrow;
            // Taken: by this same copy (adopt it) or by something else.
            if (_hashOf(baseFd, copy) == hash) break;
          }
        }
      }
    }
    if (synced) {
      // The phone's different file meets the cloud's version: the existing
      // conflict rule decides on the next pass (both versions kept).
      entry.refreshRemote = true;
      manifest.save();
    }
  }

  String? _hashOf(int fd, String path) {
    try {
      return native.copyAndHash(fd, path, null, purpose: 'phone-move');
    } on FileSystemException {
      return null;
    }
  }

  /// The row of private [from] (and the operations about it) now at the
  /// phone path [to]; a new name keeps the cloud name it stands for.
  void _rekey(String from, String to) {
    if (from == to) return;
    final old = manifest.entries[from];
    if (old != null && !manifest.entries.containsKey(to)) {
      final moved = Entry.fromJson({...old.toJson(), 'path': to});
      if (p.posix.basename(from) != p.posix.basename(to)) {
        moved.cloudName = old.cloudName ?? p.posix.basename(from);
      }
      manifest.entries.remove(from);
      manifest.entries[to] = moved;
    }
    for (final op in manifest.operations.values.toList()) {
      final data = Map<String, dynamic>.from(op.data);
      if (op.path != from && data['installing'] != from) continue;
      if (data['installing'] == from) data['installing'] = to;
      final json = {...op.toJson(), 'path': op.path == from ? to : op.path};
      manifest.operations[op.id] = Operation.fromJson(json)..data = data;
    }
  }

  static bool _exists(FileSystemException error) =>
      error.osError?.errorCode == 17;
}
