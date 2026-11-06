import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../state/manifest.dart';

/// The name of the desktop shortcut to the synced folder (spec #34 P2).
const desktopShortcutName = 'AnJ Cloud';

/// Spec #34 P2: makes the symbolic link **AnJ Cloud** to the synced folder
/// [target] in the [desktop] directory (null: there is none) and returns the
/// outcome to record in `desktopShortcut`: `created:<link>`,
/// `foreign:<path>` (an entry of that name exists and is never replaced),
/// `none` or `failed`. The calls are asynchronous, so they run off the UI
/// isolate's thread. Any refusal, whatever form the call reports it in (on
/// macOS a refused Desktop is not always a [FileSystemException]), is
/// `failed`: the shortcut never fails the caller (mac-test run 6).
Future<String> makeDesktopShortcut(String target, String? desktop) async {
  try {
    if (desktop == null) return 'none';
    final link = Link(p.join(desktop, desktopShortcutName));
    final type = await FileSystemEntity.type(link.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      return type == FileSystemEntityType.link && await link.target() == target
          ? 'created:${link.path}'
          : 'foreign:${link.path}';
    }
    await link.create(target);
    return 'created:${link.path}';
  } catch (_) {
    return 'failed';
  }
}

/// Records [outcome] in `desktopShortcut`, so a link the user deleted is
/// never recreated. A failed save (macOS: another path holds the manifest,
/// "database is locked") leaves it unrecorded, which reads like no
/// shortcut, and never fails the caller (PR #100 review L1).
void saveDesktopShortcutOutcome(Manifest store, String outcome) {
  try {
    store.setSetting('desktopShortcut', outcome);
  } catch (error) {
    stderr.writeln('anj-cloud: desktop shortcut outcome not saved: $error');
  }
}

/// After the synced folder moved from [from] to [to]: the shortcut this
/// profile made (recorded `created:<link>`) that still points at [from] is
/// pointed at [to], replacing only that exact link: a new link is made
/// under a fresh hidden name beside it and renamed over it. Returns
/// `updated:<link>` when it was, `stale:<link>` when that link still points
/// at [from] (it could not be replaced), and null when there is no such
/// link (none recorded, or the user changed or removed it).
Future<String?> retargetDesktopShortcut(
  Manifest store,
  String from,
  String to,
) async {
  final recorded = store.setting('desktopShortcut');
  if (recorded == null || !recorded.startsWith('created:')) return null;
  final path = recorded.substring('created:'.length);
  try {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.link ||
        await Link(path).target() != from) {
      return null;
    }
  } catch (_) {
    return null;
  }
  try {
    final random = Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      final temporary = Link(
        p.join(
          p.dirname(path),
          '.$desktopShortcutName.anj-cloud-move-'
          '${random.nextInt(1 << 32).toRadixString(16)}',
        ),
      );
      // Never an existing entry: only a name this call created is renamed.
      if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      await temporary.create(to);
      try {
        await temporary.rename(path);
      } catch (_) {
        // Only the link this call just made is removed.
        await temporary.delete();
        rethrow;
      }
      return 'updated:$path';
    }
  } catch (_) {
    // Reported below as stale.
  }
  return 'stale:$path';
}
