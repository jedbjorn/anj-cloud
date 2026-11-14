// Spec #52 AC0 on the emulator (seat E), task #44: the shared-storage
// primitives the phone folders rely on, exercised inside the app process
// (untrusted_app, its seccomp filter and FUSE permission checks, All files
// access from appops) through the real libanj_rootfs.so. `run-as` cannot
// reach shared storage at all, so it is no stand-in for the app.
//
//   tool/android/build_apk.sh <n> -t integration_test/android_phone_folders_ac0_test.dart
//   ANJ_APK=... OUT=... anj-emu-run <TAG> <n> tool/android/ac0/emu_ac0_app.sh
//
// Every finding is a logcat line `ANJ-AC0 <check> ok|fail|info <detail>`.
// The host script answers the hand-offs: it makes changes as another uid
// (adb shell) after `ANJ-AC0 wait-other <dir>`, revokes access after
// `ANJ-AC0 wait-revoke`, and drops a `.go` file in the work folder each time.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const shared = '/storage/emulated/0';
const pkg = 'cloud.anj.anj_cloud.qa';

void say(String check, String verdict, String detail) =>
    // ignore: avoid_print
    print('ANJ-AC0 $check $verdict $detail');

String describe(Object e) => e is FileSystemException
    ? '${e.message} ${e.path ?? ''} errno=${e.osError?.errorCode}'
    : '$e';

typedef _FsyncC = Int32 Function(Int32);
typedef _FsyncD = int Function(int);
typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD = int Function(Pointer<Utf8>, int);
typedef _RenameC = Int32 Function(
  Int32,
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
  Uint32,
);
typedef _RenameD = int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

final libc = DynamicLibrary.process();
final _fsync = libc.lookupFunction<_FsyncC, _FsyncD>('fsync');
final _open = libc.lookupFunction<_OpenC, _OpenD>('open');
final _close = libc.lookupFunction<_FsyncC, _FsyncD>('close');
final _renameat2 = libc.lookupFunction<_RenameC, _RenameD>('renameat2');
final _errno = libc.lookupFunction<_ErrnoC, _ErrnoD>('__errno');
const atFdCwd = -100;
const oRdonly = 0, oDirectory = 0x10000;

/// renameat2(AT_FDCWD, from, AT_FDCWD, to, flags): 0 or the errno.
int rename2(String from, String to, int flags) {
  final f = from.toNativeUtf8(), t = to.toNativeUtf8();
  try {
    return _renameat2(atFdCwd, f, atFdCwd, t, flags) == 0 ? 0 : _errno().value;
  } finally {
    malloc.free(f);
    malloc.free(t);
  }
}

int fsyncDir(String path) {
  final p = path.toNativeUtf8();
  try {
    final fd = _open(p, oRdonly | oDirectory);
    if (fd < 0) return _errno().value;
    final r = _fsync(fd) == 0 ? 0 : _errno().value;
    _close(fd);
    return r;
  } finally {
    malloc.free(p);
  }
}

/// One second of 8 kHz mono 16-bit silence: a valid WAV the media scanner can parse.
List<int> wav() {
  const rate = 8000, bytes = rate * 2;
  final b = BytesBuilder();
  void u32(int v) =>
      b.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255]);
  void u16(int v) => b.add([v & 255, v >> 8 & 255]);
  b.add('RIFF'.codeUnits);
  u32(36 + bytes);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(bytes);
  b.add(List.filled(bytes, 0));
  return b.takeBytes();
}

