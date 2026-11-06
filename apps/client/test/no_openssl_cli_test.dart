import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'source_scan.dart';

/// Spec #28 U1: no client code path runs the OpenSSL CLI (Android and Windows
/// have none; macOS ships LibreSSL).
///
/// * Static: client code in every platform root (comments stripped by a
///   scanner that respects string literals) never names openssl, and starts
///   processes only at the exact allowlisted call sites.
/// * Runtime: the identity, pairing and renewal suites rerun in a mount
///   namespace where /usr/bin/openssl, and any `openssl` on PATH, only records
///   that it was called. Their fixtures reach the real binary through
///   ANJ_TEST_OPENSSL; client code has no way to it.
void main() {
  const roots = [
    'lib',
    'native',
    'linux',
    'android',
    'windows',
    'macos',
    'ios',
  ];
  const skipped = {'ephemeral', 'build', '.gradle', 'Pods', '.dart_tool'};
  // Native test programs, never built into a shipped library (main's S2 and
  // Windows W2 boundary tests fork or spawn to hold a descriptor from a
  // second process). Exact paths, so a future lib/**/test/ is still scanned.
  const skippedPaths = {'native/posix/test/', 'native/windows/test/'};

  test('client sources never name the OpenSSL CLI or launch processes', () {
    final problems = <String>[];
    var scanned = 0;
    for (final root in roots.where((r) => Directory(r).existsSync())) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File ||
            entity.uri.pathSegments.any(skipped.contains) ||
            skippedPaths.any(entity.path.startsWith) ||
            sourceKind(entity.path) == null) {
          continue;
        }
        scanned++;
        problems.addAll(scanSource(entity.path, entity.readAsStringSync()));
      }
    }
    for (final path in processCallSites.keys) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(scanned, greaterThan(50));
    expect(problems, isEmpty);
  });

  group('scanner', () {
    test('only native/<os>/test harnesses are skipped', () {
      expect(
        skippedPaths.any('native/posix/test/boundary_test.cc'.startsWith),
        isTrue,
      );
      expect(
        skippedPaths.any('native/windows/test/rootfs_win_test.cc'.startsWith),
        isTrue,
      );
      for (final path in [
        'native/posix/rootfs.cc',
        'native/posix/sub/test/x.cc',
        'lib/test/x.dart',
        'macos/Runner/test/x.swift',
        'windows/runner/test/x.cpp',
      ]) {
        expect(skippedPaths.any(path.startsWith), isFalse, reason: path);
      }
    });

    const allowlisted = 'lib/platform/linux/manager_autostart.dart';
    final autostart = File(allowlisted).readAsStringSync();

    test('a second launch in an allowlisted file is caught', () {
      expect(scanSource(allowlisted, autostart), isEmpty);
      // The independent review's bypass (PR #50).
      final bypass =
          "$autostart\nFuture<void> anjProbe() => "
          "Process.run(['open','ssl'].join(), ['version']);\n";
      expect(scanSource(allowlisted, bypass), isNotEmpty);
      final tearOff = '$autostart\nfinal launch = Process.start;\n';
      expect(scanSource(allowlisted, tearOff), isNotEmpty);
      // Moving the pinned call elsewhere is caught too.
      expect(
        scanSource('lib/core/gateway/identity.dart', autostart),
        isNotEmpty,
      );
    });

    test('a // or # inside a string does not hide the code after it', () {
      expect(
        scanSource(
          'lib/x.dart',
          "final u = 'https://h/'; final o = '/usr/bin/openssl';",
        ),
        isNotEmpty,
      );
      expect(
        scanSource(
          'lib/x.dart',
          r"final u = '${'//'}' + r'//' + '''a // b'''; run('openssl');",
        ),
        isNotEmpty,
      );
      expect(
        scanSource(
          'native/x.cc',
          'const char* u = "a//b"; const char* c = "openssl";',
        ),
        isNotEmpty,
      );
      expect(
        scanSource(
          'linux/CMakeLists.txt',
          'set(U "a#b") find_program(openssl)',
        ),
        isNotEmpty,
      );
      // Comments themselves may explain what was replaced.
      expect(
        scanSource(
          'lib/x.dart',
          '// openssl\n/* openssl /* nested */ openssl */\nfinal x = 1;',
        ),
        isEmpty,
      );
    });

    test('native and platform-runner process launches are caught', () {
      for (final (path, line) in [
        ('native/x.cc', 'int r = system("ls");'),
        ('native/x.cc', 'posix_spawn(&pid, p, 0, 0, a, e);'),
        ('windows/runner/x.cpp', 'CreateProcessW(nullptr, cmd, 0, 0, 0, 0);'),
        ('android/app/src/x.kt', 'ProcessBuilder("sh").start()'),
        ('android/app/src/X.java', 'Runtime.getRuntime().exec("sh");'),
        ('macos/Runner/x.swift', 'let p = Process()'),
        ('lib/x.dart', "lookup<NativeFunction<F>>('posix_spawn');"),
      ]) {
        expect(scanSource(path, line), isNotEmpty, reason: line);
      }
    });
  });

  test(
    'identity, pairing and renewal suites pass with OpenSSL unavailable',
    () async {
      final dir = Directory.systemTemp.createTempSync('anj-no-openssl-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final marker = File('${dir.path}/openssl-called');
      final fakeDir = Directory('${dir.path}/bin')..createSync();
      final fake = File('${fakeDir.path}/openssl')
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$*" >> "${marker.path}"\nexit 1\n',
        );
      await Process.run('chmod', ['755', fake.path]);
      // Inside the namespace this file shows the real binary; outside it is
      // an empty placeholder.
      final real = File('${dir.path}/real-openssl')..writeAsStringSync('');
      final flutter =
          '${Platform.environment['FLUTTER_SDK'] ?? '${Platform.environment['HOME']}/.local/share/anj-cloud/toolchains/flutter-3.47.9'}/bin/flutter';

      Future<ProcessResult> masked(List<String> command) => Process.run(
        'unshare',
        [
          '--map-root-user',
          '--mount',
          'sh',
          '-c',
          r'mount --bind /usr/bin/openssl "$0" && '
              r'mount --bind "$1" /usr/bin/openssl && shift && exec "$@"',
          real.path,
          fake.path,
          ...command,
        ],
        environment: {
          'PATH': '${fakeDir.path}:${Platform.environment['PATH']}',
          'ANJ_TEST_OPENSSL': real.path,
        },
      );

      // The harness itself: /usr/bin/openssl and PATH only leave the marker,
      // while the fixtures' path reaches the real binary.
      final probe = await masked([
        'sh',
        '-c',
        r'/usr/bin/openssl version; openssl version; "$ANJ_TEST_OPENSSL" version',
      ]);
      expect(probe.stdout, contains('OpenSSL 3'), reason: '${probe.stderr}');
      expect(marker.readAsLinesSync(), ['version', 'version']);
      marker.deleteSync();

      final suites = [
        'test/identity_test.dart',
        'test/pairing_flow_test.dart',
        'test/certificate_renewal_test.dart',
        'test/dav_test.dart',
        'test/device_crypto_test.dart',
      ];
      final run = await masked([
        flutter,
        '--suppress-analytics',
        'test',
        '--concurrency=1',
        ...suites,
      ]);
      expect(
        run.exitCode,
        0,
        reason: '${run.stdout}'.split('\n').reversed.take(40).join('\n'),
      );
      expect(run.stdout, contains('All tests passed!'));
      expect(
        marker.existsSync() ? marker.readAsStringSync() : null,
        isNull,
        reason: 'client code ran openssl',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
    // A private mount namespace (unshare --map-root-user --mount) hides
    // the real binaries; macOS and Windows have no such namespace.
    skip: Platform.isLinux
        ? false
        : 'Linux only: masks openssl with unshare mount namespaces',
  );
}
