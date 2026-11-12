/// Port: the platform's file picker and share target for Add files, Add
/// folder and "Save to AnJ Cloud" (spec #43). Android implements it
/// (`lib/platform/android/android_add_files.dart`) with the system picker's
/// one-time read grant and the Share sheet; other platforms have none yet
/// and the menu entries are absent there.
library;

/// One item picked or shared, as the platform describes it.
class AddSource {
  const AddSource({
    required this.path,
    this.directory = false,
    this.size,
    this.virtual = false,
    this.reference,
  });

  /// Relative to the selection: 'a.txt', or 'Tree/sub/b.txt' inside a
  /// picked folder 'Tree'. Parents come before their children.
  final String path;
  final bool directory;

  /// Null when the source reports no size.
  final int? size;

  /// The source has no byte stream (Android's virtual documents).
  final bool virtual;

  /// The platform's handle to read it (Android: a content URI).
  final String? reference;

  Map<String, Object?> toCheck() => {
    'path': path,
    'directory': directory,
    'size': ?size,
    'virtual': virtual,
  };
}

/// A share received from another app.
class SharedItems {
  const SharedItems(this.items);

  /// The shared files; empty when the share carried no file (text or a link).
  final List<AddSource> items;
}

/// Why a source could not be read; [code] is `overLimit`, `unreadable` or
/// `cancelled`.
class AddSourceFailure implements Exception {
  const AddSourceFailure(this.code);
  final String code;
  @override
  String toString() => code;
}

abstract interface class AddFilesPort {
  /// The system picker, several files of any type; null when cancelled.
  Future<List<AddSource>?> pickFiles();

  /// The system folder picker; its name, or null when cancelled.
  Future<String?> pickFolder();

  /// Everything inside the folder [pickFolder] returned, the folder itself
  /// first; null when [cancelListing] stopped it.
  Future<List<AddSource>?> listFolder();
  void cancelListing();

  /// A readable path holding exactly [source]'s bytes, read through its
  /// grant; stops with [AddSourceFailure] `overLimit` once more than [limit]
  /// bytes arrive. Hand it back to [release] when done.
  Future<String> open(AddSource source, {required int limit});

  /// Stops the [open] in progress (`cancelled`).
  void cancelOpen();
  Future<void> release(String path);

  /// Free bytes on the volume holding [path], or null when unknown.
  Future<int?> freeBytes(String path);

  /// A share that started or reached the app, once; null when there is none.
  Future<SharedItems?> takeShare();

  /// Fires when a share arrives while the app runs; then call [takeShare].
  Stream<void> get shareArrived;

  /// Returns to the app the share came from.
  Future<void> leaveShare();
}
