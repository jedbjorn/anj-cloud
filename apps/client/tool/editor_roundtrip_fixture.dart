// Editor round trip with Finish editing (spec #31 acceptance row 14, M4).
// Operates only within its private marked fixture directory, against the
// disk-backed FixtureCloud (never a gateway).
//
//   dart run tool/editor_roundtrip_fixture.dart <fixture dir> <report.json>
//       --editor fake|textedit [--pdf fake|preview-save|skip]
//       [--consent <automation_consent.swift JSON>]
//
// Six files: note.txt, letter.rtf and paper.pdf, once in a Local folder and
// once in a Cloud folder (released first). A Local file is edited in place
// in the root; a Cloud file is opened as an editor working copy
// (SyncEngine.openFile, as the app's Open does), edited, and then Finish
// editing is confirmed. Pass: every edit uploads, no other name uploads,
// Finish releases the working copies (no owned bytes left in staging), the
// Local files stay Local. New names that appear in the root or staging
// while an editor works ("noise") are recorded.
//
// Editors: "fake" is an atomic save written here (temp file + rename, plus
// an AppleDouble `._` companion), so the harness runs on any host.
// "textedit" drives TextEdit through osascript (mac-test). PDFs:
// "preview-save" only asks Preview to save (its save path; annotating in
// Preview is the operator's, at M7 on the MacBook); "skip" leaves them out.
// Before it drives TextEdit or Preview at all, the harness requires
// --consent: the JSON tool/macos/automation_consent.swift printed for this
// same route, with that app "granted". Anything else exits 65 without
// opening an app, so the harness never causes a consent prompt.
//
// Exit 0 when every exercised file passes, 1 otherwise; the report says
// which. The ANJ_ROOTFS_LIBRARY native library is used (Darwin on mac-test).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'eviction_fixture.dart' show ownedAllocated;
import 'fixture_cloud.dart';

class _CountingCloud extends FixtureCloud {
  _CountingCloud(super.root);
  final uploaded = <String>[];
  final deleted = <String>[];
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    uploaded.add(path);
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    deleted.add(path);
    return super.deleteFile(path, etag: etag);
  }
}

/// One page with one line of text; offsets computed so the xref is exact.
List<int> minimalPdf(String text) {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final stream = 'BT /F1 24 Tf 72 700 Td ($text) Tj ET';
  objects.add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return latin1.encode(out.toString());
}

const _marker = ' anj-m4-edit';

/// Edits [path] (a [format] file); [inRoot] is false for a working copy in
/// the private staging directory.
typedef _Editor = Future<void> Function(
  String path,
  String format, {
  required bool inRoot,
});

Future<void> _osascript(String script, List<String> args) async {
  final process = await Process.start('/usr/bin/osascript', [
    '-e',
    script,
    ...args,
  ]);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  if (code != 0) {
    throw StateError('osascript exit $code: ${await err} ${await out}'.trim());
  }
}

Future<void> _open(String app, String path) async {
  // LaunchServices: hands the sandboxed editor its access to the file.
  final result = await Process.run('/usr/bin/open', ['-a', app, path]);
  if (result.exitCode != 0) {
    throw StateError('open -a $app: ${result.stderr}');
  }
}

/// TextEdit: open through LaunchServices, append the marker, save, close.
Future<void> _textEdit(
  String path,
  String format, {
  required bool inRoot,
}) async {
  await _open('TextEdit', path);
  await _osascript(
    r'''
on run argv
  set p to item 1 of argv
  set m to item 2 of argv
  tell application "TextEdit"
    set d to missing value
    repeat 100 times
      try
        set d to first document whose path is p
        exit repeat
      end try
      delay 0.1
    end repeat
    if d is missing value then error "TextEdit did not open " & p
    set text of d to (text of d) & m
    save d
    close d saving no
  end tell
end run
''',
    [path, _marker],
  );
}

/// Preview: save only (exercises its save path; no annotation).
Future<void> _previewSave(
  String path,
  String format, {
  required bool inRoot,
}) async {
  await _open('Preview', path);
  await _osascript(
    r'''
on run argv
  set n to item 1 of argv
  tell application "Preview"
    set d to missing value
    repeat 100 times
      try
        set d to first document whose name is n
        exit repeat
      end try
      delay 0.1
    end repeat
    if d is missing value then error "Preview did not open " & n
    save d
    close d saving no
  end tell
end run
''',
    [p.basename(path)],
  );
}

