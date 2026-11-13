import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../local/root_tree.dart' show uniqueId;
import '../ports/add_files.dart';
import '../ports/documents_filesystem.dart';
import '../sync/file_adder.dart';

export '../ports/add_files.dart';
export '../ports/documents_filesystem.dart' show DocumentsFailure;
export '../sync/file_adder.dart' show AddSkip, addFreeSpaceReserve;

/// One worker command of the documents channel
/// ([ClientController.documentsCommand]).
typedef AddCommand = Future<Map<String, Object?>> Function(
  String op,
  Map<String, Object?> args,
);

/// The evaluated selection (spec #43 Before Copying).
class AddPlan {
  AddPlan(this.destination, this.sources, Map<String, Object?> check)
    : verdicts = (check['items'] as List).cast<Map>(),
      files = check['files'] as int,
      folders = check['folders'] as int,
      bytes = check['bytes'] as int,
      limit = check['limit'] as int,
      free = check['free'] as int?,
      noSpace = check['noSpace'] == true;
  final String destination;
  final List<AddSource> sources;

  /// One verdict per source, in order: `target`, `renamed`, `skip`, `listed`.
  final List<Map> verdicts;
  final int files;
  final int folders;
  final int bytes;
  final int limit;
  final int? free;

  /// The bytes to copy exceed the free space minus the reserve.
  final bool noSpace;

  bool get nothingToAdd => files + folders == 0;

  /// Items that will be skipped, with their reasons, as the user sees them.
  List<({String name, String reason})> get skipped => [
    for (final verdict in verdicts)
      if (verdict['skip'] != null && verdict['listed'] == true)
        (
          name: verdict['path'] as String,
          reason: AddSkip.values.byName(verdict['skip'] as String).text(limit),
        ),
  ];
}

/// What an add did (spec #43 Summary).
class AddResult {
  AddResult(this.destination);
  final String destination;
  int files = 0;
  int folders = 0;

  /// Added under another name: the picked name and the name it got.
  final renamed = <({String name, String addedAs})>[];
  final skipped = <({String name, String reason})>[];
  bool cancelled = false;

  /// "Added 5 files to Documents/Receipts".
  String get headline {
    String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    final parts = [
      if (folders > 0) count(folders, 'folder'),
      if (files > 0 || folders == 0) count(files, 'file'),
    ];
    return 'Added ${parts.join(' and ')} to $destination';
  }

  /// Nothing renamed or skipped: a snackbar is enough.
  bool get plain => renamed.isEmpty && skipped.isEmpty && !cancelled;
}

/// Progress of a running add.
class AddProgress {
  const AddProgress({
    required this.destination,
    required this.done,
    required this.total,
    required this.bytes,
    required this.totalBytes,
  });
  final String destination;
  final int done;
  final int total;
  final int bytes;
  final int totalBytes;
}

/// Add files, Add folder and Save to AnJ Cloud on the UI side (spec #43):
/// evaluates a selection through the worker, then copies item by item: the
/// platform makes each source readable, the worker copies it into the root.
/// One add at a time per profile ([begin]).
class AddFiles extends ChangeNotifier {
  AddFiles(
    this.port, {
    required this.command,
    required this.cancelWorker,
    required this.root,
  });
  final AddFilesPort port;
  final AddCommand command;
  final void Function(String run) cancelWorker;

  /// The synchronized root's path, for the free-space check.
  final String? Function() root;

  bool _busy = false;
  bool get busy => _busy;
  AddProgress? progress;
  String? _run;
  bool _cancelled = false;

  /// Claims the one add of this profile; false while another runs.
  bool begin() {
    if (_busy) return false;
    _busy = true;
    _cancelled = false;
    notifyListeners();
    return true;
  }

  void end() {
    _busy = false;
    progress = null;
    _run = null;
    notifyListeners();
  }

  /// Stops the folder listing or the copy in progress. The file being copied
  /// leaves nothing behind; completed files stay.
  void cancel() {
    _cancelled = true;
    port.cancelListing();
    port.cancelOpen();
    final run = _run;
    if (run != null) cancelWorker(run);
  }

