// The Windows SelfUpdatePort over the installed manager,
// with the Linux contract. The manager's apply-update is tested by
// test/windows_manager_update_test.dart (fake Windows, any host) and on the
// Windows seat; here: what the port reads and what it hands the manager.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/ports/self_update.dart';
import 'package:anj_cloud/core/update/release.dart';
import 'package:anj_cloud/platform/windows/windows_platform_adapters.dart';
import 'package:anj_cloud/platform/windows/windows_self_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const id =
      '0123456789abcdef0123456789abcdef01234567-'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Directory fixture;
  late String executable;
  late File receipt;
  late File active;
  late File calls;
  late File manager;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-windows-self-update-');
    final release = p.join(fixture.path, 'anj-cloud', 'releases', id);
    Directory(release).createSync(recursive: true);
    executable = p.join(release, 'anj_cloud.exe');
    File(executable).writeAsStringSync('');
    receipt = File(p.join(release, 'bundle-receipt.json'))
      ..writeAsStringSync(
        '{"platform": "Windows x86_64", "version": "2026.11.11.170", '
        '"version_code": 170}',
      );
    active = File(p.join(fixture.path, 'anj-cloud', 'active.json'))
      ..writeAsStringSync(jsonEncode({'release': id}));
    calls = File(p.join(fixture.path, 'calls'));
    // A stand-in for anj-cloud-manager.exe: records its arguments, and
    // refuses with a reason when the archive's name says so.
    manager = File(p.join(release, 'anj-cloud-manager.exe'))
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "%s\\n" "\$*" >> "${calls.path}"\n'
        'case "\$2" in *refused*) echo "noise" >&2; '
        'echo "anj-cloud-manager: The update\'s signature does not verify." >&2; exit 1 ;; '
        '*crashed*) echo "Unhandled exception: trace" >&2; exit 255 ;; esac\n'
        'exit 0\n',
      );
    if (!Platform.isWindows) Process.runSync('chmod', ['0755', manager.path]);
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  final made = <String>[];
  WindowsManagerSelfUpdate port() => WindowsManagerSelfUpdate(
    manager.path,
    executable: executable,
    makePrivate: made.add,
  );

  test('the installed build comes from the active release receipt', () async {
    final build = await port().installed();
    expect(build?.target, windowsReleaseTarget);
    expect(build?.version, '2026.11.11.170');
    expect(build?.versionCode, 170);
  });

  test(
    'no version, another platform or a malformed receipt: no self-update',
    () async {
      receipt.writeAsStringSync('{"platform": "Windows x86_64"}');
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync(
        '{"platform": "Linux x86_64", "version": "1", "version_code": 1}',
      );
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync(
        '{"platform": "Windows x86_64", "version": "1", "version_code": "1"}',
      );
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync('not json');
      expect(await port().installed(), isNull);
      receipt.deleteSync();
      expect(await port().installed(), isNull);
    },
  );

  test('a release the manager did not activate has no self-update', () async {
    // An unpacked archive: no activation record above it.
    active.deleteSync();
    expect(await port().installed(), isNull);
    // A kept previous release: the record names another one.
    active.writeAsStringSync(jsonEncode({'release': 'another'}));
    expect(await port().installed(), isNull);
    active.writeAsStringSync('not json');
    expect(await port().installed(), isNull);
  });

  test('prepare makes the staging folder private', () async {
    final updates = Directory(p.join(fixture.path, 'updates'))..createSync();
    made.clear();
    await port().prepare(updates);
    expect(made, [updates.path]);
    await expectLater(
      WindowsManagerSelfUpdate(
        manager.path,
        executable: executable,
        makePrivate: (_) => throw StateError('no library'),
      ).prepare(updates),
      throwsA(isA<SelfUpdateFailure>()),
    );
  });

  final shell = Platform.isWindows
      ? 'the stand-in manager is a shell script'
      : null;

  test(
    'check asks the manager with --check; a refusal carries its reason',
    () async {
      final updates = Directory(p.join(fixture.path, 'updates'))..createSync();
      final archive = File(p.join(updates.path, '171.tar.gz'));
      final manifest = File(p.join(updates.path, '171.json'));
      await port().check(archive, manifest);
      expect(
        calls.readAsLinesSync().last,
        'apply-update ${archive.path} --manifest ${manifest.path} --check',
      );
      await expectLater(
        port().check(File(p.join(updates.path, 'refused.zip')), manifest),
        throwsA(
          isA<SelfUpdateFailure>().having(
            (f) => f.message,
            'message',
            "The update's signature does not verify.",
          ),
        ),
      );
      // A manager that died shows no stack trace in the status line.
      await expectLater(
        port().check(File(p.join(updates.path, 'crashed.zip')), manifest),
        throwsA(
          isA<SelfUpdateFailure>().having(
            (f) => f.message,
            'message',
            'The installed manager refused the update.',
          ),
        ),
      );
      await expectLater(
        WindowsManagerSelfUpdate(
          p.join(fixture.path, 'absent.exe'),
          executable: executable,
        ).check(archive, manifest),
        throwsA(isA<SelfUpdateFailure>()),
      );
    },
    skip: shell,
  );

  test('handOver starts the manager detached with --result', () async {
    final updates = Directory(p.join(fixture.path, 'updates'))..createSync();
    final archive = File(p.join(updates.path, '171.tar.gz'));
    final manifest = File(p.join(updates.path, '171.json'));
    final result = File(p.join(updates.path, 'result.json'));
    await port().handOver(archive, manifest, result);
    for (var i = 0; i < 100 && !calls.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      calls.readAsLinesSync().last,
      'apply-update ${archive.path} --manifest ${manifest.path} '
      '--result ${result.path}',
    );
    await expectLater(
      WindowsManagerSelfUpdate(
        p.join(fixture.path, 'absent.exe'),
        executable: executable,
      ).handOver(archive, manifest, result),
      throwsA(isA<SelfUpdateFailure>()),
    );
  }, skip: shell);

  test('the Windows adapters offer the in-app update through the manager', () {
    expect(
      const WindowsPlatformAdapters().managerSelfUpdate(manager.path),
      isA<WindowsManagerSelfUpdate>(),
    );
  });
}
