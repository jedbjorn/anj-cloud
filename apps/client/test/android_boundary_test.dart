// Spec #28 Native Boundary, decision #123: the Android build of the anj_*
// boundary never calls openat2 or linkat, and refuses exactly what the Linux
// build refuses. Runs on Linux: the Android variant is the same source built
// for the host with -DANJ_ANDROID_BOUNDARY, run under a seccomp filter that
// treats openat2 and linkat as Android's app sandbox does (A1: SIGSYS and
// EACCES). test/native/boundary_parity.cc holds the cases.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory work;
  late String harness;
  late String linuxLibrary;
  late String androidLibrary;

  Future<void> compile(List<String> arguments) async {
    final result = await Process.run('clang++', [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-O2',
      ...arguments,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('anj-boundary-parity-');
    harness = '${work.path}/parity';
    linuxLibrary = '${work.path}/linux.so';
    androidLibrary = '${work.path}/android.so';
    await compile(['test/native/boundary_parity.cc', '-ldl', '-o', harness]);
    await compile([
      '-fPIC',
      '-shared',
      'native/posix/rootfs.cc',
      '-o',
      linuxLibrary,
    ]);
    await compile([
      '-fPIC',
      '-shared',
      '-DANJ_ANDROID_BOUNDARY',
      'native/posix/rootfs.cc',
      '-o',
      androidLibrary,
    ]);
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  Future<ProcessResult> run(String library, {required bool sandbox}) {
    final fixture = work.createTempSync('fx-');
    return Process.run(harness, [
      library,
      fixture.path,
      if (sandbox) '--android-sandbox',
    ]);
  }

  List<String> lines(ProcessResult result) =>
      (result.stdout as String).trimRight().split('\n');

  test('the Linux build is killed by the Android sandbox filter', () async {
    // Control: the filter is real, so a pass below means the Android build
    // never reached openat2.
    final result = await run(linuxLibrary, sandbox: true);
    expect(result.exitCode, -ProcessSignal.sigsys.signalNumber);
  });

  test(
    'Android build: every case passes in the sandbox, refusals equal Linux',
    () async {
      final linux = await run(linuxLibrary, sandbox: false);
      final android = await run(androidLibrary, sandbox: true);
      expect(linux.exitCode, 0, reason: '${linux.stderr}');
      expect(android.exitCode, 0, reason: '${android.stderr}');
      final a = lines(linux);
      final b = lines(android);
      expect(a.last, 'done');
      expect(a.length, greaterThan(70));
      // The install mechanism is the one intended difference: Linux links the
      // staged file (two names, one inode), Android installs a copy.
      expect(a.where((l) => l.startsWith('MECHANISM')), ['MECHANISM links=2']);
      expect(b.where((l) => l.startsWith('MECHANISM')), ['MECHANISM links=1']);
      bool same(String l) => !l.startsWith('MECHANISM');
      expect(b.where(same).toList(), a.where(same).toList());
      // No temporary install copy is left in staging.
      expect(
        b.singleWhere((l) => l.startsWith('staging:')),
        isNot(contains('.anj-install')),
      );
    },
  );
}
