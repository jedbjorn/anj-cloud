import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/ports/add_files.dart';

/// The Dart end of the runner's AddFilesChannel.kt (spec #28 What Android
/// Is; spec #43): the system picker (ACTION_OPEN_DOCUMENT, and
/// ACTION_OPEN_DOCUMENT_TREE walked through the tree's one-time grant), the
/// Share sheet, and a private copy of each source for the worker to read.
class AndroidAddFiles implements AddFilesPort {
  AndroidAddFiles() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareArrived') _arrived.add(null);
      return null;
    });
  }

  static const _channel = MethodChannel('cloud.anj.anj_cloud/add');
  final _arrived = StreamController<void>.broadcast();

  static List<AddSource> _sources(Object? value) => [
    for (final item in (value as List? ?? const []).cast<Map>())
      AddSource(
        path: item['path'] as String,
        directory: item['directory'] == true,
        size: (item['size'] as num?)?.toInt(),
        virtual: item['virtual'] == true,
        reference: item['uri'] as String?,
      ),
  ];

  @override
  Future<List<AddSource>?> pickFiles() async {
    final picked = await _channel.invokeMethod<List>('pickFiles');
    return picked == null ? null : _sources(picked);
  }

  @override
  Future<String?> pickFolder() => _channel.invokeMethod<String>('pickFolder');

  @override
  Future<List<AddSource>?> listFolder() async {
    final listed = await _channel.invokeMethod<List>('listFolder');
    return listed == null ? null : _sources(listed);
  }

  @override
  void cancelListing() =>
      unawaited(_channel.invokeMethod<void>('cancelListing'));

  @override
  Future<String> open(AddSource source, {required int limit}) async {
    try {
      return (await _channel.invokeMethod<String>('open', {
        'uri': source.reference,
        'limit': limit,
      }))!;
    } on PlatformException catch (error) {
      throw AddSourceFailure(
        const {'overLimit', 'cancelled'}.contains(error.code)
            ? error.code
            : 'unreadable',
      );
    }
  }

  @override
  void cancelOpen() => unawaited(_channel.invokeMethod<void>('cancelOpen'));

  @override
  Future<void> release(String path) =>
      _channel.invokeMethod<void>('release', {'path': path});

  @override
  Future<int?> freeBytes(String path) async =>
      (await _channel.invokeMethod<num>('freeBytes', {'path': path}))?.toInt();

  @override
  Future<SharedItems?> takeShare() async {
    final share = await _channel.invokeMethod<Map>('takeShare');
    return share == null ? null : SharedItems(_sources(share['items']));
  }

  @override
  Stream<void> get shareArrived => _arrived.stream;

  @override
  Future<void> leaveShare() => _channel.invokeMethod<void>('leaveShare');
}
