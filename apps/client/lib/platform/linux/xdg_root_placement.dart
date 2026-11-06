import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ports/root_placement.dart';

/// Linux root placement (spec #34 P1, P2): the synced folder goes in the
/// home folder, or in the root the installer reserved for this profile
/// (`select-profile --new --root`, passed as `--default-root`). The desktop
/// directory is what `xdg-user-dir DESKTOP` prints, resolved the same way
/// without running it: `XDG_DESKTOP_DIR` from `user-dirs.dirs` in
/// `$XDG_CONFIG_HOME` (default `~/.config`), else from the environment, else
/// `~/Desktop`. A missing directory, or one that is the home folder itself
/// (a disabled desktop), means no shortcut.
class XdgRootPlacement implements RootPlacement {
  XdgRootPlacement({Map<String, String>? environment, this.reservedParent})
    : environment = environment ?? Platform.environment;
  final Map<String, String> environment;
  final String? reservedParent;

  String? get _home {
    final home = environment['HOME'];
    return home == null || home.isEmpty || !p.isAbsolute(home) ? null : home;
  }

  @override
  String? defaultParent() => reservedParent ?? _home;

  @override
  bool get stagingInProfile => true;

  @override
  String? desktopDirectory() {
    final home = _home;
    if (home == null) return null;
    final config = environment['XDG_CONFIG_HOME'];
    final configured = _fromUserDirs(
      p.join(
        config != null && p.isAbsolute(config)
            ? config
            : p.join(home, '.config'),
        'user-dirs.dirs',
      ),
      home,
    );
    final candidate =
        configured ??
        _expand(environment['XDG_DESKTOP_DIR'], home) ??
        p.join(home, 'Desktop');
    final normalized = p.normalize(candidate);
    if (p.equals(normalized, p.normalize(home))) return null;
    if (FileSystemEntity.typeSync(normalized) !=
        FileSystemEntityType.directory) {
      return null;
    }
    return normalized;
  }

  /// The home folder, xdg-user-dirs' default names and every directory
  /// `user-dirs.dirs` names (`XDG_*_DIR`, localized names included).
  @override
  Set<String> keptDirectories() {
    final home = _home;
    if (home == null) return const {};
    final kept = standardUserDirectories(home);
    final config = environment['XDG_CONFIG_HOME'];
    try {
      final lines = File(
        p.join(
          config != null && p.isAbsolute(config)
              ? config
              : p.join(home, '.config'),
          'user-dirs.dirs',
        ),
      ).readAsLinesSync();
      for (final line in lines) {
        final match = RegExp(r'^\s*XDG_[A-Z]+_DIR\s*=\s*"([^"]*)"\s*$')
            .firstMatch(line);
        final value = _expand(match?.group(1), home);
        if (value != null) kept.add(p.normalize(value));
      }
    } on FileSystemException {
      // No user-dirs.dirs: the default names only.
    }
    return kept;
  }

  /// `XDG_DESKTOP_DIR="$HOME/Desktop"` lines (shell syntax as xdg-user-dirs
  /// writes it: `$HOME/`-relative or absolute, in double quotes).
  String? _fromUserDirs(String file, String home) {
    final List<String> lines;
    try {
      lines = File(file).readAsLinesSync();
    } on FileSystemException {
      return null;
    }
    String? value;
    for (final line in lines) {
      final match = RegExp(r'^\s*XDG_DESKTOP_DIR\s*=\s*"([^"]*)"\s*$')
          .firstMatch(line);
      if (match != null) value = match.group(1);
    }
    return _expand(value, home);
  }

  String? _expand(String? value, String home) {
    if (value == null || value.isEmpty) return null;
    if (value == r'$HOME') return home;
    if (value.startsWith(r'$HOME/')) {
      return p.join(home, value.substring(r'$HOME/'.length));
    }
    return p.isAbsolute(value) ? value : null;
  }
}
