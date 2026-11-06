import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dbus/dbus.dart';
import 'package:image/image.dart' as img;

import '../../core/ports/desktop_session.dart';
import '../../core/sync/sync_schedule.dart';

/// Session-bus integration written in Dart over `package:dbus`: no native
/// tray library (and so no new ELF dependency) is linked.
///
/// Per-profile activation: the process holding a profile's lifetime lock
/// owns [activationBusName] and shows its window on `Activate()`. The
/// Linux manager derives the same name (tool/linux_install.py).
const activationPath = '/cloud/anj/AnjCloud';
const activationInterface = 'cloud.anj.AnjCloud1';

String activationBusName(String canonicalProfile) {
  final digest = sha256.convert(utf8.encode(canonicalProfile)).toString();
  return 'cloud.anj.AnjCloud.p${digest.substring(0, 32)}';
}

class ActivationService extends DBusObject {
  ActivationService._(this.onActivate) : super(DBusObjectPath(activationPath));
  final void Function() onActivate;

  /// Exports the service and claims the profile's name. Returns null (and
  /// exports nothing) when another connection already owns it.
  static Future<ActivationService?> claim(
    DBusClient client,
    String profile,
    void Function() onActivate,
  ) async {
    final service = ActivationService._(onActivate);
    await client.registerObject(service);
    final reply = await client.requestName(
      activationBusName(profile),
      flags: {DBusRequestNameFlag.doNotQueue},
    );
    if (reply != DBusRequestNameReply.primaryOwner &&
        reply != DBusRequestNameReply.alreadyOwner) {
      await client.unregisterObject(service);
      return null;
    }
    return service;
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      activationInterface,
      methods: [DBusIntrospectMethod('Activate')],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != activationInterface ||
        methodCall.name != 'Activate') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (methodCall.values.isNotEmpty) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    onActivate();
    return DBusMethodSuccessResponse();
  }
}

/// Asks the instance already running [profile] to show its window.
Future<bool> activateRunning(DBusClient client, String profile) async {
  try {
    await client.callMethod(
      destination: activationBusName(profile),
      path: DBusObjectPath(activationPath),
      interface: activationInterface,
      name: 'Activate',
      replySignature: DBusSignature(''),
      noAutoStart: true,
    );
    return true;
  } on DBusMethodResponseException {
    return false;
  }
}

const watcherName = 'org.kde.StatusNotifierWatcher';
const watcherPath = '/StatusNotifierWatcher';
const itemInterface = 'org.kde.StatusNotifierItem';
const itemPath = '/StatusNotifierItem';
const menuInterface = 'com.canonical.dbusmenu';
const menuPath = '/MenuBar';

/// One ARGB32 (network byte order) icon image as SNI expects it.
class TrayPixmap {
  const TrayPixmap(this.size, this.argb);
  final int size;
  final Uint8List argb;
}

/// Converts the bundled PNG into the tray sizes hosts commonly request.
List<TrayPixmap> trayPixmaps(
  Uint8List png, {
  List<int> sizes = const [22, 32, 48, 64],
}) {
  final source = img.decodePng(png);
  if (source == null) return const [];
  return [
    for (final size in sizes)
      () {
        final scaled = img.copyResize(
          source,
          width: size,
          height: size,
          interpolation: img.Interpolation.average,
        );
        final bytes = Uint8List(size * size * 4);
        var i = 0;
        for (var y = 0; y < size; y++) {
          for (var x = 0; x < size; x++) {
            final pixel = scaled.getPixel(x, y);
            bytes[i++] = pixel.a.toInt();
            bytes[i++] = pixel.r.toInt();
            bytes[i++] = pixel.g.toInt();
            bytes[i++] = pixel.b.toInt();
          }
        }
        return TrayPixmap(size, bytes);
      }(),
  ];
}

/// StatusNotifierItem with a com.canonical.dbusmenu menu: status, Open,
/// Pause/Resume and Quit. Tracks the watcher so the lifecycle knows whether
/// a hidden window can be reopened from a tray.
class StatusNotifierTray implements TrayControl {
  StatusNotifierTray(
    this.client, {
    required this.onOpen,
    required this.onTogglePause,
    required this.onQuit,
    this.pixmaps = const [],
    this.id = 'anj-cloud',
    this.title = 'AnJ Cloud',
  }) {
    _item = _ItemObject(this);
    _menu = _MenuObject(this);
  }

  final DBusClient client;
  final void Function() onOpen;
  final void Function() onTogglePause;
  final void Function() onQuit;
  final List<TrayPixmap> pixmaps;
  final String id;
  final String title;
  late final _ItemObject _item;
  late final _MenuObject _menu;
  final _hosts = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  String _name = '';
  bool _hostAvailable = false;
  bool _registered = false;
  bool _closed = false;
  SyncStatus _status = SyncStatus.upToDate;
  bool _paused = false;
  int _revision = 1;

