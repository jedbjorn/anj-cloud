/// The Windows manager (spec #32 W5): a trusted, local-only installer and
/// updater for per-user installs, mirroring tool/linux_install.py. No network
/// or feed: an update is an explicit archive plus its independently supplied
/// SHA-256, as on Linux (spec #32 Packaging and Updates; the G1 feed comes
/// later). No administrator rights are used or accepted.
///
/// Layout (all per user):
///   `%LOCALAPPDATA%\Programs\anj-cloud\releases\<source>-<archive sha256>\`
///       one immutable release: the Flutter bundle, anj_rootfs.dll, the
///       MSVC runtime and anj-cloud-manager.exe, checked against its receipt
///   %LOCALAPPDATA%\Programs\anj-cloud\active.json      the one commit point
///   %LOCALAPPDATA%\Programs\anj-cloud\autostart.json   the start-at-login choice
///   %LOCALAPPDATA%\Programs\anj-cloud\integration.json what was written outside
///   %LOCALAPPDATA%\anj-cloud\profile                   the profile (never removed)
/// Outside it: the Start menu shortcut, the HKCU Run value `AnJ Cloud` and the
/// per-user Programs and Features entry. The manager is their only writer and
/// removes exactly what it wrote.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:anj_cloud/core/update/release.dart';
import 'package:anj_cloud/platform/windows/profile_location.dart';

import 'zip.dart';

const owner = 'anj-cloud-windows-manager-v1';
const runValueName = 'AnJ Cloud';
const maxArchiveBytes = 2 * 1024 * 1024 * 1024;
const busyMessage =
    'This profile is already running. Quit AnJ Cloud from its '
    'notification-area icon before updating or uninstalling.';

const notQuitMessage =
    'AnJ Cloud did not quit in time; the update was not installed.';

/// The household release key inside a release (a Flutter asset).
const releaseKeyPayload =
    'data/flutter_assets/assets/release/household-release-key.pub';

/// Files every release must carry (the bundle-receipt lists the rest).
const requiredFiles = {
  'anj_cloud.exe',
  'flutter_windows.dll',
  'anj_rootfs.dll',
  'anj-cloud-manager.exe',
  'data/app.so',
  'data/icudtl.dat',
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
};

class Refused implements Exception {
  Refused(this.message);
  final String message;
  @override
  String toString() => message;
}

class Busy extends Refused {
  Busy() : super(busyMessage);
}

/// What the manager needs from Windows (faked in tests).
abstract class Host {
  Map<String, String> get environment;
  bool get elevated;

  /// Runs [action] holding the profile lifetime lock through [library]
  /// (a release's anj_rootfs.dll), creating [profile] private if needed.
  /// Throws [Busy] while the client holds it.
  T withProfileLock<T>(String profile, String library, T Function() action);

  /// The Run value `AnJ Cloud`: absent (`exists` false), a string
  /// (`text`), or present with another type (`text` null: foreign).
  ({bool exists, String? text}) readRun();
  void writeRun(String value);
  void deleteRun();

  /// The per-user Programs and Features entry (HKCU ...\Uninstall\AnJ Cloud):
  /// absent, or present with its InstallLocation string (`text` null when it
  /// has none or another type: foreign).
  ({bool exists, String? text}) readUninstallLocation();
  void writeUninstall(Map<String, Object> values);
  void deleteUninstall();

  /// `target` and `arguments` of a shortcut, or null when there is none.
  ({String target, String arguments})? readShortcut(String path);
  void writeShortcut(
    String path, {
    required String target,
    required String arguments,
    required String directory,
    required String icon,
  });

  /// Marks every file under [directory] read-only (or writable again).
  void seal(String directory, {required bool readOnly});

  /// Starts [executable] detached; returns its process id.
  Future<int> start(String executable, List<String> arguments);
}

class Layout {
  Layout(Map<String, String> env)
    : local = _need(env, 'LOCALAPPDATA'),
      roaming = _need(env, 'APPDATA');
  final String local;
  final String roaming;

  static String _need(Map<String, String> env, String name) {
    final value = env[name];
    if (value == null || value.isEmpty || !p.isAbsolute(value)) {
      throw Refused('$name is not set to an absolute path.');
    }
    return value;
  }

  String get base => p.join(local, 'Programs', 'anj-cloud');
  String get releases => p.join(base, 'releases');
  String get active => p.join(base, 'active.json');
  String get autostart => p.join(base, 'autostart.json');
  String get integration => p.join(base, 'integration.json');

