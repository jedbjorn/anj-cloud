import 'dart:convert';

import 'name_policy.dart';

/// The operating systems the name rule distinguishes (spec #49 R3).
enum NameOs { windows, macos, linux, android }

/// Why the cloud cannot or must not hold a name (spec #49 R2).
enum CloudNameProblem {
  empty,
  untrimmed,
  forbiddenCharacter,
  forbiddenName,
  forbiddenExtension,
  tooLong,
}

/// One cloud item of a folder: its cloud name, Nextcloud `oc:fileid` and
/// kind. Folders have no extension.
class NameEntry {
  const NameEntry(this.name, {this.fileId, this.folder = false});
  final String name;
  final int? fileId;
  final bool folder;
}

/// The name rule (spec #49, decision #193): names just work on every device.
///
/// The gateway's services/access/name_rule.py is the same rule; both run the
/// `rule` section of tests/name_policy_vectors.json, so they cannot drift.
/// It applies to one path segment. "Extension" is the text after the last
/// `.` when it and the stem before it are non-empty; folders have none. The
/// rule never edits an extension; a length cut keeps it whole.
abstract final class NameRule {
  static const version = 1;

  /// Nextcloud 33 refuses a name over 250 UTF-8 bytes (task D1).
  static const maxBytes = 250;

  /// Unicode White_Space: trimmed from both ends of every name (R1).
  static const whitespace = {
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, //
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
    0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
  };
  static const untitled = 'Untitled';

  static const _windowsCharacters = '<>:"\\|?*';
  static const _reserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  static const _forbiddenNames = {'.', '..', '.htaccess'};
  static const _forbiddenExtensions = ['.part', '.filepart'];

  /// Windows characters to fullwidth forms, C0 controls to Control Pictures
  /// (R3 step 1).
  static int _windowsLookalike(int rune) {
    if (rune >= 0x01 && rune < 0x20) return 0x2400 + rune;
    if (_windowsCharacters.codeUnits.contains(rune)) return rune + 0xFEE0;
    return rune;
  }

  /// What the cloud cannot store but a lookalike fixes, for every client
  /// (R2): `\` and C0 controls.
  static int _cloudLookalike(int rune) =>
      rune == 0x5C || (rune >= 0x01 && rune < 0x20)
      ? _windowsLookalike(rune)
      : rune;

  /// Refused by Nextcloud or the gateway's path check.
  static bool _forbiddenCharacter(int rune) =>
      rune < 0x20 || rune == 0x2F || rune == 0x5C || rune == 0x7F;

  /// (stem, extension); the extension is '' for a folder or a name without
  /// one.
  static (String, String) split(String name, {bool folder = false}) {
    final dot = name.lastIndexOf('.');
    if (folder || dot <= 0 || dot == name.length - 1) return (name, '');
    return (name.substring(0, dot), name.substring(dot + 1));
  }

  static String _join(String stem, String extension) =>
      extension.isEmpty ? stem : '$stem.$extension';

  static String _strip(String text) {
    final runes = text.runes.toList();
    var start = 0, end = runes.length;
    while (start < end && whitespace.contains(runes[start])) {
      start++;
    }
    while (end > start && whitespace.contains(runes[end - 1])) {
      end--;
    }
    return String.fromCharCodes(runes, start, end);
  }

  static int _size(String text) => utf8.encode(text).length;

  /// `stem + tail` before the extension, the stem cut at a code point
  /// boundary so the name fits [maxBytes]; a cut leaves no whitespace at the
  /// stem's end. Null when no stem would be left.
  static String? _fit(String stem, String extension, [String tail = '']) {
    final budget =
        maxBytes - _size(tail) - (extension.isEmpty ? 0 : _size(extension) + 1);
    if (_size(stem) > budget) {
      final runes = stem.runes.toList();
      var size = _size(stem);
      while (runes.isNotEmpty && size > budget) {
        size -= _size(String.fromCharCode(runes.removeLast()));
      }
      stem = _strip(String.fromCharCodes(runes));
    }
    return stem.isEmpty ? null : _join(stem + tail, extension);
  }

  /// [name] with the first ` (n)`, n >= 2, whose fold key is not in [taken].
  static String _suffixed(String name, bool folder, Set<String> taken) {
    final (stem, extension) = split(name, folder: folder);
    for (var n = 2; ; n++) {
      final candidate = _fit(stem, extension, ' ($n)');
      if (candidate == null) return name;
      if (!taken.contains(NamePolicy.foldKey(candidate))) return candidate;
    }
  }

  /// The cloud name for an item named [name] (R1, R2): unchanged when nothing
  /// needs fixing. [siblings] are the other names in its folder; a changed
  /// name that meets one by case or accents gets the next free ` (n)`.
  static String cleanup(
    String name, {
    Iterable<String> siblings = const [],
    bool folder = false,
  }) {
    final trimmed = _strip(name);
    final (stem, extension) = split(name, folder: folder);
    String result;
    if (trimmed.isEmpty) {
      result = untitled;
    } else if (extension.isNotEmpty &&
        _strip(stem).isEmpty &&
        _strip(extension).isNotEmpty) {
      result = '$untitled.${_strip(extension)}';
    } else {
      result = trimmed;
    }
    result = String.fromCharCodes(result.runes.map(_cloudLookalike));
    if (_size(result) > maxBytes) {
      final (stem, extension) = split(result, folder: folder);
      result = _fit(stem, extension) ?? result;
    }
    if (result == name) return name;
    final taken = {for (final sibling in siblings) NamePolicy.foldKey(sibling)};
    return taken.contains(NamePolicy.foldKey(result))
        ? _suffixed(result, folder, taken)
        : result;
  }

