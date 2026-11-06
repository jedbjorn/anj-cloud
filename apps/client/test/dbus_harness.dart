import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// A private `dbus-daemon` session bus for tests: never the user's session
/// bus, and without service directories, so no desktop service can be
/// auto-started on it.
class PrivateBus {
  PrivateBus._(this._process, this.address, this._directory);
  final Process _process;
  final String address;
  final Directory _directory;

  static Future<PrivateBus> start() async {
    final directory = Directory.systemTemp.createTempSync('anj-dbus-');
    final config = File('${directory.path}/bus.conf')
      ..writeAsStringSync('''
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir=${directory.path}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
''');
    final process = await Process.start('dbus-daemon', [
      '--config-file=${config.path}',
      '--nofork',
      '--nopidfile',
      '--print-address=1',
    ]);
    final address = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    return PrivateBus._(process, address.trim(), directory);
  }

  DBusClient client() => DBusClient(DBusAddress(address));

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
    _directory.deleteSync(recursive: true);
  }
}

/// Minimal org.kde.StatusNotifierWatcher (what Plasma's kded module or the
/// GNOME AppIndicator extension provide).
class FakeWatcher extends DBusObject {
  FakeWatcher({this.hostRegistered = true})
    : super(DBusObjectPath('/StatusNotifierWatcher'));
  bool hostRegistered;
  final registered = <String>[];
  final _registrations = StreamController<String>.broadcast();
  Stream<String> get registrations => _registrations.stream;

  static const name = 'org.kde.StatusNotifierWatcher';

  static Future<(DBusClient, FakeWatcher)> start(
    PrivateBus bus, {
    bool hostRegistered = true,
  }) async {
    final client = bus.client();
    final watcher = FakeWatcher(hostRegistered: hostRegistered);
    await client.registerObject(watcher);
    await client.requestName(name);
    return (client, watcher);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == name &&
        methodCall.name == 'RegisterStatusNotifierItem') {
      final service = methodCall.values.first.asString();
      registered.add(service);
      _registrations.add(service);
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == FakeWatcher.name &&
        name == 'IsStatusNotifierHostRegistered') {
      return DBusGetPropertyResponse(DBusBoolean(hostRegistered));
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  Future<void> setHost(bool value) async {
    hostRegistered = value;
    await emitSignal(
      name,
      value ? 'StatusNotifierHostRegistered' : 'StatusNotifierHostUnregistered',
    );
  }
}

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