  /// Beside the installation, so uninstall can rename the installation
  /// directory while holding it.
  String get transaction =>
      p.join(local, 'Programs', '.anj-cloud-transaction.lock');
  String get log => p.join(base, 'manager.jsonl');
  String get profile => windowsProfile(local);
  String get legacyProfile => windowsLegacyProfile(roaming);
  String get shortcut => p.join(
    roaming,
    'Microsoft',
    'Windows',
    'Start Menu',
    'Programs',
    'AnJ Cloud.lnk',
  );
  String release(String id) => p.join(releases, id);
}

class Manager {
  Manager(this.host) : layout = Layout(host.environment);
  final Host host;
  final Layout layout;

  void _refuseElevated() {
    if (host.elevated) {
      throw Refused(
        'Run the manager as your normal Windows user, not as administrator: '
        'AnJ Cloud is installed per user and runs unelevated.',
      );
    }
  }

  /// Serializes manager transactions (Linux: .transaction.lock).
  Future<T> _transaction<T>(Future<T> Function() action) async {
    Directory(p.dirname(layout.transaction)).createSync(recursive: true);
    sweep();
    final lock = File(layout.transaction).openSync(mode: FileMode.append);
    try {
      try {
        lock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw Refused(
          'Another manager command is running; retry when it ends.',
        );
      }
      return await action();
    } finally {
      lock.closeSync();
    }
  }

  /// Best effort: removes what an earlier uninstall could not (its copy in
  /// %TEMP%, a tombstone it could not delete). Only this manager's names.
  void sweep() {
    final candidates = <Directory>[];
    try {
      candidates.addAll(
        Directory.systemTemp
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where(
              (d) => p.basename(d.path).startsWith('anj-cloud-uninstall-'),
            ),
      );
    } on FileSystemException {
      // No temporary directory listing: nothing to sweep.
    }
    try {
      candidates.addAll(
        Directory(p.dirname(layout.base))
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where((d) => p.basename(d.path).startsWith('anj-cloud.removing-')),
      );
    } on FileSystemException {
      // No Programs directory yet.
    }
    final self = p.dirname(Platform.resolvedExecutable);
    for (final directory in candidates) {
      if (p.equals(directory.path, self) || p.isWithin(directory.path, self)) {
        continue;
      }
      try {
        host.seal(directory.path, readOnly: false);
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Still in use (an uninstall finishing): a later run removes it.
      }
    }
  }

