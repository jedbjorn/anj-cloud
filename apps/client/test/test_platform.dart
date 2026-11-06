// Seat helpers so the shared suite runs on every desktop seat it is sent to:
// the VM host Linux (tool/check.sh) and mac-test (tool/macos/mac_test.sh, spec #31
// acceptance row 4). Every skip they produce states its reason; on Linux,
// where the suite was written, none of them skips anything.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The native library tests hand to a [ClientController] or a sync worker.
///
/// Linux reads `ANJ_ROOTFS_LIBRARY` itself, so this changes nothing there.
/// The macOS app loads only its own bundle's dylib and never reads the
/// environment (`macos_native_library.dart`), so a test process (which has
/// no bundle) passes the test build explicitly, as `check_macos.sh` sets it.
String? get testNativeLibrary => Platform.environment['ANJ_ROOTFS_LIBRARY'];

/// The `dart` of the Flutter SDK running these tests, for crash fixtures
/// started with `dart run`: `FLUTTER_SDK`, else `FLUTTER_ROOT` (which
/// `flutter test` exports), else `dart` on `PATH`. No host path is assumed.
String get testDartExecutable {
  final sdk =
      Platform.environment['FLUTTER_SDK'] ??
      Platform.environment['FLUTTER_ROOT'];
  return sdk == null ? 'dart' : p.join(sdk, 'bin', 'dart');
}

/// Null on Linux; elsewhere the skip reason for a test of Linux behaviour.
String? linuxOnly(String why) => Platform.isLinux ? null : 'Linux only: $why';

/// Null when [path] (relative to apps/client) can be read; on a seat other
/// than Linux, the skip reason when it is outside the sources sent there.
/// Linux runs in the checkout, so a missing file still fails there.
String? checkoutFile(String path) => Platform.isLinux || File(path).existsSync()
    ? null
    : 'needs $path, which is outside the client sources mac_test.sh sends; '
          'the check does not depend on the platform and runs on the VM host';

/// For a suite that cannot run on this seat at all (for example one whose
/// setUpAll needs a tool the seat lacks): declares one skipped test named
/// [name] carrying [reason] and returns true, so `main` returns before
/// declaring the suite. Returns false, declaring nothing, when [reason] is
/// null, so test names are unchanged wherever the suite runs.
bool skipSuite(String name, String? reason) {
  if (reason == null) return false;
  test(name, () {}, skip: reason);
  return true;
}

/// Whether names on [dir]'s volume that differ only by letter case are the
/// same item (APFS by default; the VM host's ext4, btrfs and tmpfs are byte-exact).
bool foldsCase(Directory dir) => _sameItem(dir, 'Fold.probe', 'fOLD.probe');

/// Whether names on [dir]'s volume that differ only by Unicode
/// normalization (NFC `é` against NFD `e` + U+0301) are the same item.
bool foldsNormalization(Directory dir) => _sameItem(dir, 'é.probe', 'é.probe');

bool _sameItem(Directory dir, String created, String other) {
  final probe = dir.createTempSync('anj-fold-');
  try {
    File(p.join(probe.path, created)).writeAsStringSync('');
    return File(p.join(probe.path, other)).existsSync();
  } finally {
    probe.deleteSync(recursive: true);
  }
}

/// Sets [file]'s modification time to [ns] nanoseconds since the epoch and
/// keeps its access time: what GNU `touch -m -d @<s>.<ns>` does, without
/// GNU touch (BSD touch on macOS takes no `@` epoch or relative dates).
/// Dart's own setter has millisecond precision only.
Future<void> setMtimeNs(File file, int ns) async {
  final result = await Process.run('python3', [
    '-I',
    '-c',
    'import os,sys\n'
        'st=os.stat(sys.argv[1])\n'
        'os.utime(sys.argv[1],ns=(st.st_atime_ns,int(sys.argv[2])))',
    file.path,
    '$ns',
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

/// The OpenSSL CLI the TLS fixtures use.
///
/// Everywhere but macOS: `ANJ_TEST_OPENSSL` if set, else `/usr/bin/openssl`,
/// else the first `openssl` on `PATH`, never checked or skipped, so a missing
/// or broken OpenSSL fails the TLS suites.
///
/// On macOS: `ANJ_TEST_OPENSSL`, else the first `openssl` on `PATH`, else
/// `/usr/bin/openssl`; null unless it is OpenSSL 3 or later (macOS's
/// `/usr/bin/openssl` is LibreSSL, which lacks options the fixtures use, such
/// as `-noenc`).
String? get testOpenssl => _openssl.$1;

/// Null when [testOpenssl] is usable, and always null off macOS; otherwise
/// the skip reason.
String? get opensslSkip => _openssl.$2;

final (String?, String?) _openssl = _resolveOpenssl();

(String?, String?) _resolveOpenssl() {
  final path = [
    for (final dir in (Platform.environment['PATH'] ?? '').split(':'))
      if (dir.isNotEmpty) p.join(dir, 'openssl'),
  ];
  if (!Platform.isMacOS) {
    final override = Platform.environment['ANJ_TEST_OPENSSL'];
    if (override != null) return (override, null);
    final found = ['/usr/bin/openssl', ...path].firstWhere(
      (candidate) => File(candidate).existsSync(),
      orElse: () => '/usr/bin/openssl',
    );
    return (found, null);
  }
  final candidates = <String>[
    ?Platform.environment['ANJ_TEST_OPENSSL'],
    ...path,
    '/usr/bin/openssl',
  ];
  final seen = <String>[];
  for (final candidate in candidates) {
    if (!File(candidate).existsSync()) continue;
    String version;
    try {
      final result = Process.runSync(candidate, ['version']);
      version = '${result.stdout}'.trim();
    } on ProcessException {
      continue;
    }
    final major = RegExp(r'^OpenSSL (\d+)\.').firstMatch(version);
    if (major != null && int.parse(major.group(1)!) >= 3) {
      return (candidate, null);
    }
    // An unusable candidate (LibreSSL, OpenSSL 1.x) is passed over and
    // reported if nothing later on the list qualifies.
    seen.add('$candidate: ${version.isEmpty ? 'no version' : version}');
  }
  return (
    null,
    'needs the OpenSSL 3+ CLI for its TLS fixtures (set ANJ_TEST_OPENSSL); '
        'found ${seen.isEmpty ? 'none' : seen.join('; ')}',
  );
}
