import '../state/model.dart';
import 'name_tables.dart';

/// Why a name cannot exist on Windows or macOS (decision #120, seam S1).
enum NameProblem {
  empty('A name is required.'),
  invalidCharacter(
    'Names cannot contain < > : " / \\ | ? * or control characters on other devices.',
  ),
  reserved('Windows reserves this name (CON, PRN, AUX, NUL, COM1-9, LPT1-9).'),
  trailingDotOrSpace(
    'Names cannot end with a dot or a space on other devices.',
  ),
  clash(
    'Another item in this folder has the same name apart from upper/lower case or accents.',
  );

  const NameProblem(this.text);

  /// One sentence for the Rename dialog.
  final String text;

  /// The gateway's `reason` code for this problem.
  static NameProblem? fromReason(Object? reason) => switch (reason) {
    'empty' => empty,
    'invalidCharacter' => invalidCharacter,
    'reserved' => reserved,
    'trailingDotOrSpace' => trailingDotOrSpace,
    'clash' => clash,
    _ => null,
  };
}

/// Status of a local item that is not uploaded because of its name. Nothing
/// is renamed for the user; the file stays on this device.
const nameNotAllowedStatus =
    'Name not allowed on other devices: rename to sync';

/// Status of a local item inside a folder whose name is not allowed.
const nameFolderPendingStatus =
    'pending: the folder name is not allowed on other devices';

bool isNameRefusal(String status) => status == nameNotAllowedStatus;

/// Statuses of a server item this device cannot hold under its name
/// (decision #120 Q2; `NameHolds`): Cloud-only and never created here. This
/// device has no copy to rename, so the row offers no Rename and says where
/// the fix is.
const serverNameNotAllowedStatus =
    'Cloud only: name not allowed on this device. Rename it on another device to get it here';
const serverNameClashStatus =
    'Cloud only: another item here has the same name on this device. Rename one on another device to get both here';
const serverFolderNameStatus =
    'Cloud only: its folder name is not allowed on this device';

/// Information on a row whose full path on this device is over 259
/// characters (Windows, spec #32 File Names): it syncs normally, but some
/// other Windows apps cannot open it while long paths are off.
const longPathNote = 'Long path: some Windows apps may not open this';
const win32MaxPath = 259;

bool isServerNameHold(String status) =>
    status == serverNameNotAllowedStatus ||
    status == serverNameClashStatus ||
    status == serverFolderNameStatus;

/// A file another program holds open without read sharing (Windows; SC-048
/// F5): left as it is until a later pass can read it.
const fileBusyStatus = 'Open in another app: syncs when it is closed';
bool isBusyStatus(String status) => status == fileBusyStatus;

/// The gateway refused a create or rename: 422 `name-not-portable`, for
/// example a sibling clash that appeared after the last listing, or a
/// name this client's check did not cover.
class NameNotPortable extends CloudFailure {
  const NameNotPortable(this.problem)
    : super(nameNotAllowedStatus, status: 422);
  final NameProblem? problem;
}

/// The portable-name rule shared by every client and the gateway
/// (services/access/portable_names.py). Both run
/// tests/name_policy_vectors.json and use the same generated Unicode tables
/// (name_tables.dart), so they cannot drift.
abstract final class NamePolicy {
  static const _reserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  static const _invalid = '<>:"/\\|?*';

  /// The problem with one path component [name], or null when it is portable.
  static NameProblem? check(String name) {
    if (name.isEmpty) return NameProblem.empty;
    for (final unit in name.codeUnits) {
      if (unit < 0x20 || _invalid.codeUnits.contains(unit)) {
        return NameProblem.invalidCharacter;
      }
    }
    var stem = name.split('.').first;
    while (stem.endsWith(' ')) {
      stem = stem.substring(0, stem.length - 1);
    }
    if (stem.codeUnits.every((unit) => unit < 0x80) &&
        _reserved.contains(stem.toUpperCase())) {
      return NameProblem.reserved;
    }
    if (name.endsWith('.') || name.endsWith(' ')) {
      return NameProblem.trailingDotOrSpace;
    }
    return null;
  }