  void _log(String event, [Map<String, Object?> fields = const {}]) {
    Directory(layout.base).createSync(recursive: true);
    File(layout.log).writeAsStringSync(
      '${jsonEncode({'utc': DateTime.now().toUtc().toIso8601String(), 'event': event, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  static void _atomicJson(String path, Object value) {
    final temporary = File('$path.tmp-${_random()}');
    temporary.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    temporary.renameSync(path);
  }

  static String _random() =>
      Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');

  Map<String, dynamic>? activeState() {
    final file = File(layout.active);
    if (!file.existsSync()) return null;
    final Map<String, dynamic> state;
    try {
      state = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      throw Refused('Invalid activation record; refusing to repair it.');
    }
    final release = state['release'];
    if (state['owner'] != owner ||
        release is! String ||
        !RegExp(r'^[a-f0-9]{40}-[a-f0-9]{64}$').hasMatch(release) ||
        release != '${state['source']}-${state['archive_sha256']}' ||
        state['profile'] is! String) {
      throw Refused('Invalid activation record; refusing to repair it.');
    }
    return state;
  }

  // ---- install and update ----------------------------------------------

  /// Installs or updates from [archive], whose SHA-256 must be [expected]
  /// (supplied independently, e.g. from the trusted handoff). The previous
  /// release is kept; nothing is downgraded or pruned automatically.
  Future<Map<String, Object?>> install(
    String archive,
    String expected, {
    bool update = false,
  }) async {
    _refuseElevated();
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expected)) {
      throw Refused(
        'Expected SHA-256 must contain exactly 64 hexadecimal characters.',
      );
    }
    final sha = expected.toLowerCase();
    return _transaction(() async {
      final previous = activeState();
      if (update && previous == null) {
        throw Refused(
          'No active installation to update. Use install for first adoption.',
        );
      }
      Directory(layout.releases).createSync(recursive: true);
      final stage = Directory(p.join(layout.releases, '.stage-${_random()}'))
        ..createSync();
      try {
        final (top, receipt) = _extract(archive, sha, stage);
        final source = receipt['source_head'] as String;
        final id = '$source-$sha';
        final destination = layout.release(id);
        if (FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
          // Same archive again: the published payload must be exactly it.
          host.seal(destination, readOnly: false);
          try {
            if (jsonEncode(_validate(Directory(destination))) !=
                jsonEncode(receipt)) {
              throw Refused(
                'Release destination collision; no existing payload was replaced.',
              );
            }
          } finally {
            host.seal(destination, readOnly: true);
          }
        } else {
          Directory(top).renameSync(destination);
          host.seal(destination, readOnly: true);
        }
        final state = <String, Object?>{
          'owner': owner,
          'source': source,
          'archive_sha256': sha,
          'release': id,
          // The client's default (#134); choosing another profile is not a
          // Windows manager command in this delivery.
          'profile': layout.profile,
          'previous': previous == null
              ? null
              : previous['release'] != id
              ? previous['release']
              : previous['previous'],
        };
        // A pre-W5 Roaming profile moves to the managed one before the
        // profile lock (which creates it) can make it look in use.
        final adopted = adoptLegacyProfile(
          target: layout.profile,
          legacy: layout.legacyProfile,
        );
        if (!adopted.moved && adopted.profile != layout.profile) {
          throw Refused('${adopted.note} Quit it and retry.');
        }
        if (adopted.moved) {
          _log('profile_moved', {'from': layout.legacyProfile});
        }
        // The client cannot start, and a running one refuses the update,
        // while the activation record changes.
        host.withProfileLock(
          state['profile']! as String,
          p.join(destination, 'anj_rootfs.dll'),
          () {
            _log('activation_prepared', {
              'source': source,
              'archive_sha256': sha,
            });
            _atomicJson(layout.active, state);
          },
        );
        _log('activated', {'release': id});
        // Committed: what follows can only add problems to report.
        final integration = _integrate(state);
        if (adopted.note != null) {
          (integration['problems']! as List<String>).add(adopted.note!);
        }
        return {...state, 'integration': integration};
      } finally {
        if (stage.existsSync()) {
          host.seal(stage.path, readOnly: false);
          stage.deleteSync(recursive: true);
        }
      }
    });
  }

  /// Copies [archive] into [stage] while hashing it, so the bytes parsed are
  /// the bytes verified; then extracts and validates the single release.
  (String, Map<String, dynamic>) _extract(
    String archive,
    String sha,
    Directory stage, {
    int? size,
    String? mismatch,
  }) {
    final copy = File(p.join(stage.path, '.verified-input.zip'));
    final input = File(archive).openSync();
    final output = copy.openSync(mode: FileMode.writeOnly);
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    var total = 0;
    try {
      while (true) {
        final chunk = input.readSync(1 << 20);
        if (chunk.isEmpty) break;
        total += chunk.length;
        if (total > maxArchiveBytes) {
          throw Refused('Archive exceeds the size limit.');
        }
        hasher.add(chunk);
        output.writeFromSync(chunk);
      }
      hasher.close();
      output.flushSync();
    } finally {
      input.closeSync();
      output.closeSync();
    }
    if (sink.value != sha || (size != null && total != size)) {
      throw Refused(
        mismatch ?? 'Archive SHA-256 does not match the independently supplied expected digest.',
      );
    }
    final ZipArchive zip;
    try {
      zip = ZipArchive.open(copy);
    } on ZipRefused catch (error) {
      throw Refused(error.message);
    }
    final seen = <String>{};
    final roots = <String>{};
    for (final member in zip.members) {
      if (!validRelative(member.name) || !seen.add(member.name.toLowerCase())) {
        throw Refused('Unsafe/duplicate archive member: ${member.name}');
      }
      roots.add(member.name.split('/').first);
    }
    if (roots.length != 1) {
      throw Refused('Archive must contain exactly one release directory.');
    }
    final top = p.join(stage.path, roots.single);
    Directory(top).createSync();
    final ordered = [...zip.members]
      ..sort(
        (a, b) => a.name.split('/').length.compareTo(b.name.split('/').length),
      );
    try {
      for (final member in ordered) {
        final target = p.joinAll([stage.path, ...member.name.split('/')]);
        if (member.directory) {
          Directory(target).createSync(recursive: true);
          continue;
        }
        Directory(p.dirname(target)).createSync(recursive: true);
        final file = File(target);
        if (file.existsSync()) {
          throw Refused('Duplicate archive member: ${member.name}');
        }
        file.writeAsBytesSync(zip.read(member), flush: true);
      }
    } on ZipRefused catch (error) {
      throw Refused(error.message);
    }
    final receipt = _validate(Directory(top));
    final source = receipt['source_head'] as String;
    if (roots.single != 'anj-cloud-windows-x86_64-${source.substring(0, 12)}') {
      throw Refused(
        'Archive directory does not match the release source identity.',
      );
    }
    return (top, receipt);
  }

  /// The release receipt, after checking that the payload is exactly the
  /// files it lists, each with its hash.
  static Map<String, dynamic> _validate(Directory root) {
    final receiptFile = File(p.join(root.path, 'bundle-receipt.json'));
    final Object? decoded;
    try {
      decoded = jsonDecode(receiptFile.readAsStringSync());
    } on Object {
      throw Refused('Missing or invalid release receipt.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Refused('Invalid release receipt object.');
    }
    final hashes = decoded['files_sha256'];
    final source = decoded['source_head'];
    if (decoded['platform'] != 'Windows x86_64' ||
        source is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(source) ||
        hashes is! Map<String, dynamic> ||
        !hashes.keys.toSet().containsAll(requiredFiles)) {
      throw Refused(
        'Unsupported/invalid release receipt (a Windows x86_64 bundle is required).',
      );
    }
    final actual = <String>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      final relative = p
          .relative(entity.path, from: root.path)
          .replaceAll(r'\', '/');
      if (entity is Link) {
        throw Refused('Unsupported payload object: $relative');
      }
      if (entity is File) actual.add(relative);
    }
    if (!(actual.length == hashes.length + 1 &&
        actual.contains('bundle-receipt.json') &&
        hashes.keys.every(actual.contains))) {
      throw Refused('Missing/unexpected payload files.');
    }
    for (final MapEntry(key: relative, value: expected) in hashes.entries) {
      if (!validRelative(relative) ||
          expected is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
        throw Refused('Invalid receipt entry: $relative');
      }
      final file = File(p.joinAll([root.path, ...relative.split('/')]));
      if (sha256.convert(file.readAsBytesSync()).toString() != expected) {
        throw Refused('Payload hash mismatch: $relative');
      }
    }
    return decoded;
  }

  /// A portable, relative release member name.
  static bool validRelative(String value) {
    if (value.isEmpty || value.startsWith('/') || value.contains(r'\')) {
      return false;
    }
    for (final part in value.split('/')) {
      if (part.isEmpty || part == '.' || part == '..' || part.length > 255) {
        return false;
      }
      if (part.codeUnits.any(
        (c) => c < 0x20 || '<>:"|?*'.codeUnits.contains(c),
      )) {
        return false;
      }
      if (part.endsWith('.') || part.endsWith(' ')) return false;
      final base = part.split('.').first.trimRight().toUpperCase();
      if (RegExp(
        r'^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]|CONIN\$|CONOUT\$)$',
      ).hasMatch(base)) {
        return false;
      }
    }
    return true;
  }

  // ---- integration: shortcut, Programs and Features, Run value ----------

  /// The client of the active release. The shortcut and the Run value pass
  /// no profile or manager: the client defaults to the managed profile
  /// (`%LOCALAPPDATA%\anj-cloud\profile`) and finds the manager beside its
  /// executable. Explorer ignores Run values over 260 characters, and a
  /// release directory name alone is over 100.
  ({String client, String manager, String arguments}) _commands(
    Map<String, Object?> state,
  ) {
    final release = layout.release(state['release']! as String);
    return (
      client: p.join(release, 'anj_cloud.exe'),
      manager: p.join(release, 'anj-cloud-manager.exe'),
      arguments: '',
    );
  }

  /// A path the manager may own: inside its own installation.
  bool _ours(String path) => p.isWithin(layout.base, path);

  /// A Run value or Programs and Features entry present but not written by
  /// this manager (another program's, or of another type).
  bool _foreignRun(({bool exists, String? text}) value) =>
      value.exists && (value.text == null || !_ourRun(value.text!));
  bool _foreignEntry(({bool exists, String? text}) value) =>
      value.exists &&
      (value.text == null || !p.equals(value.text!, layout.base));

  /// After the commit: the Run value first (it decides what starts at
  /// login), then the shortcut and the Programs and Features entry. Each
  /// failure is reported as a problem; the switch has already happened.
  Map<String, Object?> _integrate(Map<String, Object?> state) {
    final c = _commands(state);
    final problems = <String>[];
    Map<String, Object?> autostart;
    try {
      autostart = _ensureAutostart(state);
    } on Object catch (error) {
      autostart = {'enabled': false, 'problem': '$error'};
    }
    if (autostart['problem'] != null) problems.add('${autostart['problem']}');
    try {
      final existing = host.readShortcut(layout.shortcut);
      if (existing != null && !_ours(existing.target)) {
        problems.add(
          'A Start menu shortcut "AnJ Cloud" exists and is not ours; it was left alone.',
        );
      } else {
        Directory(p.dirname(layout.shortcut)).createSync(recursive: true);
        host.writeShortcut(
          layout.shortcut,
          target: c.client,
          arguments: c.arguments,
          directory: p.dirname(c.client),
          icon: c.client,
        );
      }
    } on Object catch (error) {
      problems.add('Start menu shortcut: $error');
    }
    try {
      if (_foreignEntry(host.readUninstallLocation())) {
        problems.add(
          'A Programs and Features entry "AnJ Cloud" exists and is not ours; it was left alone.',
        );
      } else {
        host.writeUninstall({
          'DisplayName': 'AnJ Cloud',
          'DisplayVersion': (state['source']! as String).substring(0, 12),
          'Publisher': 'AnJ Cloud',
          'InstallLocation': layout.base,
          'DisplayIcon': c.client,
          'UninstallString': '"${c.manager}" uninstall',
          'NoModify': 1,
          'NoRepair': 1,
        });
      }
    } on Object catch (error) {
      problems.add('Programs and Features entry: $error');
    }
    try {
      _atomicJson(layout.integration, {
        'owner': owner,
        'shortcut': layout.shortcut,
        'release': state['release'],
      });
    } on Object catch (error) {
      problems.add('integration record: $error');
    }
    return {'problems': problems, 'autostart': autostart};
  }

  // ---- start at login ----------------------------------------------------

  String _runValue(Map<String, Object?> state) =>
      '"${_commands(state).client}" --background';

  /// A Run value this manager wrote (it starts a client of this install).
  bool _ourRun(String value) {
    final match = RegExp(r'^"([^"]+)"').firstMatch(value);
    return match != null && _ours(match.group(1)!);
  }

  Map<String, Object?> _readAutostart() {
    final file = File(layout.autostart);
    if (!file.existsSync()) return {'enabled': true, 'source': 'default'};
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return {'enabled': decoded['enabled'] == true, 'source': decoded['source']};
  }

  /// Install and update: on by default (#40) unless the user turned it off;
  /// the Run value follows the active release.
  Map<String, Object?> _ensureAutostart(Map<String, Object?> state) {
    final choice = _readAutostart();
    if (!File(layout.autostart).existsSync()) {
      _atomicJson(layout.autostart, {'owner': owner, ...choice});
    }
    return _applyAutostart(
      state,
      choice['enabled'] == true,
      choice['source'] as String?,
    );
  }

  Map<String, Object?> _applyAutostart(
    Map<String, Object?> state,
    bool enabled,
    String? source,
  ) {
    final current = host.readRun();
    if (_foreignRun(current)) {
      return {
        'enabled': false,
        'source': source,
        'problem':
            'A Run value "$runValueName" exists and is not ours; it was left alone.',
      };
    }
    if (enabled) {
      final value = _runValue(state);
      if (value.length >= 260) {
        return {
          'enabled': false,
          'source': source,
          'problem': 'The installation path is too long for a Run value (260 characters).',
        };
      }
      if (current.text != value) host.writeRun(value);
    } else if (current.exists) {
      host.deleteRun();
    }
    return {'enabled': enabled, 'source': source};
  }

  Future<Map<String, Object?>> autostart(String action) async {
    _refuseElevated();
    return _transaction(() async {
      final state = activeState();
      if (state == null) {
        throw Refused('AnJ Cloud is not installed by this manager.');
      }
      if (action == 'status') {
        final choice = _readAutostart();
        final current = host.readRun();
        if (_foreignRun(current)) {
          return {
            ...choice,
            'enabled': false,
            'problem': 'A Run value "$runValueName" exists and is not ours.',
          };
        }
        return {...choice, 'enabled': current.text == _runValue(state)};
      }
      final enabled = action == 'enable';
      _atomicJson(layout.autostart, {
        'owner': owner,
        'enabled': enabled,
        'source': 'user',
      });
      _log('autostart', {'enabled': enabled});
      return _applyAutostart(state, enabled, 'user');
    });
  }

  // ---- status, run -------------------------------------------------------

  Future<Map<String, Object?>> status() async {
    final state = activeState();
    if (state == null) return {'installed': false};
    return {
      ...state,
      'install_location': layout.base,
      'autostart': _readAutostart(),
      'rollback': 'No automatic downgrade or database restore; the previous release is kept.',
    };
  }

  Future<Map<String, Object?>> run({bool background = false}) async {
    _refuseElevated();
    final state = activeState();
    if (state == null) {
      throw Refused('AnJ Cloud is not installed by this manager.');
    }
    final c = _commands(state);
    final pid = await host.start(c.client, [if (background) '--background']);
    return {'pid': pid, 'release': state['release'], 'background': background};
  }

  // ---- in-app update -----------------------------------------------------

  /// The in-app update, mirroring tool/linux_install.py `apply_update`. The
  /// running app downloaded [archive] and its signed [manifest] into the
  /// active profile's `updates` folder; both (and [result]) must be there.
  ///
  /// Nothing the app says is trusted: the manifest's Ed25519 signature is
  /// verified against the release key built into the ACTIVE release (never
  /// one from the download), it must be a newer `windows-x64` release, and
  /// the archive is copied to a private stage while hashed, so the bytes
  /// checked (signed size and SHA-256, a complete release whose receipt
  /// carries the signed version code) are the bytes installed.
  ///
  /// [check] raises on any refusal and changes nothing. Otherwise every
  /// failure becomes an outcome: it is written to [result], the download is
  /// discarded and the app, which quit for this, is started again. The
  /// update is installed only if the app exits within [wait] (a running app
  /// holds the profile lock, and `install` refuses under it); the app is
  /// started again if it exits within [wait] + [grace]. A failed update
  /// leaves the previous release active: the activation record is the one
  /// commit point, and no release is ever changed in place.
  Future<Map<String, Object?>> applyUpdate(
    String archive,
    String manifest, {
    String? result,
    bool check = false,
    bool relaunch = true,
    Duration wait = const Duration(seconds: 120),
    Duration grace = const Duration(seconds: 300),
    DateTime Function() now = DateTime.now,
    Future<void> Function(Duration)? pause,
  }) async {
    pause ??= Future<void>.delayed;
    if (check) {
      _refuseElevated();
      final state = _installed();
      _updateFiles(state, archive, manifest, result);
      final stage = _updateStage();
      try {
        final signed = _verifyDownload(state, archive, manifest, stage);
        return {
          'ok': true,
          'check': true,
          'version': signed.version,
          'version_code': signed.versionCode,
        };
      } finally {
        _discard(stage);
      }
    }
    final deadline = now().add(wait);
    final relaunchDeadline = deadline.add(grace);
    Map<String, Object?> outcome;
    Map<String, dynamic>? state;
    var closed = false;
    var checked = false;
    RandomAccessFile? lock;
    Directory? stage;
    try {
      _refuseElevated();
      state = _installed();
      lock = _applyLock();
      if (lock == null) {
        // Another apply-update owns this hand-over: it writes the result
        // and starts the app.
        return {
          'ok': false,
          'message': 'Another update is already being applied.',
          'concurrent': true,
        };
      }
      _updateFiles(state, archive, manifest, result);
      checked = true;
      stage = _updateStage();
      final signed = _verifyDownload(state, archive, manifest, stage);
      _tryLog('update_waiting', {'version_code': signed.versionCode});
      Map<String, Object?> applied;
      while (true) {
        if (!await _waitClosed(state, deadline, now, pause)) {
          throw Refused(notQuitMessage);
        }
        try {
          applied = await install(
            p.join(stage.path, '.verified-input.zip'),
            signed.sha256,
            update: true,
          );
          closed = true;
          break;
        } on Busy {
          // Started again between the wait and the install.
          if (!now().isBefore(deadline)) throw Refused(notQuitMessage);
        }
      }
      outcome = {
        'ok': true,
        'version': signed.version,
        'version_code': signed.versionCode,
        'source': applied['source'],
      };
      _tryLog('update_applied', {
        'version_code': signed.versionCode,
        'source': applied['source'],
      });
    } on Object catch (error) {
      // The app has quit for this: always answer and start it again.
      final message = error is Refused
          ? error.message
          : 'The update could not be installed ($error).';
      outcome = {'ok': false, 'message': message};
      _tryLog('update_refused', {'reason': message});
    } finally {
      if (stage != null) _discard(stage);
      if (checked) {
        // Installed or refused, the download is discarded.
        for (final path in [archive, manifest]) {
          try {
            if (FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.file) {
              File(path).deleteSync();
            }
          } on FileSystemException {
            // The app clears its staging folder at its next start.
          }
        }
      }
    }
    try {
      if (checked && result != null) {
        try {
          _atomicJson(result, outcome);
        } on FileSystemException catch (error) {
          _tryLog('update_result_unwritten', {'reason': '$error'});
        }
      }
      if (relaunch && state != null) {
        closed =
            closed || await _waitClosed(state, relaunchDeadline, now, pause);
        var started = false;
        if (closed) {
          try {
            // The active release: the new one, or after a refusal the one
            // that was running.
            await run();
            started = true;
          } on Object catch (error) {
            _tryLog('update_relaunch_failed', {'reason': '$error'});
          }
        }
        outcome['relaunched'] = started;
      }
    } finally {
      lock?.closeSync();
    }
    return outcome;
  }

  Map<String, dynamic> _installed() {
    final state = activeState();
    if (state == null) {
      throw Refused('AnJ Cloud is not installed by this manager.');
    }
    return state;
  }

  void _tryLog(String event, Map<String, Object?> fields) {
    try {
      _log(event, fields);
    } on FileSystemException {
      // The log is not worth failing an update's answer for.
    }
  }

  /// One apply-update at a time; null while another holds it.
  RandomAccessFile? _applyLock() {
    final lock = File(p.join(layout.base, '.apply-update.lock'))
        .openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      return lock;
    } on FileSystemException {
      lock.closeSync();
      return null;
    }
  }

  Directory _updateStage() =>
      Directory(p.join(layout.releases, '.update-${_random()}'))
        ..createSync(recursive: true);

  void _discard(Directory stage) {
    try {
      if (stage.existsSync()) {
        host.seal(stage.path, readOnly: false);
        stage.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Left for a later run; never trusted again.
    }
  }

  /// Refuses unless the update's files are absolute paths directly in the
  /// active profile's `updates` folder, the download being regular files.
  void _updateFiles(
    Map<String, dynamic> state,
    String archive,
    String manifest,
    String? result,
  ) {
    final updates = p.join(state['profile'] as String, 'updates');
    final inside =
        FileSystemEntity.typeSync(updates, followLinks: false) ==
            FileSystemEntityType.directory &&
        [archive, manifest, ?result].every(
          (path) =>
              p.isAbsolute(path) &&
              p.equals(p.dirname(p.normalize(path)), updates),
        );
    if (!inside) {
      throw Refused(
        "Update files must be in the active profile's updates folder.",
      );
    }
    for (final path in [archive, manifest]) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw Refused('The downloaded update is missing.');
      }
    }
  }

  /// The version code the active release's receipt carries (0: a release
  /// packaged without one).
  int _installedVersionCode(String release) {
    try {
      final receipt = jsonDecode(
        File(p.join(release, 'bundle-receipt.json')).readAsStringSync(),
      );
      final code = receipt is Map ? receipt['version_code'] : null;
      return code is int && code >= 0 ? code : 0;
    } on Object {
      return 0;
    }
  }

  /// The signed manifest when [archive], copied into [stage] while hashed,
  /// is the newer release it names for the active release's built-in key.
  ReleaseManifest _verifyDownload(
    Map<String, dynamic> state,
    String archive,
    String manifestPath,
    Directory stage,
  ) {
    final active = layout.release(state['release'] as String);
    final ReleaseKey? key;
    try {
      final file = File(p.joinAll([active, ...releaseKeyPayload.split('/')]));
      key = file.existsSync()
          ? ReleaseKey.parse(file.readAsStringSync())
          : null;
    } on FormatException {
      throw Refused('The built-in release key file is malformed.');
    }
    if (key == null) {
      throw Refused(
        'This release has no built-in release key; update it with '
        '`anj-cloud-manager.exe update`.',
      );
    }
    final file = File(manifestPath);
    if (file.lengthSync() > 64 * 1024) {
      throw Refused('The update record is too large.');
    }
    final Object? data;
    try {
      data = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw Refused('The update record is not JSON.');
    }
    final ReleaseManifest manifest;
    try {
      manifest = ReleaseManifest.fromJson(data, windowsReleaseTarget);
    } on FormatException catch (error) {
      throw Refused(error.message);
    }
    final refusal = desktopRefusal(
      manifest,
      key,
      _installedVersionCode(active),
      windowsReleaseTarget,
    );
    if (refusal != null) throw Refused(refusal);
    final (_, receipt) = _extract(
      archive,
      manifest.sha256,
      stage,
      size: manifest.size,
      mismatch:
          'The downloaded update does not match its signed size and SHA-256.',
    );
    if (receipt['version_code'] != manifest.versionCode) {
      throw Refused("The update's receipt does not match its signed version.");
    }
    return manifest;
  }

  /// True once nothing holds the profile lifetime lock: the app has exited.
  Future<bool> _waitClosed(
    Map<String, dynamic> state,
    DateTime deadline,
    DateTime Function() now,
    Future<void> Function(Duration) pause,
  ) async {
    final library = p.join(
      layout.release(state['release'] as String),
      'anj_rootfs.dll',
    );
    while (true) {
      try {
        host.withProfileLock(state['profile'] as String, library, () {});
        return true;
      } on Busy {
        if (!now().isBefore(deadline)) return false;
        await pause(const Duration(milliseconds: 250));
      }
    }
  }

  // ---- uninstall ---------------------------------------------------------

  /// Removes exactly what install added: the Run value, the Start menu
  /// shortcut and the Programs and Features entry when they are still ours,
  /// then the installation directory (releases, records, log). Never the
  /// profile, the secrets, the synchronized root or the client's logs.
  /// Refused while the client runs.
  Future<Map<String, Object?>> uninstall({required String library}) async {
    _refuseElevated();
    return _transaction(() async {
      final state = activeState();
      final removed = <String>[];
      final kept = <String>[];
      String? tombstone;
      void inner() {
        final run = host.readRun();
        if (run.exists) {
          if (!_foreignRun(run)) {
            host.deleteRun();
            removed.add('Run value $runValueName');
          } else {
            kept.add('Run value $runValueName (not ours)');
          }
        }
        final shortcut = host.readShortcut(layout.shortcut);
        if (shortcut != null) {
          if (_ours(shortcut.target)) {
            File(layout.shortcut).deleteSync();
            removed.add(layout.shortcut);
          } else {
            kept.add('${layout.shortcut} (not ours)');
          }
        }
        final entry = host.readUninstallLocation();
        if (entry.exists) {
          if (!_foreignEntry(entry)) {
            host.deleteUninstall();
            removed.add('Programs and Features entry');
          } else {
            kept.add('Programs and Features entry (not ours)');
          }
        }
        // Still under both locks: no install or client can start between
        // the check and the removal. The rename is the removal; the
        // tombstone is deleted afterwards (a later run sweeps leftovers).
        if (Directory(layout.base).existsSync()) {
          _log('uninstalled', {'removed': removed});
          tombstone = p.join(
            p.dirname(layout.base),
            'anj-cloud.removing-${_random()}',
          );
          Directory(layout.base).renameSync(tombstone!);
          removed.add(layout.base);
        }
      }

      if (state != null) {
        host.withProfileLock(state['profile']! as String, library, inner);
      } else {
        inner();
      }
      if (tombstone != null) {
        try {
          host.seal(tombstone!, readOnly: false);
          Directory(tombstone!).deleteSync(recursive: true);
        } on FileSystemException {
          kept.add('$tombstone (removed by the next manager run)');
        }
      }
      return {
        'removed': removed,
        'kept': kept,
        'profile_kept': state?['profile'] ?? layout.profile,
      };
    }).then((result) {
      try {
        File(layout.transaction).deleteSync();
      } on FileSystemException {
        // Another manager holds it now; it stays a harmless empty file.
      }
      return result;
    });
  }
}

class _DigestSink implements Sink<Digest> {
  String? value;
  @override
  void add(Digest data) => value = data.toString();
  @override
  void close() {}
}
