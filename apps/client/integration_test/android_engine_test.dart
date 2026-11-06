// Spec #28 A2 on the VM host emulator (seat E): the shared Dart engine against
// the real Android libanj_rootfs.so inside the app sandbox (untrusted_app,
// seccomp), plus the per-pass hash cost of decision #123 (6).
//
//   anj-android flutter test integration_test/android_engine_test.dart \
//     -d <emulator serial>          (QA build cloud.anj.anj_cloud.qa)
//
// Results go to stdout as `ANJ-A2 ...` lines; tool/android/emu_engine.sh
// collects them. Suites that start host processes (crash fixtures run with
// `dart run`, python helpers) are listed in [hostOnly] and are not run here:
// the device has no Dart SDK.
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/platform/android/keystore_secrets.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_platform_adapters.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/android_adapters_test.dart' as android_adapters;
import '../test/android_storage_test.dart' as android_storage;
import '../test/entry_projection_test.dart' as entry_projection;
import '../test/event_driven_hashing_test.dart' as event_driven_hashing;
import '../test/profile_lifetime_test.dart' as profile_lifetime;
import '../test/sharing_engine_test.dart' as sharing_engine;
import '../test/sync_lifecycle_test.dart' as sync_lifecycle;
import '../test/sync_test.dart' as sync;
import '../test/upload_limit_test.dart' as upload_limit;

/// Shared engine suites that need host processes; the VM host runs them (check.sh).
const hostOnly = [
  'staging_release_test (crash fixtures via dart run)',
  'recover_dismiss_test (crash fixtures via dart run)',
  'eviction_test (crash fixtures via dart run)',
  'edit_completion_test (crash fixtures via dart run)',
  'local_watch_test (python and ln helpers)',
  'incremental_index_test (python and touch helpers)',
  'local_watch_adversarial_test (The VM host disk fixtures; asserts the stamp fast '
      'path, which is off on Android)',
  'root_identity_test (tmpfs fixtures with an unstable volume key; app '
      'storage is ext4 with a stable fsid, checked under platform)',
];

/// Dart's systemTemp on Android is under /data/user/0, a symlink to
/// /data/data in the app's view. The boundary refuses a root path through a
/// symlink (as on Linux), and the shared suites build their roots under
/// systemTemp, so they get its canonical form, as the app does for its own
/// files directory (MobileStorage, decision #123 (5)).
final class _CanonicalTemp extends IOOverrides {
  _CanonicalTemp(this.path);
  final String path;
  @override
  Directory getSystemTempDirectory() => Directory(path);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final temp = Directory.systemTemp;
  final canonicalTemp = temp.resolveSymbolicLinksSync();
  // ignore: avoid_print
  print('ANJ-A2 systemTemp ${temp.path} -> $canonicalTemp');
  IOOverrides.global = _CanonicalTemp(canonicalTemp);

  group('platform', () {
    test('selectors and library', () {
      expect(Platform.isAndroid, isTrue);
      expect(platformAdapters(), isA<AndroidPlatformAdapters>());
      expect(platformWatchers(), isA<AndroidChangeWatchers>());
      final fs = AndroidRootFs();
      expect(fs.writeback(), isNull);
      // The root on app storage: a stable on-disk volume key (ext4 or f2fs
      // fsid) with the birth time, so a recreated root is told apart.
      final fixture = Directory.systemTemp.createTempSync('anj-identity-');
      final tree = RootTree.setup(fixture.path, 'identity', fs);
      try {
        final info = fs.rootInfo(tree.fd);
        // ignore: avoid_print
        print(
          'ANJ-A2 root ${tree.root.path} magic=0x'
          '${fs.fsMagic(tree.fd, '').toRadixString(16)} identity=${info.identity} '
          'stable=${info.stable}',
        );
        expect(info.stable, isTrue);
        expect(
          info.identity,
          matches(RegExp(r'^f[0-9a-f]{16}:\d+:b\d+\.\d+$')),
        );
        // Through the symlinked spelling the root is refused, not followed.
        final aliased = tree.root.path.replaceFirst(
          '/data/data/',
          '/data/user/0/',
        );
        if (aliased != tree.root.path) {
          expect(
            () => fs.openRoot(aliased),
            throwsA(isA<FileSystemException>()),
          );
        }
      } finally {
        tree.close();
        fixture.deleteSync(recursive: true);
      }
      // /proc/sys/vm is unreadable in the sandbox (A1), so the Linux reader
      // also finds nothing here: the fast path is off either way.
      expect(
        File('/proc/sys/vm/dirty_writeback_centisecs').existsSync() &&
            _readable('/proc/sys/vm/dirty_writeback_centisecs'),
        isFalse,
      );
      // ignore: avoid_print
      print('ANJ-A2 hostOnly ${hostOnly.join('; ')}');
    });
  });

  group('android_adapters', android_adapters.main);
  group('android_storage', android_storage.main);
  group('entry_projection', entry_projection.main);
  group('event_driven_hashing', event_driven_hashing.main);
  group('profile_lifetime', profile_lifetime.main);
  group('sharing_engine', sharing_engine.main);
  group('sync_lifecycle', sync_lifecycle.main);
  group('sync', sync.main);
  group('upload_limit', upload_limit.main);