  /// Names with equal keys differ only by case or Unicode normalization:
  /// canonical caseless matching, NFD(casefold(NFD(name))).
  static String foldKey(String name) {
    final folded = <int>[];
    for (final rune in _decompose(name.runes)) {
      final mapped = nameCaseFold[rune];
      if (mapped == null) {
        folded.add(rune);
      } else {
        folded.addAll(mapped);
      }
    }
    return String.fromCharCodes(_decompose(folded));
  }

  /// [name] in Unicode NFC, the spelling every cloud name has (decision
  /// #138: Nextcloud stores NFC, so clients upload and move names in NFC).
  /// A path's separators are unaffected, so this applies to whole paths.
  static String nfc(String name) {
    // Below U+0300 there is no combining mark and nothing NFC changes.
    if (name.codeUnits.every((unit) => unit < 0x300)) return name;
    final decomposed = _decompose(name.runes);
    if (decomposed.isEmpty) return name;
    final out = <int>[decomposed.first];
    var starter = (nameCombiningClass[decomposed.first] ?? 0) == 0 ? 0 : -1;
    var lastClass = 0;
    for (final rune in decomposed.skip(1)) {
      final cls = nameCombiningClass[rune] ?? 0;
      final adjacent = starter == out.length - 1;
      if (starter >= 0 && (adjacent || (lastClass != 0 && lastClass < cls))) {
        final composite = _compose(out[starter], rune);
        if (composite != null) {
          out[starter] = composite;
          continue;
        }
      }
      if (cls == 0) starter = out.length;
      lastClass = cls;
      out.add(rune);
    }
    return String.fromCharCodes(out);
  }

  /// Two names that differ only by Unicode normalization are one name in
  /// the cloud (decision #138).
  static bool sameInCloud(String a, String b) => a == b || nfc(a) == nfc(b);

  static int? _compose(int first, int second) {
    final l = first - _lBase, v = second - _vBase;
    if (l >= 0 && l < 19 && v >= 0 && v < 21) {
      return _sBase + (l * 21 + v) * _tCount;
    }
    final s = first - _sBase, t = second - _tBase;
    if (s >= 0 && s < _sCount && s % _tCount == 0 && t > 0 && t < _tCount) {
      return first + t;
    }
    return nameComposition[first * 0x110000 + second];
  }

  /// The first of [siblings] that differs from [name] only by case or
  /// normalization, else null. An identical name is the same item.
  static String? clashWith(String name, Iterable<String> siblings) {
    String? key;
    for (final sibling in siblings) {
      if (sibling == name) continue;
      key ??= foldKey(name);
      if (foldKey(sibling) == key) return sibling;
    }
    return null;
  }

  /// [check], then [clashWith].
  static NameProblem? problem(String name, Iterable<String> siblings) =>
      check(name) ??
      (clashWith(name, siblings) == null ? null : NameProblem.clash);

  static const _sBase = 0xAC00, _lBase = 0x1100, _vBase = 0x1161;
  static const _tBase = 0x11A7, _tCount = 28, _nCount = 21 * 28;
  static const _sCount = 19 * _nCount;

  static List<int> _decompose(Iterable<int> runes) {
    final result = <int>[];
    for (final rune in runes) {
      final index = rune - _sBase;
      if (index >= 0 && index < _sCount) {
        result
          ..add(_lBase + index ~/ _nCount)
          ..add(_vBase + (index % _nCount) ~/ _tCount);
        if (index % _tCount != 0) result.add(_tBase + index % _tCount);
      } else {
        result.addAll(nameDecomposition[rune] ?? [rune]);
      }
    }
    // Canonical ordering: stable sort of each run of non-starters by class.
    var start = 0;
    while (start < result.length) {
      if ((nameCombiningClass[result[start]] ?? 0) == 0) {
        start++;
        continue;
      }
      var end = start;
      while (end < result.length &&
          (nameCombiningClass[result[end]] ?? 0) != 0) {
        end++;
      }
      final run = result.sublist(start, end);
      _stableSortByClass(run);
      result.setRange(start, end, run);
      start = end;
    }
    return result;
  }

  // Insertion sort: stable, and runs of combining marks are short.
  static void _stableSortByClass(List<int> run) {
    for (var i = 1; i < run.length; i++) {
      final value = run[i];
      final cls = nameCombiningClass[value]!;
      var j = i - 1;
      while (j >= 0 && nameCombiningClass[run[j]]! > cls) {
        run[j + 1] = run[j];
        j--;
      }
      run[j + 1] = value;
    }
  }
}