  /// Bus name registered with the watcher.
  String get serviceName => _name;
  @override
  bool get hostAvailable => _hostAvailable;
  @override
  Stream<bool> get hostChanges => _hosts.stream;
  SyncStatus get status => _status;
  bool get paused => _paused;

  Future<void> start({int instance = 1}) async {
    await client.registerObject(_item);
    await client.registerObject(_menu);
    _name = 'org.kde.StatusNotifierItem-$pid-$instance';
    await client.requestName(_name, flags: {DBusRequestNameFlag.doNotQueue});
    _subscriptions.add(
      client.nameOwnerChanged.where((e) => e.name == watcherName).listen((
        event,
      ) {
        if (event.newOwner == null) {
          _registered = false;
          _setHost(false);
        } else {
          unawaited(_register());
        }
      }),
    );
    for (final signal in const [
      'StatusNotifierHostRegistered',
      'StatusNotifierHostUnregistered',
    ]) {
      _subscriptions.add(
        DBusSignalStream(
          client,
          interface: watcherName,
          name: signal,
          path: DBusObjectPath(watcherPath),
        ).listen((_) => unawaited(_refreshHost())),
      );
    }
    await _register();
  }

  Future<void> _register() async {
    if (_closed) return;
    try {
      await client.callMethod(
        destination: watcherName,
        path: DBusObjectPath(watcherPath),
        interface: watcherName,
        name: 'RegisterStatusNotifierItem',
        values: [DBusString(_name)],
        replySignature: DBusSignature(''),
        noAutoStart: true,
      );
      _registered = true;
    } on DBusMethodResponseException {
      _registered = false;
    }
    await _refreshHost();
  }

  Future<void> _refreshHost() async {
    if (_closed) return;
    var available = false;
    if (_registered) {
      try {
        final reply = await client.callMethod(
          destination: watcherName,
          path: DBusObjectPath(watcherPath),
          interface: 'org.freedesktop.DBus.Properties',
          name: 'Get',
          values: [
            const DBusString(watcherName),
            const DBusString('IsStatusNotifierHostRegistered'),
          ],
          replySignature: DBusSignature('v'),
          noAutoStart: true,
        );
        final value = reply.returnValues.first.asVariant();
        available = value is DBusBoolean && value.value;
      } on DBusMethodResponseException {
        available = false;
      }
    }
    _setHost(available);
  }

  void _setHost(bool available) {
    if (_closed || available == _hostAvailable) return;
    _hostAvailable = available;
    _hosts.add(available);
  }

  @override
  Future<void> setState(SyncStatus status, {required bool paused}) async {
    if (_closed || (status == _status && paused == _paused)) return;
    final attention =
        (status == SyncStatus.attention) != (_status == SyncStatus.attention);
    _status = status;
    _paused = paused;
    _revision++;
    try {
      await _menu.emitSignal(menuInterface, 'ItemsPropertiesUpdated', [
        DBusArray(DBusSignature('(ia{sv})'), [
          for (final id in const [1, 4])
            DBusStruct([
              DBusInt32(id),
              DBusDict.stringVariant(_menu.props(id)),
            ]),
        ]),
        DBusArray(DBusSignature('(ias)'), const []),
      ]);
      await _menu.emitSignal(menuInterface, 'LayoutUpdated', [
        DBusUint32(_revision),
        const DBusInt32(0),
      ]);
      await _item.emitSignal(itemInterface, 'NewToolTip');
      if (attention) {
        await _item.emitSignal(itemInterface, 'NewStatus', [
          DBusString(_item.sniStatus),
        ]);
      }
    } on Object {
      // A disconnected bus only loses the tray; sync is unaffected.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _hosts.close();
    try {
      await client.unregisterObject(_item);
      await client.unregisterObject(_menu);
      if (_name.isNotEmpty) await client.releaseName(_name);
    } on Object {
      // Closing the connection removes the item regardless.
    }
  }
}

class _ItemObject extends DBusObject {
  _ItemObject(this.tray) : super(DBusObjectPath(itemPath));
  final StatusNotifierTray tray;

  String get sniStatus =>
      tray._status == SyncStatus.attention ? 'NeedsAttention' : 'Active';

  DBusValue _pixmaps() => DBusArray(DBusSignature('(iiay)'), [
    for (final pixmap in tray.pixmaps)
      DBusStruct([
        DBusInt32(pixmap.size),
        DBusInt32(pixmap.size),
        DBusArray.byte(pixmap.argb),
      ]),
  ]);

