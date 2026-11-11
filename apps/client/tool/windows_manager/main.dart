/// anj-cloud-manager.exe (spec #32 W5): `dart compile exe
/// tool/windows_manager/main.dart` from the pinned SDK. Commands (JSON on
/// stdout, errors on stderr with exit 1), mirroring tool/linux_install.py:
///
///   install `<zip>` --sha256 `<hex>`    first install (or the same as update)
///   update `<zip>` --sha256 `<hex>`     refuses while AnJ Cloud runs
///   run [--background]              start the active release
///   status
///   apply-update `<archive>` --manifest `<file>` [--check | --result `<file>`
///                [--app-pid `<process id>`]]
///                                   the app's in-app update: verify the
///                                   signed download,
///                                   wait for the app to quit, install, start
///                                   it again
///   autostart enable|disable|status
///   uninstall                       exactly what install added
///
/// Obtain this manager from the release you are verifying with an
/// independently supplied SHA-256: an archive checksum cannot vouch for the
/// program that checks it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'manager.dart';
import 'windows_host.dart';

void main(List<String> arguments) {
  runZonedGuarded(() async => exit(await _main(arguments)), (error, stack) {
    // A late failure of a standard stream is not the command's failure.
    if (error is StdoutException) return;
    _say(stderr, 'anj-cloud-manager: unexpected failure: $error\n$stack');
    exit(255);
  });
}

/// Runs the command and prints its answer; returns the exit code.
Future<int> _main(List<String> arguments) async {
  try {
    final result = await _dispatch(arguments);
    await _say(stdout, const JsonEncoder.withIndent('  ').convert(result));
    // apply-update answers a refused hand-over as an outcome, not an error.
    return result is Map && result['ok'] == false ? 1 : 0;
  } on Refused catch (error) {
    await _say(stderr, 'anj-cloud-manager: $error');
    return 1;
  } on FileSystemException catch (error) {
    await _say(stderr, 'anj-cloud-manager: $error');
    return 1;
  }
}

/// Prints when there is somewhere to print. The app starts apply-update
/// detached, with no console and no standard handles: printing fails there,
/// after the work is done and its outcome is in the result file, and must
/// not turn the exit code into a crash's.
Future<void> _say(IOSink sink, String text) async {
  try {
    sink.writeln(text);
    await sink.flush();
  } on Object {
    // Nowhere to print.
  }
}

Future<Object?> _dispatch(List<String> arguments) async {
  final manager = Manager(WindowsHost());
  manager.sweep();
  String? option(String name) {
    final at = arguments.indexOf(name);
    return at >= 0 && at + 1 < arguments.length ? arguments[at + 1] : null;
  }

  final command = arguments.isEmpty ? '' : arguments.first;
  switch (command) {
    case 'install' || 'update':
      final sha = option('--sha256');
      if (arguments.length < 2 || sha == null) {
        throw Refused('Usage: $command <archive.zip> --sha256 <hex>');
      }
      return manager.install(arguments[1], sha, update: command == 'update');
    case 'run':
      return manager.run(background: arguments.contains('--background'));
    case 'status':
      return manager.status();
    case 'apply-update':
      final manifest = option('--manifest');
      if (arguments.length < 2 || manifest == null) {
        throw Refused(
          'Usage: apply-update <archive> --manifest <file> '
          '[--check | --result <file> [--app-pid <process id>]]',
        );
      }
      final appPid = option('--app-pid');
      if (appPid != null && (int.tryParse(appPid) ?? 0) <= 0) {
        throw Refused('--app-pid must be a process id.');
      }
      return manager.applyUpdate(
        arguments[1],
        manifest,
        result: option('--result'),
        check: arguments.contains('--check'),
        appPid: appPid == null ? null : int.parse(appPid),
      );
    case 'autostart':
      final action = arguments.length > 1 ? arguments[1] : '';
      if (!const {'enable', 'disable', 'status'}.contains(action)) {
        throw Refused('Usage: autostart enable|disable|status');
      }
      return manager.autostart(action);
    case 'uninstall':
      return _uninstall(manager, arguments);
  }
  throw Refused(
    'Commands: install|update <zip> --sha256 <hex>, run [--background], status, '
    'apply-update <archive> --manifest <file> [--check | --result <file>], '
    'autostart enable|disable|status, uninstall',
  );
}

/// A running program cannot delete its own file, nor a DLL it loaded, so an
/// uninstall started from inside the installation copies the manager and
/// anj_rootfs.dll to a private temporary directory and continues there once
/// this process has ended. The copy leaves its outcome in
/// %LOCALAPPDATA%\anj-cloud\logs\uninstall.json.
Future<Object?> _uninstall(Manager manager, List<String> arguments) async {
  final self = Platform.resolvedExecutable;
  final waitFor = arguments.indexOf('--after');
  if (waitFor >= 0) {
    final parent = waitFor + 1 < arguments.length
        ? int.tryParse(arguments[waitFor + 1])
        : null;
    if (parent == null || parent <= 0) {
      throw Refused('Usage: uninstall [--after <process id>]');
    }
    final logs = Directory(p.join(manager.layout.local, 'anj-cloud', 'logs'))
      ..createSync(recursive: true);
    final outcome = File(p.join(logs.path, 'uninstall.json'));
    // The continuation runs detached: its outcome, success or failure, is
    // this file.
    try {
      waitForProcess(parent);
      final result = await manager.uninstall(
        library: p.join(p.dirname(self), 'anj_rootfs.dll'),
      );
      outcome.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(result),
      );
      return result;
    } on Object catch (error) {
      outcome.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({'error': '$error'}),
      );
      rethrow;
    }
  }
  if (!p.isWithin(manager.layout.base, self)) {
    return manager.uninstall(
      library: p.join(p.dirname(self), 'anj_rootfs.dll'),
    );
  }
  // Checks first, in place: not elevated, not running.
  final state = manager.activeState();
  if (manager.host.elevated) {
    throw Refused(
      'Run the manager as your normal Windows user, not as administrator.',
    );
  }
  if (state != null) {
    manager.host.withProfileLock(
      state['profile']! as String,
      p.join(p.dirname(self), 'anj_rootfs.dll'),
      () => null,
    );
  }
  final temporary = Directory.systemTemp.createTempSync('anj-cloud-uninstall-');
  final copy = p.join(temporary.path, 'anj-cloud-manager.exe');
  File(self).copySync(copy);
  File(p.join(p.dirname(self), 'anj_rootfs.dll'))
      .copySync(p.join(temporary.path, 'anj_rootfs.dll'));
  await Process.start(
    copy,
    ['uninstall', '--after', '$pid'],
    workingDirectory: temporary.path,
    mode: ProcessStartMode.detached,
  );
  return {
    'uninstalling': true,
    'result': p.join(
      manager.layout.local,
      'anj-cloud',
      'logs',
      'uninstall.json',
    ),
  };
}
