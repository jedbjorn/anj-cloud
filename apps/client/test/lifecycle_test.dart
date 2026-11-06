import 'dart:async';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/platform/linux/desktop_bus.dart';
import 'package:anj_cloud/core/app/lifecycle.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/ports/desktop_session.dart';
import 'package:anj_cloud/core/ports/autostart.dart';
import 'package:anj_cloud/platform/linux/manager_autostart.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dbus_harness.dart';
import 'fakes.dart';
import 'test_platform.dart';

class FakeWindow implements WindowControl {
  final calls = <String>[];
  @override
  Future<void> show() async => calls.add('show');
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  Future<void> exit() async => calls.add('exit');
}

class FakeAutostart extends ManagerAutostart {
  FakeAutostart() : super('/nonexistent/anj-cloud');
  @override
  Future<AutostartState> status() async =>
      const AutostartState(enabled: true, source: 'default');
}

class FakeTray implements TrayControl {
  FakeTray({bool host = true}) : hostAvailable = host;
  @override
  bool hostAvailable;
  bool closed = false;
  final _changes = StreamController<bool>.broadcast();
  final states = <(SyncStatus, bool)>[];

  void setHost(bool value) {
    hostAvailable = value;
    _changes.add(value);
  }

  @override
  Stream<bool> get hostChanges => _changes.stream;
  @override
  Future<void> setState(SyncStatus status, {required bool paused}) async =>
      states.add((status, paused));
  @override
  Future<void> close() async => closed = true;
}

class _FailingTray extends FakeTray {
  @override
  Future<void> close() async => throw StateError('tray channel gone');
}

