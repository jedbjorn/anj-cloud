// The editor round-trip harness (tool/editor_roundtrip_fixture.dart, spec
// #31 row 14) with its host-neutral atomic-save editor, so the harness the
// mac-test run drives with TextEdit and Preview is itself checked on the VM host.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // The SDK running this test (`flutter test` exports FLUTTER_ROOT), so the
  // harness runs on any seat, mac-test included.
  final sdk =
      Platform.environment['FLUTTER_SDK'] ??
      Platform.environment['FLUTTER_ROOT'];
  final dart = sdk == null ? 'dart' : '$sdk/bin/dart';

  test('real editors are refused without granted consent', () async {
    final fixture = Directory.systemTemp.createTempSync('anj-editor-consent-');
    try {
      final denied = File('${fixture.path}/consent.json')
        ..writeAsStringSync(
          jsonEncode({
            'accessibility': false,
            'targets': {
              'com.apple.TextEdit': 'granted',
              'com.apple.Preview': 'wouldPrompt',
            },
          }),
        );
      for (final args in [
        ['--editor', 'textedit', '--pdf', 'skip'],
        ['--editor', 'fake', '--pdf', 'preview-save', '--consent', denied.path],
        ['--editor', 'textedit', '--consent', '${fixture.path}/missing.json'],
      ]) {
        final run = await Process.run(dart, [
          'run',
          'tool/editor_roundtrip_fixture.dart',
          '${fixture.path}/rt',
          '${fixture.path}/report.json',
          ...args,
        ]);
        expect(run.exitCode, 65, reason: '$args: ${run.stderr}');
        expect('${run.stderr}', contains('no granted Automation consent'));
        expect(File('${fixture.path}/report.json').existsSync(), isFalse);
      }
      final annotate = await Process.run(dart, [
        'run',
        'tool/editor_roundtrip_fixture.dart',
        '${fixture.path}/rt',
        '${fixture.path}/report.json',
        '--pdf',
        'preview-annotate',
      ]);
      expect(annotate.exitCode, 64, reason: 'the annotate mode is gone');
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('every edit uploads, Finish releases, noise stays local', () async {
    final fixture = Directory.systemTemp.createTempSync('anj-editor-rt-');
    try {
      final report = File('${fixture.path}/report.json');
      final run = await Process.run(dart, [
        'run',
        'tool/editor_roundtrip_fixture.dart',
        '${fixture.path}/rt',
        report.path,
        '--editor',
        'fake',
      ]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final result = jsonDecode(report.readAsStringSync()) as Map;
      expect(result['pass'], isTrue);
      final files = (result['files'] as List).cast<Map>();
      expect(files, hasLength(6));
      for (final file in files) {
        expect(file['uploaded'], isTrue, reason: '${file['path']}');
        expect(file['inodeReplaced'], isTrue, reason: '${file['path']}');
      }
      for (final file in files.where((f) => f['retention'] == 'cloud')) {
        expect(file['released'], isTrue, reason: '${file['path']}');
        expect(file['status'], 'cloud-only');
      }
      for (final file in files.where((f) => f['retention'] == 'local')) {
        expect(file['status'], 'current local');
        expect(file['noise'], [
          '._${(file['path'] as String).split('/').last}',
        ]);
      }
      expect(result['uploadedOtherNames'], isEmpty);
      expect(result['excludedUploads'], isEmpty);
      expect(result['cloudDeletes'], isEmpty);
      expect(result['rootNoise'], hasLength(3));
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });
}
