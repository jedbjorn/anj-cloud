import 'dart:io';
import 'dart:typed_data';

import 'package:anj_cloud/platform/linux/desktop_bus.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dbus_harness.dart';
import 'test_platform.dart';

/// Spec #16 "Tray protocol": StatusNotifierItem + dbusmenu over package:dbus,
/// exercised on a private dbus-daemon against a fake watcher/host.
void main() {
  if (skipSuite(
    'StatusNotifierItem tray over D-Bus',
    linuxOnly(
      'a private dbus-daemon and the freedesktop tray; the macOS '
      'menu bar is tested in macos_desktop_session_test.dart and on '
      'mac-test (session_check.sh)',
    ),
  )) {
    return;
  }
  late PrivateBus bus;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    bus = await PrivateBus.start();
  });
  tearDown(() async {
    for (final cleanup in cleanups.reversed) {
      await cleanup();
    }
    cleanups.clear();
    await bus.stop();
  });

  DBusClient client() {
    final value = bus.client();
    cleanups.add(value.close);
    return value;
  }

  Future<(StatusNotifierTray, List<String>)> startTray({
    List<TrayPixmap> pixmaps = const [],
  }) async {
    final actions = <String>[];
    final tray = StatusNotifierTray(
      client(),
      onOpen: () => actions.add('open'),
      onTogglePause: () => actions.add('pause'),
      onQuit: () => actions.add('quit'),
      pixmaps: pixmaps,
    );
    cleanups.add(tray.close);
    await tray.start();
    return (tray, actions);
  }

  Future<DBusValue> itemProperty(
    DBusClient caller,
    StatusNotifierTray tray,
    String name,
  ) async {
    final reply = await caller.callMethod(
      destination: tray.serviceName,
      path: DBusObjectPath(itemPath),
      interface: 'org.freedesktop.DBus.Properties',
      name: 'Get',
      values: [const DBusString(itemInterface), DBusString(name)],
      replySignature: DBusSignature('v'),
    );
    return reply.returnValues.first.asVariant();
  }

  Future<List<DBusValue>> menuCall(
    DBusClient caller,
    StatusNotifierTray tray,
    String name,
    List<DBusValue> values,
  ) async => (await caller.callMethod(
    destination: tray.serviceName,
    path: DBusObjectPath(menuPath),
    interface: menuInterface,
    name: name,
    values: values,
  )).returnValues;

  Map<int, Map<String, DBusValue>> layoutItems(DBusValue layout) {
    final result = <int, Map<String, DBusValue>>{};
    void walk(DBusValue node) {
      final fields = node.asStruct();
      result[fields[0].asInt32()] = fields[1].asStringVariantDict();
      for (final child in fields[2].asVariantArray()) {
        walk(child);
      }
    }

    walk(layout);
    return result;
  }

  test(
    'item registers with the watcher, exposes SNI properties and pixmaps',
    () async {
      final (watcherClient, watcher) = await FakeWatcher.start(bus);
      cleanups.add(watcherClient.close);
      final pixel = Uint8List.fromList(List.filled(22 * 22 * 4, 0x7f));
      final (tray, _) = await startTray(pixmaps: [TrayPixmap(22, pixel)]);
      expect(watcher.registered, [tray.serviceName]);
      expect(tray.serviceName, 'org.kde.StatusNotifierItem-$pid-1');
      expect(tray.hostAvailable, isTrue);
      final host = client();
      expect((await itemProperty(host, tray, 'Id')).asString(), 'anj-cloud');
      expect(
        (await itemProperty(host, tray, 'Category')).asString(),
        'ApplicationStatus',
      );
      expect((await itemProperty(host, tray, 'Status')).asString(), 'Active');
      expect(
        (await itemProperty(host, tray, 'Menu')).asObjectPath().value,
        menuPath,
      );
      expect(
        (await itemProperty(host, tray, 'ItemIsMenu')).asBoolean(),
        isFalse,
      );
      final pixmaps = (await itemProperty(host, tray, 'IconPixmap')).asArray();
      expect(pixmaps, hasLength(1));
      final image = pixmaps.single.asStruct();
      expect(image[0].asInt32(), 22);
      expect(image[2].asByteArray().length, 22 * 22 * 4);
      // Hosts introspect before use.
      final xml = await host.callMethod(
        destination: tray.serviceName,
        path: DBusObjectPath(itemPath),
        interface: 'org.freedesktop.DBus.Introspectable',
        name: 'Introspect',
      );
      expect(xml.returnValues.first.asString(), contains(itemInterface));
    },
  );

  test('menu layout, events and live status updates', () async {
    final (watcherClient, _) = await FakeWatcher.start(bus);
    cleanups.add(watcherClient.close);
    final (tray, actions) = await startTray();
    final host = client();
    final signals = <String>[];
    final subscription = DBusSignalStream(
      host,
      sender: tray.serviceName,
    ).listen((signal) => signals.add(signal.name));
    cleanups.add(subscription.cancel);
    final reply = await menuCall(host, tray, 'GetLayout', [
      const DBusInt32(0),
      const DBusInt32(-1),
      DBusArray.string(const []),
    ]);
    final revision = reply[0].asUint32();
    final items = layoutItems(reply[1]);
    expect(items.keys, [0, 1, 2, 3, 4, 5, 6]);
    expect(items[1]!['label']!.asString(), 'AnJ Cloud: Up to date');
    expect(items[1]!['enabled']!.asBoolean(), isFalse);
    expect(items[2]!['type']!.asString(), 'separator');
    expect(items[3]!['label']!.asString(), 'Open AnJ Cloud');
    expect(items[4]!['label']!.asString(), 'Pause sync');
    expect(items[6]!['label']!.asString(), 'Quit AnJ Cloud');
    // Depth 0 returns no children.
    final shallow = await menuCall(host, tray, 'GetLayout', [
      const DBusInt32(0),
      const DBusInt32(0),
      DBusArray.string(const ['label']),
    ]);
    expect(shallow[1].asStruct()[2].asVariantArray(), isEmpty);

    for (final id in [3, 4, 6]) {
      await menuCall(host, tray, 'Event', [
        DBusInt32(id),
        const DBusString('clicked'),
        DBusVariant(const DBusString('')),
        const DBusUint32(0),
      ]);
    }
    // Hover events are not actions.
    await menuCall(host, tray, 'Event', [
      const DBusInt32(6),
      const DBusString('hovered'),
      DBusVariant(const DBusString('')),
      const DBusUint32(0),
    ]);
    expect(actions, ['open', 'pause', 'quit']);
    final errors = await menuCall(host, tray, 'EventGroup', [
      DBusArray(DBusSignature('(isvu)'), [
        DBusStruct([
          const DBusInt32(3),
          const DBusString('clicked'),
          DBusVariant(const DBusString('')),
          const DBusUint32(0),
        ]),
        DBusStruct([
          const DBusInt32(99),
          const DBusString('clicked'),
          DBusVariant(const DBusString('')),
          const DBusUint32(0),
        ]),
      ]),
    ]);
    expect(errors.single.asInt32Array(), [99]);
    expect(actions.last, 'open');
    await host.callMethod(
      destination: tray.serviceName,
      path: DBusObjectPath(itemPath),
      interface: itemInterface,
      name: 'Activate',
      values: const [DBusInt32(0), DBusInt32(0)],
    );
    expect(actions.last, 'open');
    expect(
      (await menuCall(host, tray, 'AboutToShow', [
        const DBusInt32(0),
      ])).single.asBoolean(),
      isFalse,
    );

    await tray.setState(SyncStatus.paused, paused: true);
    await eventually(() => signals.contains('LayoutUpdated'));
    final updated = await menuCall(host, tray, 'GetGroupProperties', [
      DBusArray.int32(const [1, 4]),
      DBusArray.string(const ['label']),
    ]);
    final labels = {
      for (final item in updated.single.asArray())
        item.asStruct()[0].asInt32(): item
            .asStruct()[1]
            .asStringVariantDict()['label']!
            .asString(),
    };
    expect(labels, {1: 'AnJ Cloud: Paused', 4: 'Resume sync'});
    final after = await menuCall(host, tray, 'GetLayout', [
      const DBusInt32(0),
      const DBusInt32(-1),
      DBusArray.string(const []),
    ]);
    expect(after[0].asUint32(), greaterThan(revision));
    expect(signals, containsAll(['ItemsPropertiesUpdated', 'NewToolTip']));
    expect(
      (await itemProperty(host, tray, 'ToolTip')).asStruct()[3].asString(),
      'Paused',
    );

    await tray.setState(SyncStatus.attention, paused: false);
    await eventually(() => signals.contains('NewStatus'));
    expect(
      (await itemProperty(host, tray, 'Status')).asString(),
      'NeedsAttention',
    );
    for (final status in SyncStatus.values) {
      await tray.setState(status, paused: status == SyncStatus.paused);
      final current = layoutItems(
        (await menuCall(host, tray, 'GetLayout', [
          const DBusInt32(0),
          const DBusInt32(-1),
          DBusArray.string(const []),
        ]))[1],
      );
      expect(current[1]!['label']!.asString(), 'AnJ Cloud: ${status.label}');
    }
  });

  test('host availability follows the watcher: absent, appearing, '
      'unregistering and disappearing', () async {
    final (tray, _) = await startTray();
    expect(tray.hostAvailable, isFalse, reason: 'no watcher on the bus');
    final changes = <bool>[];
    final subscription = tray.hostChanges.listen(changes.add);
    cleanups.add(subscription.cancel);

    final (watcherClient, watcher) = await FakeWatcher.start(
      bus,
      hostRegistered: false,
    );
    await eventually(() => watcher.registered.isNotEmpty);
    expect(watcher.registered, [tray.serviceName]);
    expect(tray.hostAvailable, isFalse, reason: 'watcher without a host');
    await watcher.setHost(true);
    await eventually(() => tray.hostAvailable);
    await watcher.setHost(false);
    await eventually(() => !tray.hostAvailable);
    await watcher.setHost(true);
    await eventually(() => tray.hostAvailable);
    // The tray host process crashes: its connection (and name) disappear.
    await watcherClient.close();
    await eventually(() => !tray.hostAvailable);
    expect(changes, [true, false, true, false]);

    // A restarted watcher gets the item registered again.
    final (again, restarted) = await FakeWatcher.start(bus);
    cleanups.add(again.close);
    await eventually(() => tray.hostAvailable);
    expect(restarted.registered, [tray.serviceName]);
  });

  test('closing the tray removes the item from the bus', () async {
    final (watcherClient, _) = await FakeWatcher.start(bus);
    cleanups.add(watcherClient.close);
    final (tray, _) = await startTray();
    final host = client();
    expect(await host.nameHasOwner(tray.serviceName), isTrue);
    await tray.close();
    expect(await host.nameHasOwner(tray.serviceName), isFalse);
  });

  group('per-profile activation', () {
    test('name derivation matches the manager (shared vectors)', () {
      expect(
        activationBusName('/home/user/.local/share/anj-cloud/profiles/default'),
        'cloud.anj.AnjCloud.p1375a8456229d3fabd546f85d6acf6b2',
      );
      expect(
        activationBusName('/tmp/profile " % \$ é'),
        'cloud.anj.AnjCloud.p38a88d30f064480aa4bebb125cea351a',
      );
    });

    test(
      'Activate() reaches the running instance; the name is exclusive',
      () async {
        const profile = '/tmp/anj-profile-under-test';
        var activations = 0;
        final running = client();
        final service = await ActivationService.claim(
          running,
          profile,
          () => activations++,
        );
        expect(service, isNotNull);
        final second = client();
        expect(
          await ActivationService.claim(second, profile, () {}),
          isNull,
          reason: 'a second process cannot take over the profile name',
        );
        final launcher = client();
        expect(await activateRunning(launcher, profile), isTrue);
        await eventually(() => activations == 1);
        expect(await activateRunning(launcher, '/tmp/other-profile'), isFalse);
        // The name is released with the connection (process exit).
        await running.close();
        cleanups.remove(running.close);
        expect(await activateRunning(launcher, profile), isFalse);
        expect(
          await ActivationService.claim(second, profile, () {}),
          isNotNull,
        );
      },
    );
  });

  test('trayPixmaps converts the bundled PNG to ARGB32 sizes', () {
    final png = File('assets/branding/harbor/icon-128.png').readAsBytesSync();
    final pixmaps = trayPixmaps(png);
    expect(pixmaps.map((p) => p.size), [22, 32, 48, 64]);
    for (final pixmap in pixmaps) {
      expect(pixmap.argb.length, pixmap.size * pixmap.size * 4);
    }
    // Opaque centre pixel: alpha first (network byte order ARGB).
    final centre = pixmaps.last;
    final offset = (32 * 64 + 32) * 4;
    expect(centre.argb[offset], greaterThan(0));
  });
}
