// The Windows manager's exit code must not depend on whether it can print.
// The app starts `apply-update` detached, with no console and no standard
// handles; on a Windows seat that made every command exit 255 after its work
// was done. The entry point is plain Dart, so the same failure shows on any
// host with standard output and error closed or full.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'test_platform.dart';

void main() {
  final skip = Platform.isWindows
      ? 'closes the standard streams through a POSIX shell'
      : checkoutFile('tool/windows_manager/main.dart');
  // Closed, and (Linux has the device) accepting no byte.
  final unusable = ['>&- 2>&-', if (Platform.isLinux) '>/dev/full 2>/dev/full'];
  late Directory temp;
  late String manager;
  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('anj-manager-cli-');
    if (skip != null) return;
    manager = p.join(temp.path, 'manager');
    final compiled = await Process.run(testDartExecutable, [
      'compile',
      'exe',
      'tool/windows_manager/main.dart',
      '-o',
      manager,
    ]);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  /// The exit code of `manager <command>` with [streams] as its redirection.
  Future<int> run(String command, String streams) async {
    final result = await Process.run(
      '/bin/sh',
      ['-c', '"\$0" $command $streams', manager],
      environment: {
        'LOCALAPPDATA': p.join(temp.path, 'Local'),
        'APPDATA': p.join(temp.path, 'Roaming'),
      },
    );
    return result.exitCode;
  }

  test(
    'a command that succeeds exits 0 with or without somewhere to print',
    () async {
      expect(await run('status', '>/dev/null 2>&1'), 0);
      for (final streams in unusable) {
        expect(await run('status', streams), 0, reason: streams);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a refused command exits 1 with or without somewhere to print',
    () async {
      expect(await run('no-such-command', '>/dev/null 2>&1'), 1);
      for (final streams in unusable) {
        expect(await run('no-such-command', streams), 1, reason: streams);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
