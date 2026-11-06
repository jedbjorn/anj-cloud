/// Ordered path-key lookups shared by the sync engine's local view and the
/// platform watchers (moved unchanged from
/// lib/platform/native/local_watcher.dart).
library;

import 'dart:collection';

/// Keys equal to [path] or beneath it ('' is everything), in order.
List<String> keysUnder<V>(SplayTreeMap<String, V> map, String path) {
  if (path.isEmpty) return map.keys.toList();
  final result = <String>[if (map.containsKey(path)) path];
  final prefix = '$path/';
  // Every key beginning with the prefix sorts after the prefix itself.
  for (
    var key = map.firstKeyAfter(prefix);
    key != null && key.startsWith(prefix);
    key = map.firstKeyAfter(key)
  ) {
    result.add(key);
  }
  return result;
}