/// Spec #16 "Close/hide/no-host" and "Login start" (Dart side; the runner
/// only shows/hides on request and forwards close as System.requestAppExit).
void main() {
  late Directory profile;
  late FakeWindow window;
  late List<String> events;

  setUp(() {
    profile = Directory.systemTemp.createTempSync('anj-lifecycle-');
    window = FakeWindow();
    events = [];
  });
  tearDown(() => profile.deleteSync(recursive: true));

  DesktopLifecycle lifecycle({
    TrayControl? tray,
    bool background = false,
    Duration trayWait = const Duration(milliseconds: 300),
  }) => DesktopLifecycle(
    window: window,
    tray: tray,
    stopSync: () async {
      events.add('stop');
      return true;
    },
    onShown: () => events.add('shown'),
    notices: LifecycleNotices(profile)..load(),
    background: background,
    trayWait: trayWait,
  );

  test('close with a tray host hides; sync keeps running', () async {
    final tray = FakeTray();
    final subject = lifecycle(tray: tray);
    await subject.start();
    await subject.closeRequested();
    expect(window.calls, ['hide']);
    expect(subject.visible, isFalse);
    expect(events, ['shown'], reason: 'no stop on hide');
    await subject.open();
    expect(window.calls, ['hide', 'show']);
    expect(events, ['shown', 'shown'], reason: 'showing asks for a pass');
  });

  test('close without a host quits cleanly after a one-time notice', () async {
    final subject = lifecycle(tray: FakeTray(host: false));
    var notices = 0;
    var answer = false;
    subject.confirmQuitWithoutTray = () async {
      notices++;
      return answer;
    };
    await subject.start();
    await subject.closeRequested();
    expect(notices, 1);
    expect(window.calls, isEmpty, reason: 'Keep open');
    expect(events, isNot(contains('stop')));
    answer = true;
    await subject.closeRequested();
    expect(notices, 2);
    expect(events.last, 'stop');
    expect(window.calls, ['exit']);
    // Confirmed once: later closes quit without asking again.
    final again = lifecycle(tray: null);
    again.confirmQuitWithoutTray = () async {
      notices++;
      return false;
    };
    await again.start();
    await again.closeRequested();
    expect(notices, 2);
    expect(window.calls, ['exit', 'exit']);
  });

  test('a host lost while hidden shows the window again', () async {
    final tray = FakeTray();
    final subject = lifecycle(tray: tray);
    await subject.start();
    await subject.closeRequested();
    expect(subject.visible, isFalse);
    tray.setHost(false);
    await eventually(() => subject.visible);
    expect(window.calls, ['hide', 'show']);
    expect(subject.note, contains('no longer available'));
    // Now visible without a host: Close quits (never invisible).
    subject.confirmQuitWithoutTray = () async => true;
    await subject.closeRequested();
    expect(window.calls.last, 'exit');
    expect(events.last, 'stop');
  });

  test(
    'quit stops sync before exiting, closes the tray, is idempotent',
    () async {
      final tray = FakeTray();
      final order = <String>[];
      final subject = DesktopLifecycle(
        window: window,
        tray: tray,
        stopSync: () async {
          order.add('stop');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          order.add('stopped');
          return true;
        },
      );
      await subject.start();
      final first = subject.quit();
      final second = subject.quit();
      await Future.wait([first, second]);
      expect(order, ['stop', 'stopped']);
      expect(tray.closed, isTrue);
      expect(window.calls, ['exit']);
      // Close and Open after Quit do nothing.
      await subject.closeRequested();
      await subject.open();
      expect(window.calls, ['exit']);
    },
  );

  test('a tray that fails to close still exits', () async {
    final subject = DesktopLifecycle(
      window: window,
      stopSync: () async => true,
      tray: _FailingTray(),
    );
    await subject.quit();
    expect(window.calls, ['exit']);
  });

  test('a failing stop still exits (the kernel releases the locks)', () async {
    final subject = DesktopLifecycle(
      window: window,
      stopSync: () async => throw StateError('worker gone'),
    );
    await expectLater(subject.quit(), throwsStateError);
    expect(window.calls, ['exit']);
  });

  test(
    'a second Close while the no-tray notice is open does not stack it',
    () async {
      final subject = lifecycle(tray: FakeTray(host: false));
      var asked = 0;
      final answer = Completer<bool>();
      subject.confirmQuitWithoutTray = () {
        asked++;
        return answer.future;
      };
      await subject.start();
      final first = subject.closeRequested();
      final second = subject.closeRequested();
      answer.complete(true);
      await Future.wait([first, second]);
      expect(asked, 1);
      expect(window.calls, ['exit']);
    },
  );

  group('login start (--background)', () {
    test('host already present: stays hidden in the tray', () async {
      final subject = lifecycle(tray: FakeTray(), background: true);
      await subject.start();
      expect(subject.visible, isFalse);
      expect(window.calls, isEmpty);
      expect(subject.note, isNull);
    });

    test('host appears within the bounded wait: stays hidden', () async {
      final tray = FakeTray(host: false);
      final subject = lifecycle(
        tray: tray,
        background: true,
        trayWait: const Duration(seconds: 5),
      );
      final started = subject.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      tray.setHost(true);
      await started;
      expect(window.calls, isEmpty);
      expect(subject.visible, isFalse);
    });

    test('no host within the wait: starts visible with a note', () async {
      final watch = Stopwatch()..start();
      final subject = lifecycle(
        tray: FakeTray(host: false),
        background: true,
        trayWait: const Duration(milliseconds: 200),
      );
      await subject.start();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(190));
      expect(window.calls, ['show']);
      expect(subject.visible, isTrue);
      expect(subject.note, contains('No system tray'));
    });

    test('on macOS the notes say menu bar (spec #31)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final tray = FakeTray(host: false);
        final subject = lifecycle(
          tray: tray,
          background: true,
          trayWait: const Duration(milliseconds: 50),
        );
        await subject.start();
        expect(subject.note, startsWith('No menu bar was found'));
        expect(desktopTrayName, 'menu bar');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // Independent review PR #24: a Quit (SIGTERM at logout) during the
    // bounded tray wait must never show the window afterwards.
    test('quit during background tray wait never shows the window', () async {
      final subject = lifecycle(
        tray: FakeTray(host: false),
        background: true,
        trayWait: const Duration(milliseconds: 300),
      );
      final started = subject.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subject.quit();
      await started;
      expect(window.calls.where((c) => c == 'show'), isEmpty);
      expect(window.calls, ['exit']);
    });

    test('no session bus (no tray at all): starts visible at once', () async {
      final subject = lifecycle(tray: null, background: true);
      await subject.start();
      expect(window.calls, ['show']);
    });
  });

  testWidgets('login-start announcement waits for the first visible window', (
    tester,
  ) async {
    final notices = LifecycleNotices(profile)..load();
    final subject = DesktopLifecycle(
      window: window,
      tray: FakeTray(),
      stopSync: () async => true,
      notices: notices,
      background: true,
    );
    await subject.start();
    expect(subject.visible, isFalse);
    final controller = ClientController(
      Directory('${profile.path}/client'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    await tester.pumpWidget(
      CloudApp(
        controller: controller,
        lifecycle: subject,
        notices: notices,
        autostart: FakeAutostart(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('starts when you log in'), findsNothing);
    expect(notices['autostartAnnounced'], isFalse, reason: 'not seen yet');
    await subject.open();
    await tester.pumpAndSettle();
    expect(find.textContaining('starts when you log in'), findsOneWidget);
    // The toggle lives in the window's overflow menu, not the tray menu.
    expect(
      find.textContaining(
        'open the ⋮ menu at the top right of this window and clear Start at login',
      ),
      findsOneWidget,
    );
    expect(notices['autostartAnnounced'], isTrue);
  });

  test('real tray on a private bus: hide, host crash reshows', () async {
    final bus = await PrivateBus.start();
    final (watcherClient, _) = await FakeWatcher.start(bus);
    final trayClient = bus.client();
    late DesktopLifecycle subject;
    final tray = StatusNotifierTray(
      trayClient,
      onOpen: () => unawaited(subject.open()),
      onTogglePause: () {},
      onQuit: () => unawaited(subject.quit()),
    );
    try {
      await tray.start();
      subject = lifecycle(tray: tray, background: true);
      await subject.start();
      expect(subject.visible, isFalse, reason: 'login start, host present');
      // Tray "Open" through dbusmenu.
      final host = bus.client();
      await host.callMethod(
        destination: tray.serviceName,
        path: DBusObjectPath(menuPath),
        interface: menuInterface,
        name: 'Event',
        values: [
          const DBusInt32(3),
          const DBusString('clicked'),
          DBusVariant(const DBusString('')),
          const DBusUint32(0),
        ],
      );
      await eventually(() => subject.visible);
      await subject.closeRequested();
      expect(subject.visible, isFalse);
      await watcherClient.close();
      await eventually(() => subject.visible);
      expect(window.calls, ['show', 'hide', 'show']);
      await host.close();
    } finally {
      await tray.close();
      await trayClient.close();
      await bus.stop();
    }
  }, skip: linuxOnly('a private dbus-daemon and the freedesktop tray'));
}
