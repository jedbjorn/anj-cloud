import 'dart:convert';
import 'dart:io';

import '../../core/ports/autostart.dart';

/// Runs the installed manager's `autostart` command. Only manager-launched
/// builds know the stable command; the manager is the only writer of the
/// autostart file. The Linux [AutostartControl].
class ManagerAutostart implements AutostartControl {
  ManagerAutostart(this.command, {this.timeout = const Duration(seconds: 30)});
  final String command;
  final Duration timeout;

  Future<AutostartState> _run(String action) async {
    final result = await Process.run(command, [
      'autostart',
      action,
    ]).timeout(timeout);
    if (result.exitCode != 0) {
      final error = '${result.stderr}'.trim();
      throw ProcessException(
        command,
        ['autostart', action],
        error,
        result.exitCode,
      );
    }
    return AutostartState.fromJson(
      jsonDecode('${result.stdout}') as Map<String, dynamic>,
    );
  }

  @override
  Future<AutostartState> status() => _run('status');
  @override
  Future<AutostartState> set(bool enabled) =>
      _run(enabled ? 'enable' : 'disable');
}
