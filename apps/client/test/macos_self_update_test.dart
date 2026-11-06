// Spec #40 R2: the macOS SelfUpdatePort over the embedded manager, with the
// Linux contract. The manager and the app's verifier are tested by
// tool/macos/test_manager.sh (The VM host) and on mac-test; here: what the port
// reads and what it hands the manager.
import 'dart:io';

import 'package:anj_cloud/core/ports/self_update.dart';
import 'package:anj_cloud/core/update/release.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/macos/macos_self_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory fixture;
  late String executable;
  late File receipt;
  late File calls;
  late File manager;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-macos-self-update-');
    final contents = p.join(fixture.path, 'AnJ Cloud.app', 'Contents');
    Directory(p.join(contents, 'MacOS')).createSync(recursive: true);
    Directory(p.join(contents, 'Resources')).createSync();
    executable = p.join(contents, 'MacOS', 'AnJ Cloud');
    File(executable).writeAsStringSync('');
    receipt = File(p.join(contents, 'Resources', 'bundle-receipt.json'));
    calls = File(p.join(fixture.path, 'calls'));
    // A stand-in for the embedded manager: records its arguments, and
    // refuses with a reason when the archive's name says so.
    manager = File(p.join(contents, 'Resources', 'anj-cloud-macos-install.sh'))
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "%s\\n" "\$*" >> "${calls.path}"\n'
        'case "\$2" in *refused*) echo "anj-cloud: checking" >&2; '
        'echo "anj-cloud: The update\'s signature does not verify." >&2; exit 1 ;; esac\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['0755', manager.path]);
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  MacosManagerSelfUpdate port() =>
      MacosManagerSelfUpdate(manager.path, executable: executable);

  test('the installed build comes from the bundle receipt', () async {
    receipt.writeAsStringSync(
      '{"target": "macos-arm64", "platform": "macOS arm64", '
      '"version": "2026.11.06.160", "version_code": 160}',
    );
    final build = await port().installed();
    expect(build?.target, macosReleaseTarget);
    expect(build?.version, '2026.11.06.160');
    expect(build?.versionCode, 160);
  });

  test(
    'no receipt, another target or a malformed one: no self-update',
    () async {
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync(
        '{"target": "linux-x86_64", "version": "1", "version_code": 1}',
      );
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync(
        '{"target": "macos-arm64", "version_code": "1"}',
      );
      expect(await port().installed(), isNull);
      receipt.writeAsStringSync('not json');
      expect(await port().installed(), isNull);
    },
  );

  test(
    'check asks the manager with --check; a refusal carries its reason',
    () async {
      final updates = Directory(p.join(fixture.path, 'updates'))..createSync();
      await port().prepare(updates);
      expect(updates.statSync().modeString(), 'rwx------');
      final archive = File(p.join(updates.path, 'update.zip'));
      final manifest = File(p.join(updates.path, 'manifest.json'));
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
    },
  );

  test(
    'handOver starts the manager detached with --result and this pid',
    () async {
      final updates = Directory(p.join(fixture.path, 'updates'))..createSync();
      final archive = File(p.join(updates.path, 'update.zip'));
      final manifest = File(p.join(updates.path, 'manifest.json'));
      final result = File(p.join(updates.path, 'result.json'));
      await port().handOver(archive, manifest, result);
      for (var i = 0; i < 100 && !calls.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        calls.readAsLinesSync().last,
        'apply-update ${archive.path} --manifest ${manifest.path} '
        '--result ${result.path} --app-pid $pid',
      );
    },
  );

  test('the macOS adapters offer the in-app update through the manager', () {
    expect(
      const MacosPlatformAdapters().managerSelfUpdate(manager.path),
      isA<MacosManagerSelfUpdate>(),
    );
  });
}