/// An atomic save as editors do it: a new file renamed over the old one.
/// In the root it also leaves an AppleDouble companion beside it (as a copy
/// from a FAT or SMB volume would); staging gets nothing extra, because any
/// unowned file there holds Finish editing (correctly) until it is gone.
Future<void> _fake(String path, String format, {required bool inRoot}) async {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  final edited = format == 'pdf'
      ? [...bytes, ...latin1.encode('%$_marker\n')]
      : [...bytes, ...utf8.encode(_marker)];
  final temp = File(p.join(p.dirname(path), '.${p.basename(path)}.sb-anj'))
    ..writeAsBytesSync(edited, flush: true);
  temp.renameSync(path);
  if (!inRoot) return;
  File(p.join(p.dirname(path), '._${p.basename(path)}'))
      .writeAsBytesSync([0, 5, 22, 7], flush: true);
}

Set<String> _names(Directory directory) => {
  if (directory.existsSync())
    for (final entity in directory.listSync(recursive: true))
      p.relative(entity.path, from: directory.path),
};

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: editor_roundtrip_fixture.dart <dir> <report.json> '
      '--editor fake|textedit [--pdf fake|preview-save|skip] [--consent <json>]',
    );
    exit(64);
  }
  final fixture = Directory(args[0]);
  final reportFile = File(args[1]);
  String option(String name, String fallback) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
  }

  final editorName = option('--editor', 'fake');
  final pdfMode = option('--pdf', editorName == 'fake' ? 'fake' : 'skip');
  final editors = <String, _Editor>{'fake': _fake, 'textedit': _textEdit};
  final pdfEditors = <String, _Editor>{
    'fake': _fake,
    'preview-save': _previewSave,
  };
  final textEditor = editors[editorName];
  if (textEditor == null ||
      (pdfMode != 'skip' && !pdfEditors.containsKey(pdfMode))) {
    stderr.writeln('editor_roundtrip_fixture.dart: unknown editor or pdf mode');
    exit(64);
  }
  // The apps this run would drive, each needing a "granted" consent result.
  final apps = {
    if (editorName == 'textedit') 'com.apple.TextEdit',
    if (pdfMode == 'preview-save') 'com.apple.Preview',
  };
  if (apps.isNotEmpty) {
    final consentPath = args.contains('--consent')
        ? option('--consent', '')
        : '';
    Map<String, dynamic>? targets;
    try {
      final consent = jsonDecode(File(consentPath).readAsStringSync());
      targets =
          (consent as Map<String, dynamic>)['targets'] as Map<String, dynamic>?;
    } catch (_) {
      targets = null;
    }
    final missing = [
      for (final app in apps)
        if (targets?[app] != 'granted') app,
    ];
    if (missing.isNotEmpty) {
      stderr.writeln(
        'editor_roundtrip_fixture.dart: no granted Automation consent for '
        '${missing.join(', ')} (--consent); not opening any app',
      );
      exit(65);
    }
  }
  final marker = File('${fixture.path}/.anj-editor-roundtrip-fixture');
  if (fixture.existsSync()) {
    if (!marker.existsSync()) throw StateError('Not an owned fixture');
    fixture.deleteSync(recursive: true);
  }
  fixture.createSync(recursive: true);
  marker.writeAsStringSync('synthetic only');
  final canonical = fixture.resolveSymbolicLinksSync();

  final native = NativeRootFs();
  final cloud = _CountingCloud(Directory('$canonical/cloud'));
  final parent = Directory('$canonical/files')..createSync();
  final tree = RootTree.setup(parent.path, 'editor-roundtrip', native);
  final store = Manifest(Directory('$canonical/profile'));
  final engine = SyncEngine(store, tree, cloud);
  final report = <String, Object?>{
    'editor': editorName,
    'pdf': pdfMode,
    'files': <Map<String, Object?>>[],
  };
  var failed = false;
  try {
    final formats = {
      'txt': utf8.encode('A plain note.\n'),
      'rtf': utf8.encode(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 A rich letter.}',
      ),
      if (pdfMode != 'skip') 'pdf': minimalPdf('A paper to save'),
    };
    String name(String format) => switch (format) {
      'txt' => 'note.txt',
      'rtf' => 'letter.rtf',
      _ => 'paper.pdf',
    };
    final paths = <String, String>{}; // path -> format
    for (final folder in ['Local', 'Cloud']) {
      for (final format in formats.keys) {
        final path = 'Documents/$folder/${name(format)}';
        final remote = cloud.file(path);
        remote.parent.createSync(recursive: true);
        remote.writeAsBytesSync(formats[format]!, flush: true);
        paths[path] = format;
      }
    }
    await engine.tick();
    engine.setRetention('Documents/Cloud', Retention.cloud);
    await engine.tick();
    for (final path in paths.keys.where((v) => v.contains('/Cloud/'))) {
      final status = store.entries[path]?.status;
      if (status != 'cloud-only') {
        throw StateError(
          '$path was not released before the round trip: $status',
        );
      }
    }
    cloud.uploaded.clear();
    final namesBefore = _names(tree.root);

    for (final entry in paths.entries) {
      final path = entry.key;
      final format = entry.value;
      final cloudFolder = path.contains('/Cloud/');
      final editor = format == 'pdf' ? pdfEditors[pdfMode]! : textEditor;
      final result = <String, Object?>{
        'path': path,
        'retention': cloudFolder ? 'cloud' : 'local',
        'editor': format == 'pdf' ? pdfMode : editorName,
      };
      (report['files'] as List).add(result);
      final problems = <String>[];
      try {
        final remoteBefore = cloud.file(path).readAsBytesSync();
        final target = cloudFolder
            ? await engine.openFile(path)
            : '${tree.root.path}/$path';
        final directory = Directory(p.dirname(target));
        final around = _names(directory);
        final fd = cloudFolder ? tree.stageFd : tree.fd;
        final relative = cloudFolder ? p.basename(target) : path;
        final identity = engine.artifacts.native.info(fd, relative).identity;
        await editor(target, format, inRoot: !cloudFolder);
        // Let the editor finish writing (autosave, close), then sync.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final edited = File(target).readAsBytesSync();
        result['sameBytesAsBefore'] = _same(edited, remoteBefore);
        result['inodeReplaced'] =
            engine.artifacts.native.info(fd, relative).identity != identity;
        result['noise'] = (_names(directory).difference(around)).toList()
          ..sort();
        await engine.tick();
        await engine.tick();
        final remote = cloud.file(path).readAsBytesSync();
        result['uploaded'] =
            _same(remote, edited) && !_same(remote, remoteBefore);
        if (result['uploaded'] != true) problems.add('edit did not upload');
        if (cloudFolder) {
          final preview = engine
              .workingCopies(path)
              .map((v) => Map<String, dynamic>.from(v))
              .toList();
          engine.editing.request(path, preview);
          await engine.tick();
          await engine.tick();
          result['workingCopiesAfterFinish'] = engine
              .workingCopies(path)
              .length;
          result['status'] = store.entries[path]?.status;
          result['released'] =
              engine.workingCopies(path).isEmpty &&
              !File(target).existsSync() &&
              !File('${tree.root.path}/$path').existsSync();
          if (result['released'] != true) {
            problems.add('Finish editing did not release the working copy');
          }
        } else {
          result['status'] = store.entries[path]?.status;
          if (!File('${tree.root.path}/$path').existsSync()) {
            problems.add('the Local file left the root');
          }
        }
      } catch (error) {
        problems.add('$error');
      }
      result['problems'] = problems;
      result['pass'] = problems.isEmpty;
      failed |= problems.isNotEmpty;
      stdout.writeln(
        '${problems.isEmpty ? 'pass' : 'FAIL'}  $path (${result['editor']})'
        '${problems.isEmpty ? '' : ': ${problems.join('; ')}'}',
      );
    }

    await engine.tick();
    final unexpected = cloud.uploaded.toSet().difference(paths.keys.toSet());
    report['uploadedOtherNames'] = unexpected.toList()..sort();
    report['excludedUploads'] = cloud.uploaded.where(isSyncExcluded).toList();
    report['cloudDeletes'] = cloud.deleted;
    report['rootNoise'] = (_names(tree.root).difference(
      namesBefore,
    )..removeWhere((v) => paths.containsKey(v))).toList()..sort();
    report['ownedAllocatedRootAndStaging'] = ownedAllocated(tree);
    final staged = _names(tree.staging);
    report['stagingNames'] = staged.toList()..sort();
    if (unexpected.isNotEmpty || cloud.deleted.isNotEmpty) failed = true;
    stdout.writeln(
      '${unexpected.isEmpty ? 'pass' : 'FAIL'}  no other name uploaded'
      '${unexpected.isEmpty ? '' : ': ${unexpected.join(', ')}'}',
    );
    stdout.writeln(
      '${cloud.deleted.isEmpty ? 'pass' : 'FAIL'}  no cloud delete',
    );
  } catch (error, stack) {
    failed = true;
    report['error'] = '$error';
    stderr.writeln('$error\n$stack');
  } finally {
    engine.close();
  }
  report['pass'] = !failed;
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  stdout.writeln(
    failed ? 'editor round trip: FAILED' : 'editor round trip: all passed',
  );
  exit(failed ? 1 : 0);
}

bool _same(List<int> a, List<int> b) => sha256.convert(a) == sha256.convert(b);