Future<void> waitForGo(String dir, String what) async {
  final go = File('$dir/.go-$what');
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (!go.existsSync() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  say(
    'handoff',
    go.existsSync() ? 'info' : 'fail',
    '$what ${go.existsSync() ? 'received' : 'timed out'}',
  );
}

Map<String, dynamic>? entry(AndroidRootFs fs, int root, String path) {
  for (final item in fs.scan(root)) {
    if (item['path'] == path) return item;
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('AC0 shared-storage primitives', () async {
    final fs = AndroidRootFs();
    say('identity', 'info', 'pid=$pid');
    // 1. No-follow walk of the phone folder.
    late int music;
    try {
      music = fs.openRoot('$shared/Music');
      final info = fs.rootInfo(music);
      final items = fs.scan(music);
      say(
        'walk',
        'ok',
        '$shared/Music identity=${info.identity} stable=${info.stable} '
            'entries=${items.length} magic=0x${fs.fsMagic(music, '').toRadixString(16)}',
      );
    } catch (e) {
      say('walk', 'fail', describe(e));
      // Without access: what does a plain listing show?
      try {
        final names = Directory('$shared/Music')
            .listSync()
            .map((e) => e.path)
            .toList();
        say(
          'listing_without_access',
          'info',
          'dart:io lists ${names.length}: ${names.take(5)}',
        );
      } catch (e2) {
        say('listing_without_access', 'info', 'dart:io refuses: $e2');
      }
      return;
    }
    // What this uid sees of files another uid made (the script puts two in
    // Music/anj-ac0-seen): with access, both; without it, scoped storage's view.
    try {
      final seen = fs
          .scan(music)
          .where((i) => (i['path'] as String).startsWith('anj-ac0-seen/'))
          .map((i) => i['path'])
          .toList();
      say('other_uid_files_visible', 'info', '${seen.length}: $seen');
    } catch (e) {
      say('other_uid_files_visible', 'info', 'scan refused: ${describe(e)}');
    }
    final work = 'anj-ac0-${DateTime.now().millisecondsSinceEpoch}';
    final workPath = '$shared/Music/$work';
    fs.makeDir(music, work);
    final scanned = entry(fs, music, work);
    say('mkdir', scanned == null ? 'fail' : 'ok', '$workPath ${scanned ?? ''}');

    // Symlinks in shared storage.
    try {
      Link('$workPath/link').createSync('/data');
      final type = FileSystemEntity.typeSync(
        '$workPath/link',
        followLinks: false,
      );
      String through;
      try {
        fs.closeFd(fs.openRoot('$workPath/link'));
        through = 'FOLLOWED';
      } catch (e) {
        through = 'refused (${describe(e)})';
      }
      say(
        'symlink',
        through.startsWith('refused') ? 'ok' : 'fail',
        'created as $type; walk through it $through',
      );
      Link('$workPath/link').deleteSync();
    } catch (e) {
      say('symlink', 'ok', 'cannot be created in shared storage: $e');
    }

    // 2. Exclusive create, through dart:io and through the boundary.
    File('$workPath/excl.txt').createSync(exclusive: true);
    try {
      File('$workPath/excl.txt').createSync(exclusive: true);
      say('exclusive_create', 'fail', 'second create succeeded');
    } on FileSystemException catch (e) {
      say(
        'exclusive_create',
        e.osError?.errorCode == 17 ? 'ok' : 'fail',
        'second create: ${describe(e)}',
      );
    }
    try {
      final fd = fs.createExclusive(music, '$work/boundary.txt');
      fs.closeFd(fd);
      try {
        fs.createExclusive(music, '$work/boundary.txt');
        say(
          'exclusive_create_boundary',
          'fail',
          'second anj_create_file succeeded',
        );
      } catch (e) {
        say(
          'exclusive_create_boundary',
          'ok',
          'anj_create_file twice: ${describe(e)}',
        );
      }
    } catch (e) {
      say('exclusive_create_boundary', 'fail', describe(e));
    }

    // 3. Staging candidates and the atomic rename from staging.
    final stages = <String, String>{
      'app-media': '$shared/Android/media/$pkg/anj-staging',
      'hidden-top': '$shared/.anj-cloud-staging',
      'app-private':
          '${Directory.systemTemp.resolveSymbolicLinksSync()}/anj-ac0-stage',
    };
    for (final MapEntry(key: name, value: stage) in stages.entries) {
      try {
        Directory(stage).createSync(recursive: true);
        final stageFd = fs.openRoot(stage);
        final rootInfo = fs.rootInfo(stageFd);
        say(
          'stage_$name',
          'info',
          '$stage identity=${rootInfo.identity} stable=${rootInfo.stable} '
              'mode=${FileStat.statSync(stage).modeString()}',
        );
        // Owned-directory check of the release guard (uid owner, mode 0700).
        fs.privateDir(stage);
        say(
          'stage_${name}_mode',
          'info',
          'after chmod 0700: ${FileStat.statSync(stage).modeString()}',
        );
        final guard = fs.releaseGuard();
        // An ordinary install: the staged file renamed into place, no replace.
        final staged = File('$stage/s1.bin')
          ..writeAsBytesSync(List.filled(1 << 20, 7), flush: true);
        final before = staged.statSync();
        try {
          guard.restore(music, '$work/installed-$name.bin', stageFd, 's1.bin');
          final after = entry(fs, music, '$work/installed-$name.bin');
          say(
            'install_rename_$name',
            'ok',
            'restore (RENAME_NOREPLACE) ok; size=${after?['size']} '
                'staged size=${before.size}',
          );
        } catch (e) {
          say('install_rename_$name', 'fail', 'restore: ${describe(e)}');
        }
        // Raw renameat2 NOREPLACE and plain rename, to tell the call from the guard's checks.
        File('$stage/s2.bin').writeAsStringSync('two', flush: true);
        final noreplace = rename2(
          '$stage/s2.bin',
          '$workPath/raw-$name.bin',
          1,
        );
        say(
          'renameat2_noreplace_$name',
          noreplace == 0 ? 'ok' : 'fail',
          'errno=$noreplace',
        );
        File('$stage/s3.bin').writeAsStringSync('three', flush: true);
        final onto = rename2('$stage/s3.bin', '$workPath/raw-$name.bin', 1);
        final ontoContent = File('$workPath/raw-$name.bin').existsSync()
            ? File('$workPath/raw-$name.bin').readAsStringSync()
            : '<missing>';
        say(
          'renameat2_noreplace_existing_$name',
          onto == 17 ? 'ok' : 'fail',
          'errno=$onto, existing content now "$ontoContent"',
        );
        final plain = rename2('$stage/s3.bin', '$workPath/plain-$name.bin', 0);
        say('rename_plain_$name', plain == 0 ? 'ok' : 'fail', 'errno=$plain');
        // A folder published from staging (installDirectory).
        Directory('$stage/d1').createSync();
        final dir = rename2('$stage/d1', '$workPath/dir-$name', 1);
        say('rename_directory_$name', dir == 0 ? 'ok' : 'fail', 'errno=$dir');
        // The guard's copy-install (link_file: copy beside the staged file, then NOREPLACE).
        File('$stage/s4.bin').writeAsStringSync('four', flush: true);
        try {
          fs.install(music, '$work/copied-$name.bin', '$stage/s4.bin');
          say(
            'install_copy_$name',
            'ok',
            'anj_install (copy then no-replace rename) ok',
          );
        } catch (e) {
          say('install_copy_$name', 'fail', describe(e));
        }
        // Quarantine: a phone file moved back into staging (release, recovery).
        File('$workPath/q-$name.bin').writeAsStringSync('q', flush: true);
        try {
          fs.quarantine(music, '$work/q-$name.bin', '$stage/q.bin');
          say('quarantine_$name', 'ok', 'phone file renamed into staging');
        } catch (e) {
          say('quarantine_$name', 'fail', describe(e));
        }
        fs.closeFd(stageFd);
      } catch (e) {
        say('stage_$name', 'fail', describe(e));
      }
    }

    // Between two phone folders, and within one (renameExclusive with identity).
    try {
      final top = fs.openRoot(shared);
      File('$workPath/cross.txt').writeAsStringSync('cross', flush: true);
      final id = fs.fileIdentity(top, 'Music/$work/cross.txt');
      fs.renameExclusive(
        top,
        'Music/$work/cross.txt',
        'Documents/$work-cross.txt',
        id,
      );
      final id2 = fs.fileIdentity(top, 'Documents/$work-cross.txt');
      say(
        'rename_between_phone_folders',
        'ok',
        'Music -> Documents; identity $id -> $id2',
      );
      File('$shared/Documents/$work-cross.txt').deleteSync();
      fs.closeFd(top);
    } catch (e) {
      say('rename_between_phone_folders', 'fail', describe(e));
    }
    try {
      File('$workPath/r1.txt').writeAsStringSync('r', flush: true);
      final id = fs.fileIdentity(music, '$work/r1.txt');
      fs.renameExclusive(music, '$work/r1.txt', '$work/r2.txt', id);
      say(
        'rename_exclusive_in_folder',
        'ok',
        'identity kept: ${fs.fileIdentity(music, '$work/r2.txt') == id}',
      );
    } catch (e) {
      say('rename_exclusive_in_folder', 'fail', describe(e));
    }

    // Identity stability: the same file seen by two scans, and after a reopen.
    final a = entry(fs, music, '$work/excl.txt');
    final music2 = fs.openRoot('$shared/Music');
    final b = entry(fs, music2, '$work/excl.txt');
    say(
      'identity_stable',
      a?['inode'] == b?['inode'] && a?['volume'] == b?['volume']
          ? 'ok'
          : 'fail',
      'volume=${a?['volume']} inode=${a?['inode']} vs ${b?['volume']} ${b?['inode']}; '
          'root ${fs.rootInfo(music).identity} vs ${fs.rootInfo(music2).identity}',
    );
    fs.closeFd(music2);

    // Case sensitivity.
    File('$workPath/Case.txt').writeAsStringSync('case', flush: true);
    final lower = File('$workPath/case.txt').existsSync();
    String second;
    try {
      File('$workPath/CASE.txt').createSync(exclusive: true);
      second = 'CASE.txt created beside it';
    } catch (e) {
      second = 'CASE.txt refused: ${describe(e)}';
    }
    say(
      'case',
      'info',
      '${lower ? 'case-INSENSITIVE' : 'case-sensitive'}; $second; '
          'caseInsensitive()=${fs.caseInsensitive('$shared/Music')}',
    );

    // Ordinary real-world names.
    final names = [
      'Björk – Jóga.mp3',
      '日本語のファイル.txt',
      'café-nfd.txt',
      'emoji 🎵.txt',
      'colon: x.txt',
      'quote " x.txt',
      'star * x.txt',
      'question ? x.txt',
      'lt < gt > x.txt',
      'pipe | x.txt',
      r'back\slash.txt',
      'trailing dot.',
      ' leading space.txt',
      'trailing space ',
      '.hidden',
      '#hash %percent&amp.txt',
      '${'a' * 250}.txt',
    ];
    for (final n in names) {
      try {
        File('$workPath/$n').writeAsStringSync('n', flush: true);
        final listed = Directory(workPath)
            .listSync()
            .any((e) => e.path == '$workPath/$n');
        final viaScan = entry(fs, music, '$work/$n') != null;
        say(
          'name',
          listed && viaScan ? 'ok' : 'fail',
          '"${n.length > 40 ? '${n.substring(0, 12)}…(${n.length})' : n}" listed=$listed scan=$viaScan',
        );
      } catch (e) {
        say('name', 'fail', '"$n" ${describe(e)}');
      }
    }

    // The same characters in folder names, and a control character.
    for (final n in [
      'folder: x',
      'folder? x',
      'tab\tname.txt',
      'del\u007fname.txt',
    ]) {
      try {
        if (n.startsWith('folder')) {
          Directory('$workPath/$n').createSync();
        } else {
          File('$workPath/$n').writeAsStringSync('n', flush: true);
        }
        say('name', 'ok', '"$n" created');
      } catch (e) {
        say(
          'name',
          'fail',
          '"${n.replaceAll('\t', r'\t').replaceAll('\u007f', r'\x7f')}" ${describe(e)}',
        );
      }
    }

    // Lease: the Linux release guard (F_SETLEASE F_WRLCK) on a phone file.
    try {
      final guard = fs.releaseGuard();
      final info = guard.info(music, '$work/excl.txt');
      say('owner', 'info', 'phone file owned by this uid: ${info.owned}');
      final g = guard.guard(music, '$work/excl.txt', info, links: info.links);
      guard.close(g);
      say(
        'lease',
        'ok',
        'anj_guard_open (F_SETLEASE F_WRLCK) on a phone file works',
      );
    } catch (e) {
      say('lease', 'fail', describe(e));
    }
    // A file another uid created (adb shell) is the common case for a lease.
    final fsyncResult = fsyncDir(workPath);
    say(
      'fsync_directory',
      fsyncResult == 0 ? 'ok' : 'fail',
      'errno=$fsyncResult',
    );

    // Media library after a path write and after a rename from .nomedia staging.
    File('$workPath/probe-indexed.wav').writeAsBytesSync(wav(), flush: true);
    final mediaStage = stages['app-media']!;
    File('$mediaStage/.nomedia').writeAsStringSync('');
    File('$mediaStage/staged-media.wav').writeAsBytesSync(wav(), flush: true);
    say('wait-media', 'info', '$workPath $mediaStage');
    await waitForGo(workPath, 'media1');
    final r = rename2(
      '$mediaStage/staged-media.wav',
      '$workPath/renamed-in.wav',
      1,
    );
    say('media_rename', r == 0 ? 'ok' : 'fail', 'errno=$r');
    say('wait-media2', 'info', workPath);
    await waitForGo(workPath, 'media2');

    // inotify for changes another uid makes.
    final events = <String>[];
    final sub = Directory(workPath)
        .watch()
        .listen((e) => events.add('${e.type}:${e.path.split('/').last}'));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    say('wait-other', 'info', workPath);
    await waitForGo(workPath, 'other');
    await Future<void>.delayed(const Duration(seconds: 3));
    await sub.cancel();
    say(
      'inotify_other_uid',
      events.any((e) => e.contains('by-shell')) ? 'ok' : 'fail',
      events.join(' '),
    );
    // A lease on the file adb shell wrote (another owner).
    try {
      final guard = fs.releaseGuard();
      final info = guard.info(music, '$work/kept-by-shell.txt');
      final g = guard.guard(
        music,
        '$work/kept-by-shell.txt',
        info,
        links: info.links,
      );
      guard.close(g);
      say('lease_other_owner', 'ok', 'owned=${info.owned}');
    } catch (e) {
      say('lease_other_owner', 'fail', describe(e));
    }

    // Revocation while running: Android kills the app ("MANAGE_EXTERNAL_STORAGE
    // changed"); the script records it. The no-access view is the second start.
    say('wait-revoke', 'info', workPath);
    await Future<void>.delayed(const Duration(seconds: 8));
    say('done', 'info', workPath);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
