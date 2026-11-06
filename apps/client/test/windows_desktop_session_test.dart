import 'dart:async';

import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/windows/dpapi_secrets.dart';
import 'package:anj_cloud/platform/windows/windows_desktop_session.dart';
import 'package:anj_cloud/platform/desktop/channel_tray.dart';
import 'package:anj_cloud/platform/windows/windows_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spec #32 W3: the Dart side of the Windows desktop session against a
/// faked runner (the `cloud.anj/window` and `cloud.anj/tray` channels).
/// Runs everywhere; the runner itself is checked on W10C-Testing
/// (tool/windows/session_test.ps1).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  final calls = <String, List<MethodCall>>{};

  void fakeRunner(String channel, Object? Function(MethodCall call) answer) {
    calls[channel] = [];
    messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
      calls[channel]!.add(call);
      return answer(call);
    });
  }

  /// A runner -> Dart call on [channel]; completes with Dart's reply.
  Future<void> fromRunner(String channel, String method, [Object? arguments]) {
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
      channel,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => reply.complete(),
    );
    return reply.future;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('cloud.anj/window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('cloud.anj/tray'),
      null,
    );
  });

  test('the tray adds the icon, mirrors state and relays the menu', () async {
    fakeRunner(
      'cloud.anj/tray',
      (call) => call.method == 'start' ? true : null,
    );
    final events = <String>[];
    final tray = ChannelTray(
      onOpen: () => events.add('open'),
      onTogglePause: () => events.add('pause'),
      onQuit: () => events.add('quit'),
    );
    expect(await tray.start(), isTrue);
    expect(tray.hostAvailable, isTrue);
    await tray.setState(SyncStatus.syncing, paused: true);
    expect(calls['cloud.anj/tray']!.last.arguments, {
      'status': 'AnJ Cloud: Syncing',
      'paused': true,
    });
    for (final method in ['open', 'togglePause', 'quit']) {
      await fromRunner('cloud.anj/tray', method);
    }
    expect(events, ['open', 'pause', 'quit']);
    final hosts = <bool>[];
    final listening = tray.hostChanges.listen(hosts.add);
    await fromRunner('cloud.anj/tray', 'hostChanged', false);
    expect(tray.hostAvailable, isFalse);
    await fromRunner('cloud.anj/tray', 'hostChanged', true);
    expect(tray.hostAvailable, isTrue);
    await pumpEventQueue();
    expect(hosts, [false, true]);
    await listening.cancel();
    await tray.close();
    expect(tray.hostAvailable, isFalse);
    expect(calls['cloud.anj/tray']!.last.method, 'close');
    // Closed: later runner events do nothing.
    await fromRunner('cloud.anj/tray', 'quit');
    expect(events, ['open', 'pause', 'quit']);
  });

  test('the window shows, hides and relays activation', () async {
    fakeRunner('cloud.anj/window', (call) => call.method == 'activateExisting');
    final window = WindowsWindow();
    await window.show();
    await window.hide();
    expect(calls['cloud.anj/window']!.map((c) => c.method), ['show', 'hide']);
    var activated = 0;
    window.onActivate = () => activated++;
    await fromRunner('cloud.anj/window', 'activate');
    expect(activated, 1);
    expect(await window.activateExisting(r'C:\p'), isTrue);
    expect(calls['cloud.anj/window']!.last.arguments, {'profile': r'C:\p'});
  });

  test(
    'session end runs Quit and replies only once sync has stopped',
    () async {
      fakeRunner('cloud.anj/window', (_) => null);
      var exited = false;
      exitProcess = (_) => exited = true;
      addTearDown(() => exitProcess = (_) {});
      final window = WindowsWindow(fallback: Duration.zero);
      final stopped = Completer<void>();
      window.onSessionEnd = () async {
        await stopped.future; // the worker stopping
        await window.exit(); // the lifecycle's last step
      };
      var replied = false;
      final reply = fromRunner(
        'cloud.anj/window',
        'endSession',
      ).then((_) => replied = true);
      await pumpEventQueue();
      expect(replied, isFalse);
      stopped.complete();
      await reply;
      expect(replied, isTrue);
      // Windows ends the process; the app itself did not exit or close windows.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(exited, isFalse);
    },
  );

  test('a stuck stop does not hold session end past its limit', () async {
    fakeRunner('cloud.anj/window', (_) => null);
    final window = WindowsWindow(
      sessionEndLimit: const Duration(milliseconds: 50),
    )..onSessionEnd = () {};
    await fromRunner('cloud.anj/window', 'endSession');
    expect(window.onSessionEnd, isNotNull);
  });

  test('the session claims activation only with a tray', () async {
    fakeRunner(
      'cloud.anj/tray',
      (call) => call.method == 'start' ? true : null,
    );
    fakeRunner('cloud.anj/window', (call) => call.method == 'claimActivation');
    final session = WindowsDesktopSession();
    final quits = <int>[];
    final tray = await session.startTray(
      onOpen: () {},
      onTogglePause: () {},
      onQuit: () => quits.add(1),
    );
    expect(tray, isNotNull);
    await session.claimActivation(r'C:\profile', () {});
    expect(calls['cloud.anj/window']!.single.method, 'claimActivation');
    // Session end takes the tray's Quit path.
    (session.window() as WindowsWindow).onSessionEnd!();
    expect(quits, [1]);
  });

  test(
    'without the runner channel there is no tray (Close then quits)',
    () async {
      final session = WindowsDesktopSession();
      expect(
        await session.startTray(
          onOpen: () {},
          onTogglePause: () {},
          onQuit: () {},
        ),
        isNull,
      );
      await session.claimActivation(r'C:\profile', () {});
    },
  );

  test('secret files are named by a hash, never by the key', () {
    final secrets = DpapiSecrets(directory: r'C:\x\secrets');
    final name = secrets.fileOf('anj-cloud:abc:device-key').path;
    expect(name, isNot(contains('device-key')));
    expect(name, matches(RegExp(r'[0-9a-f]{64}\.dpapi$')));
    expect(secrets.fileOf('a').path, isNot(secrets.fileOf('b').path));
  });
}
