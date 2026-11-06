import 'dart:io';

import '../core/ports/commit_durability.dart';
import 'macos/macos_commit_durability.dart';

/// The running platform's manifest [CommitDurability] (flag SC-051): macOS
/// groups manifest commits behind barriers; every other platform keeps a
/// durable commit each time (null). Like `platformWatchers()`, a separate
/// selector importing no Flutter library, because the manifest also opens
/// in pure-Dart processes (the crash fixtures under tool/).
CommitDurability? platformCommitDurability() =>
    Platform.isMacOS ? const MacosCommitDurability() : null;
