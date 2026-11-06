/// Port: how a manifest commit is made durable between commit points
/// (flag SC-051, refining decision #129 for the manifest).
///
/// Where a full media flush costs milliseconds (macOS F_FULLFSYNC, about
/// 5 ms against 0.3 ms for fsync), the manifest groups its commits: each
/// commit is ordered before every later write ([barrier], F_BARRIERFSYNC),
/// and a full flush ([flush], F_FULLFSYNC) makes every earlier write durable
/// at each commit point, which includes the moment before any destructive
/// root change (decision #137 (1)). A process crash loses nothing either
/// way; a power loss loses at most the additive work since the last flush.
///
/// Linux has none: every SQLite commit already reaches stable storage.
library;

abstract interface class CommitDurability {
  /// Orders everything written to [path] (and the device before it) ahead
  /// of every later write. Throws a `FileSystemException` when it cannot.
  void barrier(String path);

  /// Makes every earlier write on the device holding [path] durable.
  /// Throws a `FileSystemException` when it cannot.
  void flush(String path);
}