  Map<String, DBusValue> get properties => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': DBusString(tray.id),
    'Title': DBusString(tray.title),
    'Status': DBusString(sniStatus),
    'WindowId': const DBusInt32(0),
    'IconName': const DBusString(''),
    'IconThemePath': const DBusString(''),
    'IconPixmap': _pixmaps(),
    'OverlayIconName': const DBusString(''),
    'OverlayIconPixmap': DBusArray(DBusSignature('(iiay)'), const []),
    'AttentionIconName': const DBusString(''),
    'AttentionIconPixmap': _pixmaps(),
    'AttentionMovieName': const DBusString(''),
    'ToolTip': DBusStruct([
      const DBusString(''),
      DBusArray(DBusSignature('(iiay)'), const []),
      DBusString(tray.title),
      DBusString(tray._status.label),
    ]),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath(menuPath),
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      itemInterface,
      methods: [
        for (final name in const [
          'Activate',
          'SecondaryActivate',
          'ContextMenu',
        ])
          DBusIntrospectMethod(
            name,
            args: [
              DBusIntrospectArgument(
                DBusSignature('i'),
                DBusArgumentDirection.in_,
                name: 'x',
              ),
              DBusIntrospectArgument(
                DBusSignature('i'),
                DBusArgumentDirection.in_,
                name: 'y',
              ),
            ],
          ),
        DBusIntrospectMethod(
          'Scroll',
          args: [
            DBusIntrospectArgument(
              DBusSignature('i'),
              DBusArgumentDirection.in_,
              name: 'delta',
            ),
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'orientation',
            ),
          ],
        ),
      ],
      signals: [
        for (final name in const [
          'NewTitle',
          'NewIcon',
          'NewAttentionIcon',
          'NewOverlayIcon',
          'NewToolTip',
        ])
          DBusIntrospectSignal(name),
        DBusIntrospectSignal(
          'NewStatus',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.out,
              name: 'status',
            ),
          ],
        ),
      ],
      properties: [
        for (final entry in properties.entries)
          DBusIntrospectProperty(
            entry.key,
            entry.value.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Activate':
      case 'SecondaryActivate':
        tray.onOpen();
        return DBusMethodSuccessResponse();
      case 'ContextMenu':
      case 'Scroll':
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == itemInterface ? properties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == itemInterface ? properties : {},
      );
}

/// Menu item ids: 0 root, 1 status, 2/5 separators, 3 Open, 4 Pause or
/// Resume, 6 Quit.
class _MenuObject extends DBusObject {
  _MenuObject(this.tray) : super(DBusObjectPath(menuPath));
  final StatusNotifierTray tray;
  static const _children = {
    0: [1, 2, 3, 4, 5, 6],
  };

  Map<String, DBusValue> props(int id) {
    switch (id) {
      case 0:
        return {'children-display': const DBusString('submenu')};
      case 1:
        return {
          'label': DBusString('${tray.title}: ${tray._status.label}'),
          'enabled': const DBusBoolean(false),
        };
      case 2:
      case 5:
        return {'type': const DBusString('separator')};
      case 3:
        return {'label': const DBusString('Open AnJ Cloud')};
      case 4:
        return {
          'label': DBusString(tray._paused ? 'Resume sync' : 'Pause sync'),
        };
      case 6:
        return {'label': const DBusString('Quit AnJ Cloud')};
    }
    return const {};
  }

  static const _ids = [0, 1, 2, 3, 4, 5, 6];

  Map<String, DBusValue> _filtered(int id, List<String> names) {
    final all = props(id);
    if (names.isEmpty) return all;
    return {
      for (final entry in all.entries)
        if (names.contains(entry.key)) entry.key: entry.value,
    };
  }

