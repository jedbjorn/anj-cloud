import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/access/access_store.dart';
import '../../core/access/documents_service.dart';
import '../../core/ports/desktop_launcher.dart';
import '../../core/ports/documents.dart';
import 'background.dart' show backgroundChannel;

/// The Dart end of the runner's "AnJ Cloud" DocumentsProvider (spec #28
/// A5). The provider (AnjDocumentsProvider.kt) identifies each caller and
/// forwards the call over `cloud.anj/documents`; [DocumentsService] decides
/// and asks the sync worker. The runner's `cloud.anj/apps` channel lists and
/// opens apps and withdraws platform grants for "Apps with access".
class AndroidDocuments implements GrantRevoker, PlatformApps {
  AndroidDocuments._(DocumentsHost host, String profile) {
    service =
        DocumentsService(
            host,
            AccessStore(Directory(profile)),
            revoker: this,
            platformApps: this,
          )
          ..onChildrenChanged = _changed
          ..onLocalChange = _prompt;
    _documents.setMethodCallHandler(_call);
  }

  /// The running bridge (one per process; the launcher finds ids here).
  static AndroidDocuments? instance;

  static AppAccess start(DocumentsHost host, String profile) {
    final existing = instance;
    if (existing != null) return existing.service;
    return (instance = AndroidDocuments._(host, profile)).service;
  }

  static const _documents = MethodChannel('cloud.anj/documents');
  static const _apps = MethodChannel('cloud.anj/apps');
  late final DocumentsService service;

  /// A provider change: expedited one-time work (A4's `prompt`), so it
  /// uploads while the app is in the background (review M1).
  void _prompt() => unawaited(
    backgroundChannel.invokeMethod<void>('prompt').catchError((_) {}),
  );

  void _changed(List<String> ids) => unawaited(
    _documents.invokeMethod<void>('changed', ids).catchError((_) {}),
  );

  Future<Object?> _call(MethodCall call) async {
    final args = Map<Object?, Object?>.from(call.arguments as Map? ?? {});
    DocumentsCaller caller() =>
        DocumentsCaller.fromMap(args['caller'] as Map<Object?, Object?>);
    try {
      switch (call.method) {
        case 'roots':
          return service.roots();
        case 'document':
          return service.document(args['id'] as String, caller());
        case 'children':
          return service.children(args['id'] as String, caller());
        case 'isChild':
          return service.isChild(
            args['parent'] as String,
            args['id'] as String,
          );
        case 'findPath':
          return service.findPath(
            args['parent'] as String?,
            args['id'] as String,
            caller(),
          );
        case 'open':
          return await service.open(
            args['id'] as String,
            args['mode'] as String,
            caller(),
          );
        case 'closed':
          await service.closed(args['token'] as String);
          return null;
        case 'create':
          return await service.create(
            args['parent'] as String,
            args['name'] as String,
            args['directory'] == true,
            caller(),
          );
        case 'rename':
          return await service.rename(
            args['id'] as String,
            args['name'] as String,
            caller(),
          );
        case 'move':
          return await service.move(
            args['id'] as String,
            args['target'] as String,
            caller(),
          );
        case 'delete':
          await service.delete(args['id'] as String, caller());
          return null;
      }
    } on DocumentsFailure catch (error) {
      throw PlatformException(code: error.code, message: error.message);
    } on FileSystemException catch (error) {
      throw PlatformException(code: 'refused', message: error.message);
    }
    throw MissingPluginException(call.method);
  }

  // ---- GrantRevoker ----------------------------------------------------------

  @override
  Future<List<String>> persistedTrees() async =>
      (await _apps.invokeListMethod<String>('persistedTrees')) ?? const [];

  @override
  Future<void> revokeTree(String package, String documentId) => _apps
      .invokeMethod<void>('revokeTree', {'package': package, 'id': documentId});

  @override
  Future<List<({String id, bool read, bool write})>>
  persistedDocuments() async => [
    for (final row
        in (await _apps.invokeListMethod<Map<Object?, Object?>>(
              'persistedDocuments',
            )) ??
            const <Map<Object?, Object?>>[])
      (
        id: row['id'] as String,
        read: row['read'] == true,
        write: row['write'] == true,
      ),
  ];

  @override
  Future<void> revokeDocument(String documentId) =>
      _apps.invokeMethod<void>('revokeDocument', {'id': documentId});

  // ---- PlatformApps -----------------------------------------------------------

  static InstalledApp _app(Map<Object?, Object?> value) => InstalledApp(
    value['package'] as String,
    value['label'] as String,
    icon: value['icon'] as Uint8List?,
  );

  @override
  Future<List<InstalledApp>> installedApps() async => [
    for (final value
        in (await _apps.invokeListMethod<Map>('installedApps')) ??
            const <Map>[])
      _app(value.cast()),
  ];

  @override
  Future<Map<String, InstalledApp>> describe(List<String> packages) async {
    final values =
        await _apps.invokeListMethod<Map>('describe', packages) ?? const [];
    return {
      for (final value in values)
        value['package'] as String: _app(value.cast()),
    };
  }

  @override
  Future<bool> openApp(String package) async =>
      await _apps.invokeMethod<bool>('openApp', package) ?? false;

  /// Opens a working copy in another app with a per-document grant (R1).
  static Future<bool> openDocument(String id, String name) async =>
      await _apps.invokeMethod<bool>('openDocument', {
        'id': id,
        'name': name,
      }) ??
      false;

  /// Shows a folder of AnJ Cloud in the Files app.
  static Future<bool> showFolder(String id) async =>
      await _apps.invokeMethod<bool>('showFolder', {'id': id}) ?? false;
}

/// Android [DesktopLauncher] (spec #28 Files App and Editing, R1): Open hands
/// the working copy the engine prepared (as on Linux, #16) to an app the
/// user chooses, through a per-document grant on the provider; Show in
/// folder opens the Files app at that folder. Either reports false when no
/// app accepts it, and the shared UI says so.
class AndroidLauncher extends DesktopLauncher {
  /// Only the `w:` provider document is handed out (decision #184).
  @override
  bool get handsOutThroughProvider => true;

  @override
  Future<bool> openFile(String path) async {
    final name = path.split('/').last;
    try {
      return await AndroidDocuments.openDocument('w:$name', name);
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> openDirectory(
    String root,
    String relative,
    String rootIdentity,
  ) async {
    final bridge = AndroidDocuments.instance;
    if (bridge == null) return false;
    try {
      return await AndroidDocuments.showFolder(bridge.service.idOf(relative));
    } on PlatformException {
      return false;
    }
  }
}
