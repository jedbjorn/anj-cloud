/// Source scanning for no_openssl_cli_test.dart: comment stripping that
/// respects string literals, and the process-launch rules for client code.
library;

enum SourceKind { dart, cFamily, nestingCFamily, hash, xml }

SourceKind? sourceKind(String path) {
  final extension = path.contains('.') ? path.split('.').last : '';
  final name = path.split('/').last;
  if (extension == 'dart') return SourceKind.dart;
  if (const {
    'c',
    'cc',
    'cpp',
    'cxx',
    'h',
    'hh',
    'hpp',
    'inc',
    'm',
    'mm',
    'java',
    'gradle',
  }.contains(extension)) {
    return SourceKind.cFamily;
  }
  // Kotlin and Swift block comments nest.
  if (const {'kt', 'kts', 'swift'}.contains(extension)) {
    return SourceKind.nestingCFamily;
  }
  if (name == 'CMakeLists.txt' ||
      const {'cmake', 'properties', 'pro', 'cfg'}.contains(extension)) {
    return SourceKind.hash;
  }
  if (const {'xml', 'plist', 'xcconfig', 'manifest'}.contains(extension)) {
    return extension == 'xcconfig' ? SourceKind.cFamily : SourceKind.xml;
  }
  return null;
}

/// [text] with comments replaced by spaces (newlines kept, so line numbers
/// hold). String and character literals are kept verbatim, so a `//` or `#`
/// inside a literal never hides the code after it.
String stripComments(String text, SourceKind kind) {
  final out = StringBuffer();
  var i = 0;
  bool at(String token) => text.startsWith(token, i);
  void blank(int end) {
    for (; i < end && i < text.length; i++) {
      out.write(text[i] == '\n' ? '\n' : ' ');
    }
  }

  void copy(int end) {
    final stop = end > text.length ? text.length : end;
    out.write(text.substring(i, stop));
    i = stop;
  }

  int lineEnd() {
    final end = text.indexOf('\n', i);
    return end < 0 ? text.length : end;
  }

  int blockEnd(String open, String close, {required bool nests}) {
    var depth = 0;
    var j = i;
    while (j < text.length) {
      if (nests && text.startsWith(open, j)) {
        depth++;
        j += open.length;
      } else if (text.startsWith(close, j)) {
        j += close.length;
        if (!nests || --depth == 0) return j;
      } else {
        j++;
      }
    }
    return text.length;
  }

  // End of a quoted literal starting at [start] with [quote]; backslash
  // escapes unless [raw]. Dart `${...}` interpolation is scanned as code.
  late int Function(int start, String quote, bool raw) literalEnd;
  late int Function(int start) dartCodeUntilBrace;
  literalEnd = (start, quote, raw) {
    var j = start + quote.length;
    while (j < text.length) {
      if (!raw && text[j] == r'\') {
        j += 2;
      } else if (text.startsWith(quote, j)) {
        return j + quote.length;
      } else if (kind == SourceKind.dart && !raw && text.startsWith(r'${', j)) {
        j = dartCodeUntilBrace(j + 2);
      } else if (quote.length == 1 && text[j] == '\n') {
        return j; // unterminated single-line literal: stop at the line end
      } else {
        j++;
      }
    }
    return text.length;
  };
  dartCodeUntilBrace = (start) {
    var depth = 1;
    var j = start;
    while (j < text.length) {
      final c = text[j];
      if (c == '{') {
        depth++;
        j++;
      } else if (c == '}') {
        if (--depth == 0) return j + 1;
        j++;
      } else if (c == "'" || c == '"') {
        final triple = text.startsWith(c * 3, j) ? c * 3 : c;
        j = literalEnd(j, triple, false);
      } else {
        j++;
      }
    }
    return text.length;
  };

  while (i < text.length) {
    final c = text[i];
    switch (kind) {
      case SourceKind.dart:
        if (at('//')) {
          blank(lineEnd());
        } else if (at('/*')) {
          blank(blockEnd('/*', '*/', nests: true));
        } else if ((c == 'r' || c == 'R') &&
            i + 1 < text.length &&
            (text[i + 1] == "'" || text[i + 1] == '"') &&
            (i == 0 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(text[i - 1]))) {
          final q = text[i + 1];
          final quote = text.startsWith(q * 3, i + 1) ? q * 3 : q;
          copy(literalEnd(i + 1, quote, true));
        } else if (c == "'" || c == '"') {
          final quote = at(c * 3) ? c * 3 : c;
          copy(literalEnd(i, quote, false));
        } else {
          copy(i + 1);
        }
      case SourceKind.cFamily || SourceKind.nestingCFamily:
        final nests = kind == SourceKind.nestingCFamily;
        final raw = RegExp(r'R"([^(\s]*)\(').matchAsPrefix(text, i);
        if (at('//')) {
          blank(lineEnd());
        } else if (at('/*')) {
          blank(blockEnd('/*', '*/', nests: nests));
        } else if (raw != null &&
            (i == 0 || !RegExp(r'[A-Za-z0-9_]').hasMatch(text[i - 1]))) {
          final close = ')${raw.group(1)}"';
          final end = text.indexOf(close, raw.end);
          copy(end < 0 ? text.length : end + close.length);
        } else if (c == '"') {
          copy(literalEnd(i, at('"""') ? '"""' : '"', false));
        } else if (c == "'" && kind == SourceKind.cFamily) {
          copy(literalEnd(i, "'", false));
        } else {
          copy(i + 1);
        }
      case SourceKind.hash:
        if (at('#[[')) {
          blank(blockEnd('#[[', ']]', nests: false));
        } else if (c == '#') {
          blank(lineEnd());
        } else if (c == '"') {
          copy(literalEnd(i, '"', false));
        } else {
          copy(i + 1);
        }
      case SourceKind.xml:
        if (at('<!--')) {
          blank(blockEnd('<!--', '-->', nests: false));
        } else {
          copy(i + 1);
        }
    }
  }
  return out.toString();
}

