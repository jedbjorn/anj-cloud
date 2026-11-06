/// Port: start at login, an installer/manager hook (decision #74).
///
/// Linux: `ManagerAutostart` (lib/platform/linux/manager_autostart.dart) runs
/// the installed manager's `autostart` command (tool/linux_install.py), the
/// only writer of the XDG autostart entry.
library;

/// Start-at-login state as reported by the installed manager.
class AutostartState {
  const AutostartState({required this.enabled, this.source, this.problem});
  final bool enabled;

  /// 'default' when enabled by an install or update, 'user' after a toggle.
  final String? source;

  /// Why the entry could not be written (a foreign file at the path).
  final String? problem;

  factory AutostartState.fromJson(Map<String, dynamic> json) => AutostartState(
    enabled: json['enabled'] == true,
    source: json['source'] as String?,
    problem: json['problem'] as String?,
  );
}

abstract interface class AutostartControl {
  Future<AutostartState> status();
  Future<AutostartState> set(bool enabled);
}
