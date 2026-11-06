import 'dart:convert';
import 'dart:io';

/// Presentation preferences live beside the profile, never in the sync root.
/// Colours belong to an exact relative path; folders do not tint descendants.
class IconColors {
  IconColors(Directory profile)
    : _file = File('${profile.path}/icon-colors.json');

  final File _file;
  Map<String, int> _colors = {};

  int? operator [](String path) => _colors[path];

  void load() {
    if (!_file.existsSync()) return;
    final value = jsonDecode(_file.readAsStringSync());
    if (value is! Map<String, dynamic> ||
        value.values.any((v) => v is! int || v < 0 || v > 0xffffffff)) {
      throw const FormatException('Invalid icon colour preferences');
    }
    _colors = value.cast<String, int>();
  }

  void set(String path, int? color) {
    final updated = {..._colors};
    if (color == null) {
      updated.remove(path);
    } else {
      updated[path] = color;
    }
    // Publish the entire small preference file atomically before updating UI.
    final temporary = File('${_file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(updated), flush: true);
    temporary.renameSync(_file.path);
    _colors = updated;
  }
}