/// The only process launches client code may contain, by file and by exact
/// call-site line (trimmed). Any other mention of `Process` in Dart code, or
/// a second one in the same file, is a violation.
const processCallSites = {
  'lib/platform/linux/manager_autostart.dart': [
    'final result = await Process.run(command, [',
  ],
  // Main's Linux self-update (spec #37, PR #94): the installed manager and a
  // chmod of the update folder; neither is OpenSSL.
  // Spec #40 R2: the embedded manager's apply-update (check, then the
  // detached hand-over) and chmod of the private staging folder.
  'lib/platform/macos/macos_self_update.dart': [
    "final result = await Process.run('/bin/chmod', ['0700', directory.path]);",
    'result = await Process.run(command, [',
    'await Process.start(command, [',
  ],
  'lib/platform/linux/manager_self_update.dart': [
    "final result = await Process.run('/usr/bin/chmod', [",
    'result = await Process.run(command, [',
    'await Process.start(command, [',
  ],
  // The Windows manager's apply-update: the check, then the detached
  // hand-over.
  'lib/platform/windows/windows_self_update.dart': [
    'result = await Process.run(command, [',
    'await Process.start(command, [',
  ],
};

final _openssl = RegExp('openssl', caseSensitive: false);
final _dartProcess = RegExp(r'\bProcess\b');
// Native symbols a Dart FFI binding could look up to start a process.
final _spawnSymbol = RegExp(
  r'''['"](exec[lv]p?e?|posix_spawnp?|system|popen|_w?popen|v?fork|CreateProcess[AW]?|ShellExecute(Ex)?[AW]?|WinExec)['"]''',
);
// Process launch in native and platform-runner code (C, C++, Objective-C,
// Java, Kotlin, Swift).
final _nativeSpawn = RegExp(
  r'\b(exec[lv]p?e?|posix_spawnp?|system|popen|_w?popen|v?fork|CreateProcess[AW]?|ShellExecute(Ex)?[AW]?|WinExec)\s*\(|\bProcessBuilder\b|\bRuntime\s*\.\s*getRuntime\s*\(\s*\)\s*\.\s*exec\b|\bNSTask\b|\bProcess\s*\(\s*\)',
);

/// Violations in one client source file (path relative to the package).
List<String> scanSource(String path, String text) {
  final kind = sourceKind(path);
  if (kind == null) return const [];
  final code = stripComments(text, kind);
  final problems = <String>[];
  final lines = code.split('\n');
  for (var n = 0; n < lines.length; n++) {
    if (_openssl.hasMatch(lines[n])) {
      problems.add('$path:${n + 1}: names openssl');
    }
  }
  if (kind == SourceKind.dart) {
    final allowed = [...?processCallSites[path]];
    for (var n = 0; n < lines.length; n++) {
      for (final _ in _dartProcess.allMatches(lines[n])) {
        if (!allowed.remove(lines[n].trim())) {
          problems.add('$path:${n + 1}: process launch outside the allowlist');
        }
      }
      if (_spawnSymbol.hasMatch(lines[n])) {
        problems.add('$path:${n + 1}: names a process-spawning symbol');
      }
    }
    for (final site in allowed) {
      problems.add('$path: allowlisted call site missing: $site');
    }
  } else if (_nativeSpawn.hasMatch(code)) {
    for (var n = 0; n < lines.length; n++) {
      if (_nativeSpawn.hasMatch(lines[n])) {
        problems.add('$path:${n + 1}: native process launch');
      }
    }
  }
  return problems;
}