  /// Why the cloud cannot or must not hold [name], else null.
  static CloudNameProblem? cloudCheck(String name) {
    if (name.isEmpty) return CloudNameProblem.empty;
    if (_strip(name) != name) return CloudNameProblem.untrimmed;
    if (name.runes.any(_forbiddenCharacter)) {
      return CloudNameProblem.forbiddenCharacter;
    }
    final lower = String.fromCharCodes(
      name.codeUnits.map((u) => u >= 0x41 && u <= 0x5A ? u + 0x20 : u),
    );
    if (_forbiddenNames.contains(lower)) return CloudNameProblem.forbiddenName;
    if (_forbiddenExtensions.any(lower.endsWith)) {
      return CloudNameProblem.forbiddenExtension;
    }
    if (_size(name) > maxBytes) return CloudNameProblem.tooLong;
    return null;
  }

  /// R3 steps 1-3: characters, trailing dots, device names.
  static String _windows(String name) {
    final runes = name.runes.map(_windowsLookalike).toList();
    // Windows drops trailing dots, and with them any space they leave.
    while (runes.isNotEmpty && (runes.last == 0x2E || runes.last == 0x20)) {
      runes.removeLast();
    }
    final result = runes.isEmpty ? untitled : String.fromCharCodes(runes);
    var device = result.split('.').first;
    while (device.endsWith(' ')) {
      device = device.substring(0, device.length - 1);
    }
    if (device.codeUnits.every((unit) => unit < 0x80) &&
        _reserved.contains(device.toUpperCase())) {
      return '${device}_${result.substring(device.length)}';
    }
    return result;
  }

  static int _order(NameEntry a, NameEntry b) {
    if ((a.fileId == null) != (b.fileId == null)) {
      return a.fileId == null ? 1 : -1;
    }
    final byId = (a.fileId ?? 0).compareTo(b.fileId ?? 0);
    return byId != 0 ? byId : _compareCodePoints(a.name, b.name);
  }

  // Code point order, as Python compares strings.
  static int _compareCodePoints(String a, String b) {
    final x = a.runes.toList(), y = b.runes.toList();
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return x.length.compareTo(y.length);
  }

  /// {cloud name: local name} for the cloud items of one folder on [os]
  /// (R3). The result does not depend on the order of [entries].
  static Map<String, String> localNames(
    Iterable<NameEntry> entries,
    NameOs os,
  ) {
    final sorted = entries.toList()..sort(_order);
    if (os == NameOs.linux || os == NameOs.android) {
      return {for (final entry in sorted) entry.name: entry.name};
    }
    final base = {
      for (final entry in sorted)
        entry.name: os == NameOs.windows ? _windows(entry.name) : entry.name,
    };
    final groups = <String, List<NameEntry>>{};
    for (final entry in sorted) {
      groups
          .putIfAbsent(NamePolicy.foldKey(base[entry.name]!), () => [])
          .add(entry);
    }
    final result = <String, String>{};
    final later = <NameEntry>[];
    for (final members in groups.values) {
      // Step 4: the oldest keeps its result. Step 5: unless its name changed
      // into the exact name of an item whose name did not change; that item
      // keeps it.
      final oldest = members.first, oldestBase = base[oldest.name]!;
      final keeper = oldestBase == oldest.name
          ? oldest
          : members.firstWhere(
              (m) => m.name == oldestBase,
              orElse: () => oldest,
            );
      result[keeper.name] = base[keeper.name]!;
      later.addAll(members.where((m) => !identical(m, keeper)));
    }
    final taken = {for (final name in result.values) NamePolicy.foldKey(name)};
    // Oldest first, the next ` (n)` free of every other name.
    for (final entry in later..sort(_order)) {
      final local = _suffixed(base[entry.name]!, entry.folder, taken);
      taken.add(NamePolicy.foldKey(local));
      result[entry.name] = local;
    }
    return result;
  }

  /// The local name of the item [cloudName] among [entries], its folder's
  /// cloud items. An item missing from [entries] is placed after them, as
  /// the newest.
  static String localName(
    String cloudName,
    Iterable<NameEntry> entries,
    NameOs os, {
    bool folder = false,
  }) {
    final all = entries.toList();
    if (all.every((entry) => entry.name != cloudName)) {
      all.add(NameEntry(cloudName, folder: folder));
    }
    return localNames(all, os)[cloudName]!;
  }

  /// The cloud name for the local name [local] in a folder whose cloud items
  /// are [entries]: a known item's when its local name is exactly [local],
  /// else [local] itself.
  static String cloudName(
    String local,
    Iterable<NameEntry> entries,
    NameOs os,
  ) {
    for (final MapEntry(:key, :value) in localNames(entries, os).entries) {
      if (value == local) return key;
    }
    return local;
  }
}
