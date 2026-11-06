import 'package:path/path.dart' as p;

import '../local/root_tree.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'sync_path_policy.dart';
import 'top_folders.dart';

/// The first-sync screen's data (decision #163, superseding #150's
/// first-sync clause; #118): at a device's first pairing, before anything
/// downloads, what the account holds with sizes, and the user's choice of
/// what to keep on this device. Documents, Music and Videos themselves always
/// exist on every device; the choice is about what is inside them: each
/// subfolder, and their loose files as one row. Other top-level folders are
/// rows of their own. One shared model and screen for every client; the
/// default is the platform's ([FirstSyncDefault]).
enum FirstSyncDefault {
  /// Android (#163): nothing is kept on the device until the user ticks it.
  cloud,

  /// Desktop clients (#163): everything is kept until the user unticks it.
  local,
}

/// One row of the screen. [path] is what the choice is written to: a
/// subfolder of a top folder (`Music/Albums`), a top folder itself for its
/// new and loose files (`Music`, [looseFiles]: its files directly inside and
/// every folder added there later), or another top-level folder (`Photos`).
/// Every top folder always has its row, present on the server or not, so its
/// choice is always explicit (review H1).
class FirstSyncChoice {
  const FirstSyncChoice({
    required this.path,
    required this.size,
    this.top,
    this.files,
  });

  final String path;

  /// Total bytes the server reports; null when it reported none.
  final int? size;

  /// The top folder this row belongs to, or null for another top-level
  /// folder.
  final String? top;

  /// The number of loose files, for the "New and loose files in" row.
  final int? files;

  bool get looseFiles => top != null && path == top;

  /// The row's name on screen.
  String get label =>
      looseFiles ? 'New and loose files in $top' : path.split('/').last;
}

class FirstSyncListing {
  const FirstSyncListing({
    required this.choices,
    required this.tops,
    required this.rootFiles,
    required this.rootFilesSize,
  });

  /// Builds the listing from the root's children ([root], with the sizes the
  /// server reported in [rootSizes]) and each top folder's children
  /// ([inside], keyed by top folder). Excluded names (#21) never sync and are
  /// left out.
  factory FirstSyncListing.fromListings(
    Iterable<RemoteItem> root,
    Map<String, int> rootSizes,
    Map<String, ({List<RemoteItem> items, Map<String, int> sizes})> inside,
  ) {
    final choices = <FirstSyncChoice>[];
    final tops = <String>[];
    final others = <FirstSyncChoice>[];
    var files = 0;
    var filesSize = 0;
    for (final item in root) {
      if (item.path.contains('/') || isSyncExcluded(item.path)) continue;
      if (item.kind != ItemKind.directory) {
        files++;
        filesSize += rootSizes[item.path] ?? item.size;
      } else if (!isTopFolder(item.path)) {
        others.add(
          FirstSyncChoice(path: item.path, size: rootSizes[item.path]),
        );
      }
    }
    int byName(FirstSyncChoice a, FirstSyncChoice b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase());
    for (final top in const ['Documents', 'Music', 'Videos']) {
      // Listed whether or not the server has it yet: it always exists here.
      final level =
          inside[top] ??
          (items: const <RemoteItem>[], sizes: const <String, int>{});
      tops.add(top);
      final folders = <FirstSyncChoice>[];
      var loose = 0;
      var looseSize = 0;
      for (final item in level.items) {
        if (p.posix.dirname(item.path) != top || isSyncExcluded(item.path)) {
          continue;
        }
        if (item.kind == ItemKind.directory) {
          folders.add(
            FirstSyncChoice(
              path: item.path,
              size: level.sizes[item.path],
              top: top,
            ),
          );
        } else {
          loose++;
          looseSize += level.sizes[item.path] ?? item.size;
        }
      }
      folders.sort(byName);
      choices.addAll(folders);
      choices.add(
        FirstSyncChoice(path: top, size: looseSize, top: top, files: loose),
      );
    }
    others.sort(byName);
    choices.addAll(others);
    return FirstSyncListing(
      choices: choices,
      tops: tops,
      rootFiles: files,
      rootFilesSize: filesSize,
    );
  }

  final List<FirstSyncChoice> choices;

  /// Documents, Music and Videos: always on the device, each with its row.
  final List<String> tops;

  /// Files directly at the root: they follow #29 (the root is Local), so
  /// they download whatever the choice.
  final int rootFiles;
  final int rootFilesSize;

  List<String> get paths => [for (final choice in choices) choice.path];

  /// The platform's starting selection: everything (desktop) or nothing
  /// (Android).
  Set<String> defaultKeep(FirstSyncDefault choice) =>
      choice == FirstSyncDefault.local ? paths.toSet() : <String>{};

  /// Whether every row reported a size, so [total] is exact.
  bool get sizesComplete => choices.every((choice) => choice.size != null);

  /// Everything listed, in bytes (rows without a size count as zero).
  int get total =>
      rootFilesSize +
      choices.fold<int>(0, (sum, choice) => sum + (choice.size ?? 0));

  /// Bytes that download if [keepLocal] are kept on this device.
  int downloadSize(Set<String> keepLocal) =>
      rootFilesSize +
      choices
          .where((choice) => keepLocal.contains(choice.path))
          .fold<int>(0, (sum, choice) => sum + (choice.size ?? 0));
}

/// Settings key for the first-sync gate: `pending` from a first pairing's
/// approval until the user confirms the screen, then `done`. While it is
/// `pending` no sync worker starts, so nothing downloads.
const firstSyncSetting = 'firstSync';

/// Records the user's choice as folder storage rows, the same rows a storage
/// choice in the library writes (directory-only policy, #29), and ends the
/// gate in the same transaction: each path in [paths] is Local when in
/// [keepLocal], Cloud otherwise. A path is a direct subfolder of Documents,
/// Music or Videos, one of those three (its loose files and the subfolders
/// added later; the folder itself always stays on the device, decision
/// #163), or another top-level folder. Root files follow #29.
void applyFirstSyncChoice(
  Manifest manifest,
  Iterable<String> paths,
  Set<String> keepLocal,
) {
  for (final path in paths) {
    validateRelative(path);
    final parts = path.split('/');
    final allowed =
        !isSyncExcluded(path) &&
        (parts.length == 1 || (parts.length == 2 && isTopFolder(parts.first)));
    if (!allowed) throw FormatException('Not a first-sync choice: $path');
    final entry = manifest.entries.putIfAbsent(
      path,
      () => Entry(path, ItemKind.directory),
    );
    if (entry.kind != ItemKind.directory) {
      throw FormatException('Not a folder: $path');
    }
    entry.override = keepLocal.contains(path)
        ? Retention.local
        : Retention.cloud;
  }
  manifest.save(settings: {firstSyncSetting: 'done'});
}