  DBusStruct _layout(int id, int depth, List<String> names) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(_filtered(id, names)),
    DBusArray.variant([
      if (depth != 0)
        for (final child in _children[id] ?? const <int>[])
          _layout(child, depth < 0 ? -1 : depth - 1, names),
    ]),
  ]);

  void _event(int id, String event) {
    if (event != 'clicked') return;
    switch (id) {
      case 3:
        tray.onOpen();
      case 4:
        tray.onTogglePause();
      case 6:
        tray.onQuit();
    }
  }

  @override
  List<DBusIntrospectInterface> introspect() {
    DBusIntrospectArgument arg(
      String signature,
      String name, {
      bool out = false,
    }) => DBusIntrospectArgument(
      DBusSignature(signature),
      out ? DBusArgumentDirection.out : DBusArgumentDirection.in_,
      name: name,
    );
    return [
      DBusIntrospectInterface(
        menuInterface,
        methods: [
          DBusIntrospectMethod(
            'GetLayout',
            args: [
              arg('i', 'parentId'),
              arg('i', 'recursionDepth'),
              arg('as', 'propertyNames'),
              arg('u', 'revision', out: true),
              arg('(ia{sv}av)', 'layout', out: true),
            ],
          ),
          DBusIntrospectMethod(
            'GetGroupProperties',
            args: [
              arg('ai', 'ids'),
              arg('as', 'propertyNames'),
              arg('a(ia{sv})', 'properties', out: true),
            ],
          ),
          DBusIntrospectMethod(
            'GetProperty',
            args: [
              arg('i', 'id'),
              arg('s', 'name'),
              arg('v', 'value', out: true),
            ],
          ),
          DBusIntrospectMethod(
            'Event',
            args: [
              arg('i', 'id'),
              arg('s', 'eventId'),
              arg('v', 'data'),
              arg('u', 'timestamp'),
            ],
          ),
          DBusIntrospectMethod(
            'EventGroup',
            args: [arg('a(isvu)', 'events'), arg('ai', 'idErrors', out: true)],
          ),
          DBusIntrospectMethod(
            'AboutToShow',
            args: [arg('i', 'id'), arg('b', 'needUpdate', out: true)],
          ),
          DBusIntrospectMethod(
            'AboutToShowGroup',
            args: [
              arg('ai', 'ids'),
              arg('ai', 'updatesNeeded', out: true),
              arg('ai', 'idErrors', out: true),
            ],
          ),
        ],
        signals: [
          DBusIntrospectSignal(
            'ItemsPropertiesUpdated',
            args: [
              arg('a(ia{sv})', 'updatedProps', out: true),
              arg('a(ias)', 'removedProps', out: true),
            ],
          ),
          DBusIntrospectSignal(
            'LayoutUpdated',
            args: [
              arg('u', 'revision', out: true),
              arg('i', 'parent', out: true),
            ],
          ),
          DBusIntrospectSignal(
            'ItemActivationRequested',
            args: [arg('i', 'id', out: true), arg('u', 'timestamp', out: true)],
          ),
        ],
        properties: [
          DBusIntrospectProperty(
            'Version',
            DBusSignature('u'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'TextDirection',
            DBusSignature('s'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'Status',
            DBusSignature('s'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'IconThemePath',
            DBusSignature('as'),
            access: DBusPropertyAccess.read,
          ),
        ],
      ),
    ];
  }

  Map<String, DBusValue> get _properties => {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == menuInterface ? _properties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == menuInterface ? _properties : {},
      );

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != menuInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final values = methodCall.values;
    switch (methodCall.name) {
      case 'GetLayout':
        if (methodCall.signature != DBusSignature('iias')) break;
        final parent = values[0].asInt32();
        if (!_ids.contains(parent)) {
          return DBusMethodErrorResponse.invalidArgs('Unknown menu item');
        }
        return DBusMethodSuccessResponse([
          DBusUint32(tray._revision),
          _layout(
            parent,
            values[1].asInt32(),
            values[2].asStringArray().toList(),
          ),
        ]);
      case 'GetGroupProperties':
        if (methodCall.signature != DBusSignature('aias')) break;
        final requested = values[0].asInt32Array().toList();
        final names = values[1].asStringArray().toList();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in requested.isEmpty ? _ids : requested)
              if (_ids.contains(id))
                DBusStruct([
                  DBusInt32(id),
                  DBusDict.stringVariant(_filtered(id, names)),
                ]),
          ]),
        ]);
      case 'GetProperty':
        if (methodCall.signature != DBusSignature('is')) break;
        final value = props(values[0].asInt32())[values[1].asString()];
        if (value == null) {
          return DBusMethodErrorResponse.invalidArgs('Unknown property');
        }
        return DBusMethodSuccessResponse([DBusVariant(value)]);
      case 'Event':
        if (methodCall.signature != DBusSignature('isvu')) break;
        _event(values[0].asInt32(), values[1].asString());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        if (methodCall.signature != DBusSignature('a(isvu)')) break;
        final errors = <DBusValue>[];
        for (final event in values[0].asArray()) {
          final fields = event.asStruct();
          final id = fields[0].asInt32();
          if (_ids.contains(id)) {
            _event(id, fields[1].asString());
          } else {
            errors.add(DBusInt32(id));
          }
        }
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('i'), errors),
        ]);
      case 'AboutToShow':
        if (methodCall.signature != DBusSignature('i')) break;
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        if (methodCall.signature != DBusSignature('ai')) break;
        return DBusMethodSuccessResponse([
          DBusArray.int32(const []),
          DBusArray.int32(const []),
        ]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodErrorResponse.invalidArgs();
  }
}
