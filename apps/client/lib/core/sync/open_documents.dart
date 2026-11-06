import 'dart:io';

import '../ports/release_guard.dart';

/// One descriptor the documents provider handed to another app.
class OpenDocument {
  OpenDocument(this.path, this.identity, {required this.write, this.working});
  final String path;
  final String identity;
  final bool write;

  /// The staged name when the descriptor is on a working copy.
  final String? working;
}

/// The provider's open-descriptor registry (spec #28 Native Boundary): every
/// descriptor handed to another app is recorded by file identity until the
/// app closes it, and [RegisteredReleaseGuard] refuses Cloud release,
/// quarantine and unlink of that file meanwhile.
///
/// On Android the F_SETLEASE guard already refuses a file another process
/// holds open (A1, decision #123 (3)), so this is defence in depth. It is
/// per process and in memory: after the app process dies an app's open
/// descriptor is still seen by the lease guard, which stays the primary
/// rule. A revoke does not close a descriptor already handed out (A1 R2);
/// this registry, not the revoke, governs release.
class OpenDocuments {
  final Map<String, OpenDocument> _byToken = {};

  void add(String token, OpenDocument document) => _byToken[token] = document;
  OpenDocument? remove(String token) => _byToken.remove(token);
  bool isOpen(String identity) =>
      _byToken.values.any((d) => d.identity == identity);
  bool isPathOpen(String path) => _byToken.values.any((d) => d.path == path);
  int get length => _byToken.length;
}

/// The worker isolate's registry (isolate-local: one per engine).
final openDocuments = OpenDocuments();

/// A [ReleaseGuard] that also refuses any file the registry holds open.
/// Every guarded release (Cloud release, Finish editing, recovery and
/// staging reclamation) takes a guard first, so this one check covers them.
class RegisteredReleaseGuard implements ReleaseGuard {
  RegisteredReleaseGuard(this.inner, [OpenDocuments? registry])
    : registry = registry ?? openDocuments;
  final ReleaseGuard inner;
  final OpenDocuments registry;

  static const busyMessage =
      'Cloud pending: filesystem guard refused; file is busy, changed, linked or unsupported.';

  void _refuseOpen(String identity) {
    if (registry.isOpen(identity)) {
      throw const FileSystemException(
        busyMessage,
        'open in another app',
        OSError('open in another app', 11),
      );
    }
  }

  @override
  int guard(
    int directory,
    String path,
    NativeFileInfo expected, {
    required int links,
  }) {
    _refuseOpen(expected.identity);
    final fd = inner.guard(directory, path, expected, links: links);
    try {
      // Opened between the check and the lease: still refused.
      _refuseOpen(inner.infoFd(fd).identity);
    } catch (_) {
      inner.close(fd);
      rethrow;
    }
    return fd;
  }

  @override
  void quarantine(int guardFd, int root, String path, int stage, String name) {
    _refuseOpen(inner.infoFd(guardFd).identity);
    inner.quarantine(guardFd, root, path, stage, name);
  }

  @override
  void unlink(int guardFd, int stage, String name) {
    _refuseOpen(inner.infoFd(guardFd).identity);
    inner.unlink(guardFd, stage, name);
  }

  @override
  ReleaseGuardStrength get strength => inner.strength;
  @override
  NativeFileInfo preview(int directory, String name) =>
      inner.preview(directory, name);
  @override
  NativeFileInfo info(int directory, String path) =>
      inner.info(directory, path);
  @override
  NativeFileInfo infoFd(int fd) => inner.infoFd(fd);
  @override
  int create(int directory, String name) => inner.create(directory, name);
  @override
  void valid(int fd) => inner.valid(fd);
  @override
  void close(int fd) => inner.close(fd);
  @override
  String hash(int fd, {String purpose = 'eviction'}) =>
      inner.hash(fd, purpose: purpose);
  @override
  void preserve(int root, String path, int stage, String name) =>
      inner.preserve(root, path, stage, name);
  @override
  void install(int root, String path, int stage, String name) =>
      inner.install(root, path, stage, name);
  @override
  void restore(int root, String path, int stage, String name) =>
      inner.restore(root, path, stage, name);
}
