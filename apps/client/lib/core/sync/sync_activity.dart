import 'dart:io';

import '../gateway/cloud_api.dart';
import '../state/model.dart';
import '../gateway/sharing.dart';
import '../gateway/admin_api.dart';

/// Files the user should see as syncing: an upload or download in flight
/// ([ActivityCloud]), or committed to the running pass's transfer queue
/// ([plan]). Presentation only; synchronization never consults it.
class SyncActivity {
  final Set<String> _planned = {};
  final Map<String, int> _inFlight = {};

  /// Called whenever [paths] changes. The worker coalesces these.
  void Function()? onChanged;

  /// Built on demand (at most once per coalesced event); every change
  /// below is O(1) per path so a pass stays linear in its queue length.
  Set<String> get paths => {..._planned, ..._inFlight.keys};

  bool get isEmpty => _planned.isEmpty && _inFlight.isEmpty;

  void _changed() => onChanged?.call();

  /// The pass committed these files to its transfer queue.
  void plan(Iterable<String> paths) {
    var changed = false;
    for (final path in paths) {
      if (_planned.add(path) && !_inFlight.containsKey(path)) changed = true;
    }
    if (changed) _changed();
  }

  /// The pass finished with [path] (transferred, skipped or failed).
  void retire(String path) {
    if (_planned.remove(path) && !_inFlight.containsKey(path)) _changed();
  }

  /// The pass ended, completed or not: nothing remains queued.
  void clearPlan() {
    final visible = _planned.any((path) => !_inFlight.containsKey(path));
    _planned.clear();
    if (visible) _changed();
  }

  Future<T> transfer<T>(String path, Future<T> Function() run) async {
    final count = _inFlight[path] ?? 0;
    _inFlight[path] = count + 1;
    if (count == 0 && !_planned.contains(path)) _changed();
    try {
      return await run();
    } finally {
      final left = _inFlight[path]! - 1;
      if (left == 0) {
        _inFlight.remove(path);
        if (!_planned.contains(path)) _changed();
      } else {
        _inFlight[path] = left;
      }
    }
  }
}

/// Records every upload and download as in flight for its path while it
/// runs, whichever component started it (reconcile, editing, eviction proof,
/// opening a cloud-only file). Everything else is forwarded unchanged.
class ActivityCloud with ForwardSharing, ForwardAdmin implements CloudApi {
  ActivityCloud(this.inner, this.activity);
  final CloudApi inner;
  @override
  CloudApi get sharingTarget => inner;
  final SyncActivity activity;

  @override
  Future<List<RemoteItem>> snapshot() => inner.snapshot();
  @override
  Future<void> download(String path, File target, {required String etag}) =>
      activity.transfer(path, () => inner.download(path, target, etag: etag));
  @override
  Future<String> upload(String path, File source, {required String? etag}) =>
      activity.transfer(path, () => inner.upload(path, source, etag: etag));
  @override
  bool get lastUploadReadBack => inner.lastUploadReadBack;
  @override
  int? get uploadLimit => inner.uploadLimit;
  @override
  Future<void> mkdir(String path) => inner.mkdir(path);
  @override
  Future<void> deleteFile(String path, {required String etag}) =>
      inner.deleteFile(path, etag: etag);
  @override
  Future<void> move(String from, String to, {required String etag}) =>
      inner.move(from, to, etag: etag);
  @override
  bool get safeFolderDeletion => inner.safeFolderDeletion;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) => inner.deleteFolder(path, versions: versions);
  @override
  Future<AddedPage?> addedSince(int after) => inner.addedSince(after);
  @override
  void close() => inner.close();
}
