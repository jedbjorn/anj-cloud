/// The documents provider's boundary needs and its failure type (spec #28
/// A5), free of Flutter so the sync worker and pure-Dart processes can use
/// them (see `documents.dart` for the provider and allowlist ports).
library;

/// The two boundary operations a documents provider needs beyond
/// [RootFilesystem]: a confined read-only descriptor of a root file and an
/// exclusive create. Both are descriptor-relative and follow no symlink.
abstract interface class DocumentsFilesystem {
  /// A read-only descriptor of the regular file at [path] beneath [fd].
  int openRead(int fd, String path);

  /// Creates the absent regular file [path] beneath [fd] (mode 0600) and
  /// returns a read-write descriptor; an existing name is never replaced.
  int createExclusive(int fd, String path);
}

/// A refused documents command. [code] is one of `denied`, `notFound`,
/// `exists`, `readOnly`, `paused`, `busy`, `unavailable` or `refused`.
class DocumentsFailure implements Exception {
  const DocumentsFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
