import '../state/model.dart';
import 'name_rule.dart';
import 'name_tables.dart';

/// The rows decision #120 held items under, before spec #49 retired every
/// name hold. A manifest written by an earlier client may still carry one:
/// such a row is visited again on the first pass of this client and
/// resolves through the name rule with no user action (spec #49 AC8).
const _legacyNameHolds = {
  'Name not allowed on other devices: rename to sync',
  'pending: the folder name is not allowed on other devices',
  'Cloud only: name not allowed on this device. Rename it on another device to get it here',
  'Cloud only: another item here has the same name on this device. Rename one on another device to get both here',
  'Cloud only: its folder name is not allowed on this device',
  'Renamed on another device to a name not allowed on this device. It keeps its old name here; rename it again on another device',
  'Renamed on another device to a name another item here has on this device. It keeps its old name here; rename one on another device',
  'Moved on another device into a folder this device cannot hold. It stays where it is here',
};
bool isLegacyNameHold(String status) => _legacyNameHolds.contains(status);

/// Information on a row whose full path on this device is over 259
/// characters (Windows, spec #32 File Names): it syncs normally, but some
/// other Windows apps cannot open it while long paths are off.
const longPathNote = 'Long path: some Windows apps may not open this';
const win32MaxPath = 259;

/// A file another program holds open without read sharing (Windows; SC-048
/// F5): left as it is until a later pass can read it.
const fileBusyStatus = 'Open in another app: syncs when it is closed';
bool isBusyStatus(String status) => status == fileBusyStatus;

/// The gateway refused a create or rename: 422 `name-not-portable`, the
/// backstop for a name the cloud cannot store (spec #49 Gateway). The row
/// is the residual one ([cantSyncNameStatus]).
class NameNotPortable extends CloudFailure {
  NameNotPortable(this.problem)
    : super(cantSyncNameStatus(problem), status: 422);
  final CloudNameProblem? problem;
}

/// Name spelling shared by every client and the gateway: fold keys and NFC
/// (decision #138), from the generated Unicode tables (name_tables.dart).
/// The name rule itself is [NameRule].
abstract final class NamePolicy {
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
