import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path/path.dart' as p;

import '../../core/app/controller.dart';
import '../../core/ports/autostart.dart';
import '../../core/ports/mobile_settings.dart';
import '../../core/state/model.dart';
import '../../core/sync/sync_schedule.dart';

/// The runner's channel (MainActivity, SyncHost, SyncWorker and
/// TransferService in apps/client/android; spec #28 A4).
const backgroundChannel = MethodChannel('cloud.anj/background');

/// One attention notification (decision #108 Q14): a conflict or a refused
/// upload, keyed so each is posted once while it lasts.
class AttentionItem {
  const AttentionItem(this.key, this.path, this.title, this.text);
  final String key;
  final String path;
  final String title;
  final String text;
  Map<String, String> toJson() => {
    'key': key,
    'path': path,
    'title': title,
    'text': text,
  };
}

/// What needs the user's attention in a projected library: conflicts and
/// uploads the server refused for their size.
List<AttentionItem> attentionItems(Iterable<Map<String, dynamic>> entries) {
  final items = <AttentionItem>[];
  for (final entry in entries) {
    final path = entry['path'] as String? ?? '';
    final conflict = entry['conflict'] as String?;
    final status = entry['status'] as String? ?? '';
    final name = p.posix.basename(path);
    if (conflict != null) {
      items.add(
        AttentionItem(
          'conflict:$path:$conflict',
          path,
          'Conflict: $name',
          conflict,
        ),
      );
    } else if (isSizeRefusal(status)) {
      items.add(
        AttentionItem(
          'refused:$path:$status',
          path,
          'Upload refused: $name',
          status,
        ),
      );
    }
  }
  return items;
}

/// Posts each attention item once while it lasts, across process starts: a
/// background run that restarts the process does not repeat a notification
/// every 15 minutes. A key that disappears (resolved) is forgotten, and its
/// notification withdrawn, so the same problem coming back is announced
/// again. Kept in the profile as {key: path}.
class AttentionTracker {
  AttentionTracker(this.file);
  final File file;
  Map<String, String>? _posted;

