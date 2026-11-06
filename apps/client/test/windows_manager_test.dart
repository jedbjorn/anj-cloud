import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anj_cloud/platform/windows/windows_desktop_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/windows_manager/manager.dart';
import '../tool/windows_manager/zip.dart';

/// Spec #32 W5: the Windows manager's install, update, autostart and
/// uninstall logic against a fake Windows (registry, shortcut, profile lock)
/// and real archives, on any host. The real registry, shortcut and lock are
/// checked on W10C-Testing (tool/windows/manager_test.ps1).
class FakeHost implements Host {
  FakeHost(this.root);
  final String root;
  bool busy = false;
  bool admin = false;
  String? run;
  Map<String, Object>? uninstall;
  final shortcuts = <String, ({String target, String arguments})>{};
  final locks = <String>[];

  @override
  Map<String, String> get environment => {
    'LOCALAPPDATA': p.join(root, 'Local'),
    'APPDATA': p.join(root, 'Roaming'),
  };
  @override
  bool get elevated => admin;
  @override
  T withProfileLock<T>(String profile, String library, T Function() action) {
    if (busy) throw Busy();
    if (!File(library).existsSync()) throw Refused('no library $library');
    Directory(profile).createSync(recursive: true);
    locks.add(profile);
    return action();
  }

  /// A Run value of another type (REG_DWORD, say): present, unreadable.
  bool runOfOtherType = false;
  bool failShortcut = false;
  @override
  ({bool exists, String? text}) readRun() => (
    exists: run != null || runOfOtherType,
    text: runOfOtherType ? null : run,
  );
  @override
  void writeRun(String value) => run = value;
  @override
  void deleteRun() => run = null;
  @override
  ({bool exists, String? text}) readUninstallLocation() => (
    exists: uninstall != null,
    text: uninstall?['InstallLocation'] as String?,
  );
  @override
  void writeUninstall(Map<String, Object> values) => uninstall = values;
  @override
  void deleteUninstall() => uninstall = null;
  @override
  ({String target, String arguments})? readShortcut(String path) =>
      shortcuts[path];
  @override
  void writeShortcut(
    String path, {
    required String target,
    required String arguments,
    required String directory,
    required String icon,
  }) {
    if (failShortcut) throw Refused('shortcut service unavailable');
    File(path).writeAsStringSync('lnk');
    shortcuts[path] = (target: target, arguments: arguments);
  }

  @override
  void seal(String directory, {required bool readOnly}) {}
  @override
  Future<int> start(String executable, List<String> arguments) async => 42;
}

/// A ZIP of [files] (stored, or deflated when [deflate]).
List<int> zipOf(
  Map<String, List<int>> files, {
  bool deflate = false,
  Set<String> links = const {},
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, v >> 8 & 0xff]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);
  for (final MapEntry(key: name, value: data) in files.entries) {
    final body = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    final crc = crc32(data);
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0x800);
    u16(out, deflate ? 8 : 0);
    u32(out, 0);
    u32(out, crc);
    u32(out, body.length);
    u32(out, data.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(body);
    u32(central, 0x02014b50);
    u16(central, links.contains(name) ? 0x31e : 20);
    u16(central, 20);
    u16(central, 0x800);
    u16(central, deflate ? 8 : 0);
    u32(central, 0);
    u32(central, crc);
    u32(central, body.length);
    u32(central, data.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, links.contains(name) ? 0xA1FF << 16 : 0);
    u32(central, offset);
    central.add(nameBytes);
  }
  final cdOffset = out.length;
  final cd = central.takeBytes();
  out.add(cd);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, files.length);
  u16(out, files.length);
  u32(out, cd.length);
  u32(out, cdOffset);
  u16(out, 0);
  return out.takeBytes();
}

const source = '0123456789abcdef0123456789abcdef01234567';
final top = 'anj-cloud-windows-x86_64-${source.substring(0, 12)}';

/// A complete release bundle as the packaging script lays it out.
Map<String, List<int>> bundle({
  String build = 'one',
  String platform = 'Windows x86_64',
}) {
  final files = <String, List<int>>{
    for (final name in requiredFiles) name: utf8.encode('$name $build'),
    'data/flutter_assets/AssetManifest.bin': utf8.encode('assets'),
  };
  final receipt = {
    'platform': platform,
    'source_head': source,
    'files_sha256': {
      for (final e in files.entries) e.key: sha256.convert(e.value).toString(),
    },
  };
  return {
    for (final e in files.entries) '$top/${e.key}': e.value,
    '$top/bundle-receipt.json': utf8.encode(jsonEncode(receipt)),
  };
}

