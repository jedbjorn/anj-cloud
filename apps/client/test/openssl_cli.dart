import 'dart:io';

import 'test_platform.dart';

/// The OpenSSL CLI for test fixtures and reference comparisons only; client
/// code never runs it (`no_openssl_cli_test.dart`). That test reruns the
/// identity, pairing and renewal suites with /usr/bin/openssl (and any
/// `openssl` on PATH) replaced by a recorder, and points ANJ_TEST_OPENSSL at
/// the real binary so only fixture calls reach it.
///
/// The binary is `test_platform.dart`'s [testOpenssl], the one resolver every
/// TLS fixture uses: ANJ_TEST_OPENSSL when set, otherwise the seat's OpenSSL
/// 3+ CLI (macOS skips LibreSSL). Where none qualifies, using this fails with
/// the same reason [opensslSkip] gives.
final String opensslExecutable =
    testOpenssl ??
    (throw StateError(
      'The test fixtures need the OpenSSL 3+ CLI (set ANJ_TEST_OPENSSL): '
      '$opensslSkip',
    ));

Future<List<int>> openssl(List<String> args, [List<int>? input]) async {
  final process = await Process.start(opensslExecutable, args);
  final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
  final err = process.stderr.fold<List<int>>([], (a, b) => a..addAll(b));
  if (input != null) process.stdin.add(input);
  await process.stdin.close();
  final code = await process.exitCode;
  final bytes = await out;
  await err;
  if (code != 0) throw StateError('openssl ${args.first} failed ($code).');
  return bytes;
}