  group('key custody', () {
    // Acceptance row 15: the device key exists only in the Keystore-backed
    // secret store; no app file holds it in plaintext.
    test('the device key is in no app file', () async {
      final profile = Directory.systemTemp.createTempSync('anj-key-');
      final manifest = Manifest(profile);
      final secrets = KeystoreSecrets();
      final identity = DeviceIdentity(manifest, secrets);
      try {
        await identity.prepare();
        final pem = (await secrets.read(identity.privateKeyRef))!;
        expect(pem, contains('PRIVATE KEY'));
        final body = pem
            .split('\n')
            .where((l) => l.isNotEmpty && !l.startsWith('-----'))
            .join();
        // Two slices of the key's base64 body (the PEM header is also a string
        // literal in the debug build's kernel blob, so it proves nothing).
        final needles = [
          body.substring(0, 40),
          body.substring(body.length - 40),
        ];
        // The app's whole data directory (files, cache, shared_prefs, ...).
        final data = Directory(profile.parent.parent.path);
        var scanned = 0;
        for (final entity in data.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          scanned++;
          for (final needle in needles) {
            expect(_contains(entity, needle), isFalse, reason: entity.path);
          }
        }
        // ignore: avoid_print
        print('ANJ-A2 key custody scanned=$scanned files under ${data.path}');
        expect(scanned, greaterThan(0));
      } finally {
        await secrets.delete(identity.privateKeyRef);
        manifest.close();
        profile.deleteSync(recursive: true);
      }
    });
  });

  group('hash cost', () {
    // A phone library's local bytes: photos, music, documents and a few
    // videos, about 1 GiB (see [_mix]). Every pass hashes every file
    // (no writeback parameters), so a pass costs a full read and SHA-256.
    test('per-pass hash cost, fast path off', () async {
      final mib =
          int.tryParse(
            const String.fromEnvironment('ANJ_HASH_MIB', defaultValue: '1024'),
          ) ??
          1024;
      final fixture = Directory.systemTemp.createTempSync('anj-hash-');
      final fs = AndroidRootFs();
      final tree = RootTree.setup(fixture.path, 'hash', fs);
      try {
        final mix = _mix(mib);
        final random = Random(28);
        final block = List<int>.generate(1 << 20, (_) => random.nextInt(256));
        var total = 0;
        final written = Stopwatch()..start();
        for (final (folder, count, size) in mix) {
          Directory('${tree.root.path}/$folder').createSync(recursive: true);
          for (var i = 0; i < count; i++) {
            final out = File('${tree.root.path}/$folder/f$i.bin')
                .openSync(mode: FileMode.write);
            var left = size;
            while (left > 0) {
              final n = min(left, block.length);
              out.writeFromSync(block, 0, n);
              left -= n;
            }
            // A distinct first block per file, so no two files are equal.
            out.setPositionSync(0);
            out.writeFromSync([i, i >> 8, folder.length]);
            out.closeSync();
            total += size;
          }
        }
        written.stop();
        final files = mix.fold<int>(0, (a, m) => a + m.$2);
        // ignore: avoid_print
        print(
          'ANJ-A2 hash fixture files=$files bytes=$total '
          'write_s=${(written.elapsedMilliseconds / 1000).toStringAsFixed(1)}',
        );
        for (var pass = 1; pass <= 3; pass++) {
          final cpu0 = _cpuSeconds();
          final bytes0 = fs.meter.bytes;
          final files0 = fs.meter.files;
          final clock = Stopwatch()..start();
          final items = await tree.snapshot();
          clock.stop();
          final cpu = _cpuSeconds() - cpu0;
          expect(tree.writebackEnabled, isFalse);
          expect(items.values.where((i) => i.hash != null).length, files);
          final hashed = fs.meter.bytes - bytes0;
          final s = clock.elapsedMicroseconds / 1e6;
          // ignore: avoid_print
          print(
            'ANJ-A2 hash pass=$pass files=${fs.meter.files - files0} '
            'bytes=$hashed wall_s=${s.toStringAsFixed(2)} '
            'cpu_s=${cpu.toStringAsFixed(2)} '
            'mib_per_s=${(hashed / (1 << 20) / s).toStringAsFixed(1)}',
          );
          expect(hashed, total);
        }
      } finally {
        tree.close();
        fixture.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

/// Whether [file] holds the ASCII [needle], read in 1 MiB chunks.
bool _contains(File file, String needle) {
  final handle = file.openSync();
  try {
    var carry = '';
    while (true) {
      final chunk = handle.readSync(1 << 20);
      if (chunk.isEmpty) return false;
      final text = carry + String.fromCharCodes(chunk);
      if (text.contains(needle)) return true;
      carry = text.substring(max(0, text.length - needle.length));
    }
  } finally {
    handle.closeSync();
  }
}

bool _readable(String path) {
  try {
    File(path).readAsStringSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// (folder, files, bytes each) totalling about [mib] MiB: 60 % photos of
/// 3 MiB, 25 % music of 8 MiB, 10 % videos of 64 MiB, the rest documents
/// of 256 KiB.
List<(String, int, int)> _mix(int mib) {
  const m = 1 << 20;
  int count(double share, int size) => max(1, (mib * m * share) ~/ size);
  return [
    ('Pictures', count(0.60, 3 * m), 3 * m),
    ('Music', count(0.25, 8 * m), 8 * m),
    ('Videos', count(0.10, 64 * m), 64 * m),
    ('Documents', count(0.05, 256 * 1024), 256 * 1024),
  ];
}

/// User plus system CPU of this process (/proc/self/stat, clock ticks).
double _cpuSeconds() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) / 100;
}