void main() {
  late Directory temp;
  late FakeHost host;
  late Manager manager;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('anj-w5-');
    host = FakeHost(temp.path);
    manager = Manager(host);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  (String, String) archive(List<int> bytes, [String name = 'release.zip']) {
    final file = File(p.join(temp.path, name))..writeAsBytesSync(bytes);
    return (file.path, sha256.convert(bytes).toString());
  }

  test('install publishes the release and integrates it', () async {
    final (path, sha) = archive(zipOf(bundle(), deflate: true));
    final result = await manager.install(path, sha);
    final release = manager.layout.release('$source-$sha');
    expect(File(p.join(release, 'anj_cloud.exe')).existsSync(), isTrue);
    expect(manager.activeState()!['release'], '$source-$sha');
    expect(result['previous'], isNull);
    expect(host.locks, [manager.layout.profile]);
    final client = p.join(release, 'anj_cloud.exe');
    final managerExe = p.join(release, 'anj-cloud-manager.exe');
    expect(host.shortcuts[manager.layout.shortcut]!.target, client);
    expect(host.shortcuts[manager.layout.shortcut]!.arguments, '');
    expect(host.run, '"$client" --background');
    expect(host.uninstall!['InstallLocation'], manager.layout.base);
    expect(host.uninstall!['UninstallString'], '"$managerExe" uninstall');
    expect(await manager.autostart('status'), {
      'enabled': true,
      'source': 'default',
    });
    // Nothing staged is left behind.
    expect(
      Directory(manager.layout.releases)
          .listSync()
          .map((e) => p.basename(e.path)),
      ['$source-$sha'],
    );
  });

  test('a wrong SHA-256 or an elevated manager changes nothing', () async {
    final (path, _) = archive(zipOf(bundle()));
    await expectLater(manager.install(path, 'a' * 64), throwsA(isA<Refused>()));
    expect(manager.activeState(), isNull);
    host.admin = true;
    final (_, sha) = archive(zipOf(bundle()));
    await expectLater(manager.install(path, sha), throwsA(isA<Refused>()));
    expect(host.run, isNull);
  });

  test('update keeps the previous release and refuses while running', () async {
    final (first, firstSha) = archive(zipOf(bundle()), 'a.zip');
    await manager.install(first, firstSha);
    await expectLater(
      manager.install(first, firstSha, update: false),
      completes,
    );
    final (second, secondSha) = archive(
      zipOf(bundle(build: 'two'), deflate: true),
      'b.zip',
    );
    host.busy = true;
    await expectLater(
      manager.install(second, secondSha, update: true),
      throwsA(isA<Busy>()),
    );
    expect(manager.activeState()!['release'], '$source-$firstSha');
    host.busy = false;
    final updated = await manager.install(second, secondSha, update: true);
    expect(updated['release'], '$source-$secondSha');
    expect(updated['previous'], '$source-$firstSha');
    expect(
      Directory(manager.layout.release('$source-$firstSha')).existsSync(),
      isTrue,
    );
    expect(host.run, contains('$source-$secondSha'));
  });

  test('update needs an installation', () async {
    final (path, sha) = archive(zipOf(bundle()));
    await expectLater(
      manager.install(path, sha, update: true),
      throwsA(isA<Refused>()),
    );
  });

  test('unsafe or incomplete archives are refused', () async {
    final cases = <String, List<int>>{
      'parent': zipOf({
        ...bundle(),
        '$top/../evil.txt': [1],
      }),
      'backslash': zipOf({
        ...bundle(),
        r'anj\evil.txt': [1],
      }),
      'reserved': zipOf({
        ...bundle(),
        '$top/nul.txt': [1],
      }),
      'two roots': zipOf({
        ...bundle(),
        'other/x': [1],
      }),
      'link': zipOf(bundle(), links: {'$top/anj_cloud.exe'}),
      'missing': zipOf(Map.of(bundle())..remove('$top/anj_rootfs.dll')),
      'tampered': zipOf(Map.of(bundle())..['$top/anj_cloud.exe'] = [9, 9]),
      'platform': zipOf(bundle(platform: 'Linux x86_64')),
      'case twins': zipOf({
        ...bundle(),
        '$top/ANJ_CLOUD.EXE': [1],
      }),
    };
    for (final MapEntry(key: name, value: bytes) in cases.entries) {
      final (path, sha) = archive(bytes, '$name.zip');
      await expectLater(
        manager.install(path, sha),
        throwsA(isA<Refused>()),
        reason: name,
      );
      expect(manager.activeState(), isNull, reason: name);
    }
  });

  test('autostart toggles only its own Run value', () async {
    final (path, sha) = archive(zipOf(bundle()));
    await manager.install(path, sha);
    final value = host.run;
    expect(await manager.autostart('disable'), {
      'enabled': false,
      'source': 'user',
    });
    expect(host.run, isNull);
    // An update keeps the user's choice.
    await manager.install(path, sha);
    expect(host.run, isNull);
    expect(await manager.autostart('enable'), {
      'enabled': true,
      'source': 'user',
    });
    expect(host.run, value);
    host.run = r'"C:\Other\app.exe"';
    final foreign = await manager.autostart('disable');
    expect(foreign['problem'], contains('not ours'));
    expect(host.run, r'"C:\Other\app.exe"');
  });

  test('uninstall removes exactly what install added', () async {
    final (path, sha) = archive(zipOf(bundle()));
    await manager.install(path, sha);
    final profile = Directory(manager.layout.profile);
    File(p.join(profile.path, 'manifest.sqlite')).writeAsStringSync('db');
    final secrets = Directory(
      p.join(manager.layout.local, 'anj-cloud', 'secrets'),
    )..createSync(recursive: true);
    host.busy = true;
    await expectLater(
      manager.uninstall(library: p.join(temp.path, 'x.dll')),
      throwsA(isA<Busy>()),
    );
    expect(Directory(manager.layout.base).existsSync(), isTrue);
    host.busy = false;
    final library = p.join(
      manager.layout.release('$source-$sha'),
      'anj_rootfs.dll',
    );
    final result = await manager.uninstall(library: library);
    expect(host.run, isNull);
    expect(host.uninstall, isNull);
    expect(File(manager.layout.shortcut).existsSync(), isFalse);
    expect(Directory(manager.layout.base).existsSync(), isFalse);
    expect(profile.existsSync(), isTrue);
    expect(File(p.join(profile.path, 'manifest.sqlite')).existsSync(), isTrue);
    expect(secrets.existsSync(), isTrue);
    expect(result['kept'], isEmpty);
  });

  test('uninstall leaves entries that are not ours', () async {
    final (path, sha) = archive(zipOf(bundle()));
    await manager.install(path, sha);
    host.run = r'"C:\Other\app.exe"';
    host.uninstall = {'InstallLocation': r'C:\Other'};
    final library = p.join(
      manager.layout.release('$source-$sha'),
      'anj_rootfs.dll',
    );
    final result = await manager.uninstall(library: library);
    expect(host.run, r'"C:\Other\app.exe"');
    expect(host.uninstall, isNotNull);
    expect(result['kept'], hasLength(2));
  });

  test('install adopts a pre-W5 Roaming profile before locking', () async {
    final legacy = Directory(manager.layout.legacyProfile)
      ..createSync(recursive: true);
    File(p.join(legacy.path, 'manifest.sqlite')).writeAsStringSync('paired');
    final (path, sha) = archive(zipOf(bundle()));
    await manager.install(path, sha);
    expect(
      File(p.join(manager.layout.profile, 'manifest.sqlite'))
          .readAsStringSync(),
      'paired',
    );
    expect(legacy.existsSync(), isFalse);
  });

  test(
    'a Roaming profile beside a used Local one is reported, not moved',
    () async {
      final legacy = Directory(manager.layout.legacyProfile)
        ..createSync(recursive: true);
      File(p.join(legacy.path, 'manifest.sqlite')).writeAsStringSync('old');
      final local = Directory(manager.layout.profile)
        ..createSync(recursive: true);
      File(p.join(local.path, 'manifest.sqlite')).writeAsStringSync('new');
      final (path, sha) = archive(zipOf(bundle()));
      final result = await manager.install(path, sha);
      expect((result['integration']! as Map)['problems'], [
        contains('left alone'),
      ]);
      expect(
        File(p.join(local.path, 'manifest.sqlite')).readAsStringSync(),
        'new',
      );
      expect(legacy.existsSync(), isTrue);
    },
  );

  test('a Run value of another type is foreign: kept and reported', () async {
    host.runOfOtherType = true;
    final (path, sha) = archive(zipOf(bundle()));
    final result = await manager.install(path, sha);
    expect((result['integration']! as Map)['problems'], [contains('not ours')]);
    expect(host.run, isNull);
    final library = p.join(
      manager.layout.release('$source-$sha'),
      'anj_rootfs.dll',
    );
    final removed = await manager.uninstall(library: library);
    expect(host.runOfOtherType, isTrue);
    expect(removed['kept'], [contains('Run value')]);
  });

  test(
    'an entry without InstallLocation is foreign: kept and reported',
    () async {
      host.uninstall = {'DisplayName': 'Something else'};
      final (path, sha) = archive(zipOf(bundle()));
      final result = await manager.install(path, sha);
      expect((result['integration']! as Map)['problems'], [
        contains('Programs and Features'),
      ]);
      expect(host.uninstall, {'DisplayName': 'Something else'});
      final library = p.join(
        manager.layout.release('$source-$sha'),
        'anj_rootfs.dll',
      );
      await manager.uninstall(library: library);
      expect(host.uninstall, {'DisplayName': 'Something else'});
    },
  );

  test(
    'a failure after the switch is a problem, not a failed install',
    () async {
      host.failShortcut = true;
      final (path, sha) = archive(zipOf(bundle()));
      final result = await manager.install(path, sha);
      expect(manager.activeState()!['release'], '$source-$sha');
      expect(host.run, isNotNull);
      expect((result['integration']! as Map)['problems'], [
        contains('Start menu shortcut'),
      ]);
    },
  );

  test('a member that inflates past its declared size is refused', () async {
    final big = zipOf({
      ...bundle(),
      '$top/data/app.so': List.filled(1 << 20, 0),
    }, deflate: true);
    // Declare app.so as 10 bytes in the central directory.
    final name = utf8.encode('$top/data/app.so');
    var at = big.length - 22;
    while (!(big[at] == 0x50 &&
        big[at + 1] == 0x4b &&
        big[at + 2] == 0x01 &&
        big[at + 3] == 0x02 &&
        _matches(big, at + 46, name))) {
      at--;
    }
    big[at + 24] = 10;
    big[at + 25] = 0;
    big[at + 26] = 0;
    big[at + 27] = 0;
    final (path, sha) = archive(big);
    await expectLater(
      manager.install(path, sha),
      throwsA(
        isA<Refused>().having(
          (e) => e.message,
          'message',
          contains('beyond its declared size'),
        ),
      ),
    );
  });

  test('superscript reserved device names are refused', () {
    expect(Manager.validRelative('a/COM¹.txt'), isFalse);
    expect(Manager.validRelative('a/lpt².log'), isFalse);
    expect(Manager.validRelative('a/COMMON.txt'), isTrue);
  });

  group('default Windows profile (#134)', () {
    test('is under LOCALAPPDATA, moving a Roaming default once', () {
      final roaming = p.join(temp.path, 'Roaming', 'cloud.anj', 'anj_cloud');
      final legacy = Directory(p.join(roaming, 'anj-cloud', 'default'))
        ..createSync(recursive: true);
      File(p.join(legacy.path, 'manifest.sqlite')).writeAsStringSync('db');
      final env = {'LOCALAPPDATA': p.join(temp.path, 'Local')};
      final session = WindowsDesktopSession();
      final chosen = session.defaultProfile(roaming, environment: env);
      expect(chosen, p.join(temp.path, 'Local', 'anj-cloud', 'profile'));
      expect(File(p.join(chosen, 'manifest.sqlite')).readAsStringSync(), 'db');
      expect(legacy.existsSync(), isFalse);
      // Already moved: nothing happens again.
      expect(session.defaultProfile(roaming, environment: env), chosen);
    });

    test('an unused LOCALAPPDATA profile (a lock only) still adopts', () {
      final roaming = p.join(temp.path, 'Roaming');
      final legacy = Directory(p.join(roaming, 'anj-cloud', 'default'))
        ..createSync(recursive: true);
      File(p.join(legacy.path, 'manifest.sqlite')).writeAsStringSync('db');
      final local = Directory(
        p.join(temp.path, 'Local', 'anj-cloud', 'profile'),
      )..createSync(recursive: true);
      File(p.join(local.path, '.instance.lock')).writeAsStringSync('');
      final env = {'LOCALAPPDATA': p.join(temp.path, 'Local')};
      expect(
        WindowsDesktopSession().defaultProfile(roaming, environment: env),
        local.path,
      );
      expect(
        File(p.join(local.path, 'manifest.sqlite')).readAsStringSync(),
        'db',
      );
    });

    test('an existing LOCALAPPDATA profile is never replaced', () {
      final roaming = p.join(temp.path, 'Roaming');
      Directory(p.join(roaming, 'anj-cloud', 'default'))
          .createSync(recursive: true);
      final local = Directory(
        p.join(temp.path, 'Local', 'anj-cloud', 'profile'),
      )..createSync(recursive: true);
      File(p.join(local.path, 'manifest.sqlite')).writeAsStringSync('in use');
      final env = {'LOCALAPPDATA': p.join(temp.path, 'Local')};
      expect(
        WindowsDesktopSession().defaultProfile(roaming, environment: env),
        local.path,
      );
      expect(
        Directory(p.join(roaming, 'anj-cloud', 'default')).existsSync(),
        isTrue,
      );
    });
  });
}

bool _matches(List<int> bytes, int at, List<int> name) {
  if (at + name.length > bytes.length) return false;
  for (var i = 0; i < name.length; i++) {
    if (bytes[at + i] != name[i]) return false;
  }
  return true;
}
