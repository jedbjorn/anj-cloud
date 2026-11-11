import 'package:path/path.dart' as p;

import '../state/model.dart';
import 'name_policy.dart';

/// Which server items this device cannot create under their names, for one
/// pass. Such an item stays Cloud-only with
/// the reason as its row status ([serverNameNotAllowedStatus],
/// [serverNameClashStatus], [serverFolderNameStatus]) and is never created
/// here, so a case-blind filesystem never writes it inside the sibling it
/// folds onto.
///
/// Two separate capabilities gate the rules:
/// - [win32Names]: names Windows cannot hold (`CON`, a trailing dot or
///   space, ...), and everything inside such a folder. Windows only.
/// - [foldsCase]: the root's volume treats names that differ only by case or
///   normalization as one ([RootFilesystem.caseInsensitive]: Windows, and
///   macOS on its default volumes). Of such siblings, local or server, one is
///   kept and the others, and everything inside them, stay Cloud-only.
///
/// The kept sibling is, in order: the one on disk now; otherwise the one
/// whose manifest entry is not already held for its name (so a Cloud/Local
/// cycle that empties the disk never flips the winner); otherwise the
/// byte-wise first name. Siblings are grouped once per folder per pass.
class NameHolds {
  NameHolds({
    required this.win32Names,
    required this.foldsCase,
    required this.remote,
    required this.local,
    required this.entries,
  });

  final bool win32Names;
  final bool foldsCase;
  final Iterable<String> remote;
  final Map<String, LocalItem> local;
  final Map<String, Entry> entries;

  bool get active => win32Names || foldsCase;

  /// Fold keys computed by every index (test seam): one per name grouped
  /// plus one per lookup, so a pass stays linear in the folder size.
  static int debugFoldKeys = 0;

  Map<String, Set<String>>? _names;
  final _groups = <String, Map<String, List<String>>>{};

  /// The hold status of [path], absent from this device, or null when it
  /// can be created here. [moving] is where the same item is on this device
  /// now, when the question is whether it can be renamed to [path] (a move
  /// made in the cloud): the item is not its own sibling.
  String? status(String path, {String? moving}) {
    if (!active) return null;
    final parts = path.split('/');
    if (win32Names) {
      if (_win32Refuses(parts.last)) return serverNameNotAllowedStatus;
      for (var i = 0; i < parts.length - 1; i++) {
        if (_win32Refuses(parts[i])) return serverFolderNameStatus;
      }
    }
    if (foldsCase) {
      var prefix = '';
      for (var i = 0; i < parts.length; i++) {
        prefix = i == 0 ? parts[0] : '$prefix/${parts[i]}';
        if (_loses(prefix, moving)) {
          return i == parts.length - 1
              ? serverNameClashStatus
              : serverFolderNameStatus;
        }
      }
    }
    return null;
  }

  /// The portable rules plus NTFS's component limit of 255 UTF-16 units
  /// (`componentTooLong`). Uploads keep the portable
  /// rules alone.
  static bool _win32Refuses(String name) =>
      NamePolicy.check(name) != null || name.length > win32ComponentUnits;

  static const win32ComponentUnits = 255;

  bool _loses(String path, [String? moving]) {
    if (local.containsKey(path)) return false;
    final folder = p.posix.dirname(path);
    final name = p.posix.basename(path);
    String child(String n) => folder == '.' ? n : '$folder/$n';
    var members = _group(folder, name);
    if (moving != null && members.any((n) => child(n) == moving)) {
      members = [
        for (final n in members)
          if (child(n) != moving) n,
      ];
    }
    if (members.length < 2) return false;
    if (members.any((n) => n != name && local.containsKey(child(n)))) {
      return true;
    }
    bool held(String n) => isServerNameHold(entries[child(n)]?.status ?? '');
    var candidates = [
      for (final n in members)
        if (!held(n)) n,
    ];
    if (candidates.isEmpty) candidates = members;
    if (!candidates.contains(name)) return true;
    var first = candidates.first;
    for (final n in candidates.skip(1)) {
      if (compareUnits(n, first) < 0) first = n;
    }
    return first != name;
  }

  /// Names in [folder] that fold onto [name], local and server, with [name].
  List<String> _group(String folder, String name) {
    final names = _names ??= () {
      final index = <String, Set<String>>{};
      for (final path in [...remote, ...local.keys]) {
        index
            .putIfAbsent(p.posix.dirname(path), () => {})
            .add(p.posix.basename(path));
      }
      return index;
    }();
    final groups = _groups.putIfAbsent(folder, () {
      final byKey = <String, List<String>>{};
      for (final n in names[folder] ?? const <String>{}) {
        debugFoldKeys++;
        byKey.putIfAbsent(NamePolicy.foldKey(n), () => []).add(n);
      }
      return byKey;
    });
    debugFoldKeys++;
    final members = groups[NamePolicy.foldKey(name)] ?? const <String>[];
    return members.contains(name) ? members : [...members, name];
  }

  /// UTF-16 code-unit order: the same on every device and every pass.
  static int compareUnits(String a, String b) {
    final x = a.codeUnits, y = b.codeUnits;
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return x.length - y.length;
  }
}
