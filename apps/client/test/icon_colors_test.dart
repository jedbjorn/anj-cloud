import 'dart:io';

import 'package:anj_cloud/core/app/icon_colors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory profile;
  setUp(
    () => profile = Directory.systemTemp.createTempSync('anj-icon-colors-'),
  );
  tearDown(() => profile.deleteSync(recursive: true));

  test('colours survive restart, stay path-local and reset independently', () {
    final colors = IconColors(profile)..load();
    colors.set('Documents', 0xff225bb5);
    colors.set('Documents/file.txt', 0xffb3261e);
    final restarted = IconColors(profile)..load();
    expect(restarted['Documents'], 0xff225bb5);
    expect(restarted['Documents/file.txt'], 0xffb3261e);
    expect(restarted['Documents/other.txt'], isNull);
    restarted.set('Documents', null);
    final reset = IconColors(profile)..load();
    expect(reset['Documents'], isNull);
    expect(reset['Documents/file.txt'], 0xffb3261e);
    final otherProfile = Directory('${profile.path}/other')..createSync();
    expect((IconColors(otherProfile)..load())['Documents/file.txt'], isNull);
    expect(
      profile.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
      ['icon-colors.json'],
    );
  });

  test('invalid preferences are reported without modifying the file', () {
    final file = File('${profile.path}/icon-colors.json');
    for (final invalid in ['not json', '[]', '{"file":"red"}', '{"file":-1}']) {
      file.writeAsStringSync(invalid);
      expect(() => IconColors(profile).load(), throwsFormatException);
      expect(file.readAsStringSync(), invalid);
    }
  });

  test('failed persistence keeps the previous in-memory colour', () {
    final colors = IconColors(profile)..set('file', 0xff225bb5);
    Directory('${profile.path}/icon-colors.json.tmp').createSync();
    expect(
      () => colors.set('file', 0xffb3261e),
      throwsA(isA<FileSystemException>()),
    );
    expect(colors['file'], 0xff225bb5);
    expect((IconColors(profile)..load())['file'], 0xff225bb5);
  });
}