  Map<String, String> _load() {
    try {
      return Map<String, String>.from(
        jsonDecode(file.readAsStringSync()) as Map,
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  /// The items not yet announced, and the paths whose announced items have
  /// all resolved (their notifications are withdrawn); records the current
  /// set. Call only with a library the worker has reported: an empty list
  /// means "nothing needs attention", and forgets every announced item.
  ({List<AttentionItem> fresh, List<String> resolved}) update(
    List<AttentionItem> current,
  ) {
    final posted = _posted ??= _load();
    final now = {for (final item in current) item.key: item.path};
    final fresh = [
      for (final item in current)
        if (!posted.containsKey(item.key)) item,
    ];
    final paths = now.values.toSet();
    final resolved = {
      for (final entry in posted.entries)
        if (!now.containsKey(entry.key) && !paths.contains(entry.value))
          entry.value,
    }.toList()..sort();
    if (fresh.isEmpty &&
        posted.length == now.length &&
        now.keys.every(posted.containsKey)) {
      return (fresh: const [], resolved: const []);
    }
    _posted = now;
    try {
      file.writeAsStringSync(jsonEncode(now), flush: true);
    } on FileSystemException {
      // Without the record a later start may announce an item again.
    }
    return (fresh: fresh, resolved: resolved);
  }
}

/// Android background sync, network setting and notifications (spec #28
/// A4, decision #108 Q3, Q4 and Q14). The runner owns WorkManager, the
/// dataSync service, connectivity and the notifications; this side answers
/// background runs from the engine and reports what the user should see.
///
/// Runner to Dart: `backgroundRun` (one complete pass, answered when it
/// ends), `network` ({wifi}), `notifications` ({allowed}) and `foreground`
/// (report transfers again).
/// Dart to runner: `attach`, `transfers` ({count, waiting}), `attention`
/// ({items, current}), `openNotificationSettings`, `backgroundSync.get` and
/// `backgroundSync.set`.
class AndroidBackground extends ChangeNotifier implements MobileSettings {
  AndroidBackground(this.controller, {MethodChannel? channel})
    : channel = channel ?? backgroundChannel;
  final ClientController controller;
  final MethodChannel channel;
  late final AttentionTracker _attention = AttentionTracker(
    File(p.join(controller.profile.path, 'attention-notified-v2.json')),
  );
  Future<void> _initialized = Future.value();
  bool _notifications = false;
  ({int count, int waiting})? _lastTransfers;
  bool _attached = false;
  AppLifecycleListener? _lifecycle;

  @override
  bool get notificationsAllowed => _notifications;

  /// Installs the handler before the controller starts, so a background run
  /// that started this process is answered once [initialized] completes.
  @override
  Future<void> start(Future<void> initialized) async {
    _initialized = initialized;
    channel.setMethodCallHandler(_handle);
    controller.addListener(_report);
    // Leaving the app mid-transfer: expedited work keeps the process until
    // the pass ends, so local changes still upload promptly (#108 Q3).
    _lifecycle = AppLifecycleListener(onHide: _left);
    try {
      final state = Map<String, Object?>.from(
        await channel.invokeMethod<Map>('attach') ?? const {},
      );
      _notifications = state['notifications'] == true;
      final wifi = state['wifi'];
      if (wifi is bool) controller.reportNetwork(wifi: wifi);
      _attached = true;
      notifyListeners();
      _report();
    } on MissingPluginException {
      // A runner without the channel (widget tests): nothing to report to.
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments is Map
        ? Map<String, Object?>.from(call.arguments as Map)
        : const <String, Object?>{};
    switch (call.method) {
      case 'backgroundRun':
        await _initialized;
        // All files access as it is now, before the run's pass (spec #52).
        await controller.checkPhoneFolders();
        return controller.backgroundRun();
      case 'network':
        controller.reportNetwork(wifi: args['wifi'] == true);
        return null;
      case 'foreground':
        // The app is in the foreground and the runner's service cap was
        // cleared: report the current transfers even if unchanged.
        _lastTransfers = null;
        _report();
        return null;
      case 'notifications':
        _notifications = args['allowed'] == true;
        notifyListeners();
        // Announce what is already waiting once posting becomes possible.
        _report();
        return null;
    }
    throw MissingPluginException(call.method);
  }

  void _left() {
    if (controller.syncing.isNotEmpty ||
        controller.status == SyncStatus.syncing) {
      unawaited(_invoke('prompt', null));
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    controller.removeListener(_report);
    super.dispose();
  }

  void _report() {
    if (!_attached) return;
    final waiting = controller.entries
        .where((e) => e['status'] == waitingForWifiStatus)
        .length;
    final transfers = (count: controller.syncing.length, waiting: waiting);
    if (transfers != _lastTransfers) {
      _lastTransfers = transfers;
      unawaited(
        _invoke('transfers', {'count': transfers.count, 'waiting': waiting}),
      );
    }
    // Until the worker has reported the library, `entries` is empty for
    // lack of news, not because everything resolved: judging it would forget
    // every announced item and repeat them all after each restart.
    if (!controller.stateReceived) return;
    final current = attentionItems(controller.entries);
    // Nothing is recorded as announced while the user declines
    // notifications; the in-app status shows the same items.
    if (!_notifications) return;
    final change = _attention.update(current);
    if (change.fresh.isNotEmpty || change.resolved.isNotEmpty) {
      unawaited(
        _invoke('attention', {
          'items': [for (final item in change.fresh) item.toJson()],
          'resolved': change.resolved,
        }),
      );
    }
  }

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException {
      // A notification that cannot be posted never disturbs sync.
    } on MissingPluginException {
      // Widget tests.
    }
  }

  @override
  Future<void> openNotificationSettings() =>
      _invoke('openNotificationSettings', null);
}

/// The Background-sync switch (spec #28 Background Sync): on Android the
/// start-at-login choice of #40, on by default. On, the runner keeps the
/// unique periodic WorkManager work; off cancels exactly that work.
/// WorkManager keeps the work across reboots and runs it after the first
/// unlock.
class AndroidBackgroundSwitch implements AutostartControl {
  AndroidBackgroundSwitch({MethodChannel? channel})
    : channel = channel ?? backgroundChannel;
  final MethodChannel channel;

  AutostartState _state(Object? value) {
    final map = value is Map ? value : const {};
    return AutostartState(
      enabled: map['enabled'] == true,
      source: map['source'] as String?,
    );
  }

  @override
  Future<AutostartState> status() async =>
      _state(await channel.invokeMethod<Map>('backgroundSync.get'));

  @override
  Future<AutostartState> set(bool enabled) async => _state(
    await channel.invokeMethod<Map>('backgroundSync.set', {'enabled': enabled}),
  );
}