  bool get cancelled => _cancelled;

  /// Evaluates [sources] for [destination] before anything is written.
  Future<AddPlan> check(String destination, List<AddSource> sources) async {
    final rootPath = root();
    int? free;
    if (rootPath != null) {
      try {
        free = await port.freeBytes(rootPath);
      } catch (_) {
        free = null;
      }
    }
    final data = await command('addCheck', {
      'destination': destination,
      'items': [for (final source in sources) source.toCheck()],
      'free': ?free,
    });
    return AddPlan(destination, sources, data);
  }

  /// Copies what [plan] allows, in order (folders before their contents).
  Future<AddResult> run(AddPlan plan) async {
    final result = AddResult(plan.destination);
    final run = _run = uniqueId();
    // Selection folder -> its path in the root.
    final placed = <String, String>{};
    var done = 0, bytes = 0;
    String? stop;
    void report() {
      progress = AddProgress(
        destination: plan.destination,
        done: done,
        total: plan.files,
        bytes: bytes,
        totalBytes: plan.bytes,
      );
      notifyListeners();
    }

    report();
    try {
      for (var i = 0; i < plan.sources.length; i++) {
        final source = plan.sources[i];
        final verdict = plan.verdicts[i];
        final path = source.path;
        void skip(String reason) {
          if (verdict['listed'] == true) {
            result.skipped.add((name: path, reason: reason));
          }
        }

        if (verdict['skip'] != null) {
          skip(
            AddSkip.values.byName(verdict['skip'] as String).text(plan.limit),
          );
          continue;
        }
        final selectionParent = p.posix.dirname(path) == '.'
            ? ''
            : p.posix.dirname(path);
        final top = selectionParent.isEmpty;
        final parent = top ? plan.destination : placed[selectionParent];
        // Inside a folder that was not added: listed with that folder.
        if (parent == null) continue;
        if (_cancelled) {
          result.cancelled = true;
          stop ??= AddSkip.cancelled.text(plan.limit);
        }
        if (stop != null) {
          if (top) result.skipped.add((name: path, reason: stop));
          continue;
        }
        final name = p.posix.basename(path);
        try {
          final String added;
          if (source.directory) {
            added =
                (await command('addFolder', {
                      'parent': parent,
                      'name': name,
                      'number': top,
                    }))['path']
                    as String;
            placed[path] = added;
            result.folders++;
          } else {
            final readable = await port.open(source, limit: plan.limit);
            try {
              added =
                  (await command('addFile', {
                        'parent': parent,
                        'name': name,
                        'source': readable,
                        'number': top,
                        'run': run,
                      }))['path']
                      as String;
            } finally {
              await port.release(readable);
            }
            result.files++;
            done++;
            bytes += source.size ?? 0;
            report();
          }
          final given = p.posix.basename(added);
          if (given != name) {
            result.renamed.add((name: path, addedAs: given));
          }
        } on AddSourceFailure catch (error) {
          if (error.code == 'cancelled') {
            result.cancelled = true;
            stop = AddSkip.cancelled.text(plan.limit);
            skip(stop);
            continue;
          }
          skip(
            (AddSkip.byCode(error.code) ?? AddSkip.unreadable).text(plan.limit),
          );
          done++;
          report();
        } on DocumentsFailure catch (error) {
          final known = AddSkip.byCode(error.code);
          if (known == AddSkip.cancelled) {
            result.cancelled = true;
            stop = known!.text(plan.limit);
            skip(stop);
            continue;
          }
          final reason = known?.text(plan.limit) ?? error.message;
          skip(reason);
          // The phone cannot take more now: the rest is not tried.
          if (const {'paused', 'unavailable'}.contains(error.code)) {
            stop = reason;
          }
          if (!source.directory) {
            done++;
            report();
          }
        }
      }
    } finally {
      _run = null;
      unawaited(command('addDone', {'run': run}).then((_) {}, onError: (_) {}));
    }
    return result;
  }
}
