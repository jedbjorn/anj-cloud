// The Windows manager's apply-update (the in-app
// update) against a fake Windows and real archives, on any host. Manifests
// are signed with a throwaway Ed25519 key by the OpenSSL CLI (test fixture
// only). The real profile lock, detached hand-over and restart are checked
// on the Windows seat.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/update/release.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/windows_manager/manager.dart';
import 'test_platform.dart';
import 'windows_manager_test.dart' show FakeHost, zipOf;

/// A fake Windows whose client holds the profile lock for a number of
/// lock attempts, and which records what the manager starts.
class UpdateHost extends FakeHost {
  UpdateHost(super.root);
  int busyAttempts = 0;
  final started = <String>[];

  /// Thrown by every lock attempt (a lock that fails for another reason
  /// than "held").
  Object? lockError;

  /// Thrown once, after the locked action ran (a failure past the commit).
  Object? failAfterAction;
  Object? startError;

  @override
  T withProfileLock<T>(String profile, String library, T Function() action) {
    if (lockError != null) throw lockError!;
    if (busyAttempts > 0) {
      busyAttempts--;
      throw Busy();
    }
    final value = super.withProfileLock(profile, library, action);
    final late = failAfterAction;
    if (late != null) {
      failAfterAction = null;
      throw late;
    }
    return value;
  }

  @override
  Future<int> start(String executable, List<String> arguments) async {
    if (startError != null) throw startError!;
    started.add(executable);
    return 42;
  }
}

/// A manager whose two cross-process locks can be held by "another
/// process" (a second lock from this process would simply succeed).
class ContendedManager extends Manager {
  ContendedManager(super.host);
  bool applying = false;
  int transactionsHeld = 0;

  @override
  RandomAccessFile? applyLock() => applying ? null : super.applyLock();

  @override
  RandomAccessFile transactionLock() {
    if (transactionsHeld > 0) {
      transactionsHeld--;
      throw TransactionBusy();
    }
    return super.transactionLock();
  }
}

String sourceOf(int code) => code.toRadixString(16).padLeft(40, '0');

/// A release archive of version [code] trusting [keyText] (none when null).
List<int> release(
  int code, {
  String? keyText,
  int? receiptCode,
  bool stamped = true,
}) {
  final source = sourceOf(code);
  final top = 'anj-cloud-windows-x86_64-${source.substring(0, 12)}';
  final files = <String, List<int>>{
    for (final name in requiredFiles) name: utf8.encode('$name $code'),
    releaseKeyPayload: ?(keyText == null ? null : utf8.encode(keyText)),
  };
  final receipt = {
    'platform': 'Windows x86_64',
    'source_head': source,
    if (stamped) 'version': '2026.11.11.$code',
    if (stamped) 'version_code': receiptCode ?? code,
    'files_sha256': {
      for (final e in files.entries) e.key: sha256.convert(e.value).toString(),
    },
  };
  return zipOf({
    for (final e in files.entries) '$top/${e.key}': e.value,
    '$top/bundle-receipt.json': utf8.encode(jsonEncode(receipt)),
  }, deflate: true);
}

void main() {
  if (skipSuite(
    'Windows apply-update with OpenSSL-signed manifests',
    opensslSkip,
  )) {
    return;
  }
  late Directory keys;
  late File privateKey;
  late String keyText;
  late File otherPrivateKey;
  late String otherKeyText;

  Future<String> generate(File key) async {
    final made = await Process.run(testOpenssl!, [
      'genpkey',
      '-algorithm',
      'ed25519',
      '-out',
      key.path,
    ]);
    expect(made.exitCode, 0);
    final der = await Process.run(testOpenssl!, [
      'pkey',
      '-in',
      key.path,
      '-pubout',
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    return '# test\ned25519 ${base64.encode((der.stdout as List<int>).sublist(12))}\n';
  }

  setUpAll(() async {
    keys = Directory.systemTemp.createTempSync('anj-windows-update-keys-');
    privateKey = File(p.join(keys.path, 'release.pem'));
    keyText = await generate(privateKey);
    otherPrivateKey = File(p.join(keys.path, 'other.pem'));
    otherKeyText = await generate(otherPrivateKey);
  });
  tearDownAll(() => keys.deleteSync(recursive: true));

  /// The signed manifest of [bytes] as version [code].
  Future<Map<String, Object>> signed(
    int code,
    List<int> bytes, {
    File? signer,
    String? signerKeyText,
    String target = windowsReleaseTarget,
  }) async {
    final unsigned = ReleaseManifest(
      target: target,
      version: '2026.11.11.$code',
      versionCode: code,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      keyId: ReleaseKey.parse(signerKeyText ?? keyText)!.id,
      signature: '${'A' * 86}==',
    );
    final message = File(p.join(keys.path, 'message'))
      ..writeAsBytesSync(unsigned.signedMessage);
    final signature = File(p.join(keys.path, 'signature'));
    final done = await Process.run(testOpenssl!, [
      'pkeyutl',
      '-sign',
      '-inkey',
      (signer ?? privateKey).path,
      '-rawin',
      '-in',
      message.path,
      '-out',
      signature.path,
    ]);
    expect(done.exitCode, 0);
    return {
      ...unsigned.toJson(),
      'signature': base64.encode(signature.readAsBytesSync()),
    };
  }

  late Directory temp;
  late UpdateHost host;
  late ContendedManager manager;
  late Directory updates;
  late String firstRelease;

  /// Installs version 10 (trusting the test key unless [key] says
  /// otherwise) with the profile's staging folder present.
  Future<void> install({bool key = true, bool stamped = true}) async {
    final bytes = release(10, keyText: key ? keyText : null, stamped: stamped);
    final file = File(p.join(temp.path, 'first.zip'))..writeAsBytesSync(bytes);
    await manager.install(file.path, sha256.convert(bytes).toString());
    firstRelease = manager.activeState()!['release'] as String;
    updates = Directory(p.join(manager.layout.profile, 'updates'))
      ..createSync(recursive: true);
    host.locks.clear();
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anj-windows-update-');
    host = UpdateHost(temp.path);
    manager = ContendedManager(host);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// The app's download in the staging folder: (archive, manifest, result).
  (String, String, String) download(
    List<int> bytes,
    Map<String, Object?> manifest,
  ) {
    final code = manifest['version_code'];
    final archive = File(p.join(updates.path, '$code.tar.gz'))
      ..writeAsBytesSync(bytes);
    final record = File(p.join(updates.path, '$code.json'))
      ..writeAsStringSync(jsonEncode(manifest));
    return (archive.path, record.path, p.join(updates.path, 'result.json'));
  }

  Future<void> pause(Duration _) async {}

  /// Nothing changed: the first release is active and nothing is staged.
  void expectUntouched() {
    expect(manager.activeState()!['release'], firstRelease);
    expect(
      Directory(manager.layout.releases)
          .listSync()
          .map((e) => p.basename(e.path)),
      [firstRelease],
    );
  }

  Matcher refused(String message) =>
      throwsA(isA<Refused>().having((e) => e.message, 'message', message));

  test('check accepts a signed newer release and changes nothing', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(11, bytes));
    expect(await manager.applyUpdate(archive, manifest, check: true), {
      'ok': true,
      'check': true,
      'version': '2026.11.11.11',
      'version_code': 11,
    });
    expectUntouched();
    expect(File(archive).existsSync(), isTrue);
    expect(File(manifest).existsSync(), isTrue);
    expect(host.started, isEmpty);
    // The check never needs the app to quit.
    expect(host.locks, isEmpty);
  });

  test('every tamper is refused and nothing is installed', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final good = await signed(11, bytes);
    Future<void> expectRefused(
      List<int> package,
      Map<String, Object?> manifest,
      String message,
    ) async {
      final (archive, record, result) = download(package, manifest);
      await expectLater(
        manager.applyUpdate(archive, record, check: true),
        refused(message),
      );
      expectUntouched();
      // The hand-over refuses the same download, as an outcome.
      final outcome = await manager.applyUpdate(
        archive,
        record,
        result: result,
        pause: pause,
      );
      expect(outcome['ok'], isFalse);
      expect(outcome['message'], message);
      expect(jsonDecode(File(result).readAsStringSync()), {
        'ok': false,
        'message': message,
      });
      expect(File(archive).existsSync(), isFalse);
      expect(File(record).existsSync(), isFalse);
      expectUntouched();
    }

    const mismatch =
        'The downloaded update does not match its signed size and SHA-256.';
    // The package: one byte changed, truncated, extended.
    await expectRefused([...bytes]..[40] ^= 1, good, mismatch);
    await expectRefused(bytes.sublist(0, bytes.length - 1), good, mismatch);
    await expectRefused([...bytes, 0], good, mismatch);
    // The manifest: any signed field changed after signing.
    const unsigned = "The update's signature does not verify.";
    await expectRefused(bytes, {...good, 'version_code': 12}, unsigned);
    await expectRefused(bytes, {...good, 'version': '2026.11.11.12'}, unsigned);
    await expectRefused(bytes, {...good, 'size': bytes.length + 1}, unsigned);
    await expectRefused(bytes, {...good, 'sha256': 'a' * 64}, unsigned);
    // The signature: another one, and another key's under this key's id.
    final other = await signed(12, bytes);
    await expectRefused(bytes, {
      ...good,
      'signature': other['signature'],
    }, unsigned);
    await expectRefused(
      bytes,
      await signed(11, bytes, signer: otherPrivateKey),
      unsigned,
    );
    // The key: a manifest naming another key.
    await expectRefused(bytes, {
      ...good,
      'key_id': '0123456789abcdef',
    }, 'The update is signed with a different key than this app trusts.');
    // Another platform's release, a malformed record, unexpected fields.
    await expectRefused(
      bytes,
      await signed(11, bytes, target: linuxReleaseTarget),
      'The update record is for another device type.',
    );
    await expectRefused(bytes, {
      ...good,
      'installer': 'x',
    }, 'The update record has unexpected fields.');
    // A downgrade and a replay of the installed version, both signed.
    final older = release(9, keyText: keyText);
    await expectRefused(
      older,
      await signed(9, older),
      'The update (9) is not newer than this version (10).',
    );
    final same = release(10, keyText: keyText);
    await expectRefused(
      same,
      await signed(10, same),
      'The update (10) is not newer than this version (10).',
    );
    // A signed manifest whose package is another version's build.
    final relabelled = release(11, keyText: keyText, receiptCode: 10);
    await expectRefused(
      relabelled,
      await signed(11, relabelled),
      "The update's receipt does not match its signed version.",
    );
    // A signed package that is not a complete release.
    final broken = zipOf({
      'anj-cloud-windows-x86_64-x/readme.txt': [1],
    });
    await expectRefused(
      broken,
      await signed(11, broken),
      'Missing or invalid release receipt.',
    );
    expect(host.started, everyElement(endsWith('anj_cloud.exe')));
    expect(host.started.toSet(), {
      p.join(manager.layout.release(firstRelease), 'anj_cloud.exe'),
    });
  });

  test('a record that is not JSON is refused', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(11, bytes));
    File(manifest).writeAsStringSync('{');
    await expectLater(
      manager.applyUpdate(archive, manifest, check: true),
      refused('The update record is not JSON.'),
    );
    expectUntouched();
  });

  test('update files outside the profile staging folder are refused', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    const message =
        "Update files must be in the active profile's updates folder.";
    final outside = File(p.join(temp.path, 'outside.zip'))
      ..writeAsBytesSync(bytes);
    final nested = Directory(p.join(updates.path, 'deeper'))..createSync();
    for (final (a, m, r) in [
      (outside.path, manifest, result),
      (archive, p.join(temp.path, 'outside.json'), result),
      (archive, manifest, p.join(temp.path, 'result.json')),
      (p.join(nested.path, 'x.zip'), manifest, result),
      (p.join(updates.path, '..', '..', 'x.zip'), manifest, result),
      ('11.tar.gz', manifest, result),
    ]) {
      await expectLater(
        manager.applyUpdate(a, m, result: r, check: true),
        refused(message),
      );
      // The hand-over neither deletes nor writes outside the folder.
      final outcome = await manager.applyUpdate(a, m, result: r, pause: pause);
      expect(outcome['message'], message);
    }
    expect(outside.existsSync(), isTrue);
    expect(File(p.join(temp.path, 'result.json')).existsSync(), isFalse);
    expect(File(result).existsSync(), isFalse);
    expect(File(archive).existsSync(), isTrue);
    expectUntouched();
    await expectLater(
      manager.applyUpdate(
        p.join(updates.path, 'absent.zip'),
        manifest,
        check: true,
      ),
      refused('The downloaded update is missing.'),
    );
  });

  test('a release without a built-in key never updates itself', () async {
    await install(key: false);
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(11, bytes));
    await expectLater(
      manager.applyUpdate(archive, manifest, check: true),
      refused(
        'This release has no built-in release key; update it with '
        '`anj-cloud-manager.exe update`.',
      ),
    );
    expectUntouched();
  });

  test('the key in the download is never the one that is trusted', () async {
    await install();
    // The whole attack: an archive carrying the attacker's public key, a
    // manifest signed by the attacker's private key and naming the
    // attacker's key id. A manager that trusted the downloaded key would
    // accept it.
    final bytes = release(11, keyText: otherKeyText);
    final forged = await signed(
      11,
      bytes,
      signer: otherPrivateKey,
      signerKeyText: otherKeyText,
    );
    expect(
      ReleaseKey.parse(otherKeyText)!
          .verify(ReleaseManifest.fromJson(forged, windowsReleaseTarget)),
      isTrue,
      reason: 'the forgery is valid for the key it carries',
    );
    final (archive, manifest, result) = download(bytes, forged);
    const message =
        'The update is signed with a different key than this app trusts.';
    await expectLater(
      manager.applyUpdate(archive, manifest, check: true),
      refused(message),
    );
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome['message'], message);
    expectUntouched();
    // The same forgery under the installed key's id fails on the signature.
    final renamed = {...forged, 'key_id': ReleaseKey.parse(keyText)!.id};
    final (a, m, _) = download(bytes, renamed);
    await expectLater(
      manager.applyUpdate(a, m, check: true),
      refused("The update's signature does not verify."),
    );
    expectUntouched();
  });

  test('not installed or elevated: refused', () async {
    await expectLater(
      manager.applyUpdate('a', 'b', check: true),
      refused('AnJ Cloud is not installed by this manager.'),
    );
    final outcome = await manager.applyUpdate('a', 'b', pause: pause);
    expect(outcome, {
      'ok': false,
      'message': 'AnJ Cloud is not installed by this manager.',
    });
    await install();
    host.admin = true;
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(11, bytes));
    const elevated =
        'Run the manager as your normal Windows user, not as administrator: '
        'AnJ Cloud is installed per user and runs unelevated.';
    await expectLater(
      manager.applyUpdate(archive, manifest, check: true),
      refused(elevated),
    );
    // The hand-over refuses too: nothing installed, deleted, written or
    // started by an elevated manager.
    final refusedOutcome = await manager.applyUpdate(
      archive,
      manifest,
      result: p.join(updates.path, 'result.json'),
      pause: pause,
    );
    expect(refusedOutcome, {'ok': false, 'message': elevated});
    expect(File(archive).existsSync(), isTrue);
    expect(File(p.join(updates.path, 'result.json')).existsSync(), isFalse);
    expect(host.started, isEmpty);
    expectUntouched();
  });

  test(
    'the update installs once the app has quit, and starts it again',
    () async {
      await install();
      final bytes = release(11, keyText: keyText);
      final (archive, manifest, result) = download(
        bytes,
        await signed(11, bytes),
      );
      // The app still holds the profile lock for a while.
      host.busyAttempts = 3;
      var pauses = 0;
      final outcome = await manager.applyUpdate(
        archive,
        manifest,
        result: result,
        pause: (_) async => pauses++,
      );
      final id = '${sourceOf(11)}-${sha256.convert(bytes)}';
      expect(outcome, {
        'ok': true,
        'version': '2026.11.11.11',
        'version_code': 11,
        'source': sourceOf(11),
        'relaunched': true,
      });
      expect(pauses, 3);
      final state = manager.activeState()!;
      expect(state['release'], id);
      // The previous release is kept, untouched.
      expect(state['previous'], firstRelease);
      expect(
        File(p.join(manager.layout.release(firstRelease), 'anj_cloud.exe'))
            .readAsStringSync(),
        'anj_cloud.exe 10',
      );
      // The profile is the same one; only its download is gone.
      expect(state['profile'], manager.layout.profile);
      expect(File(archive).existsSync(), isFalse);
      expect(File(manifest).existsSync(), isFalse);
      expect(jsonDecode(File(result).readAsStringSync()), {
        'ok': true,
        'version': '2026.11.11.11',
        'version_code': 11,
        'source': sourceOf(11),
      });
      // The new release is what starts, and what starts at login.
      final client = p.join(manager.layout.release(id), 'anj_cloud.exe');
      expect(host.started, [client]);
      expect(host.run, '"$client" --background');
      expect(
        Directory(manager.layout.releases)
            .listSync()
            .map((e) => p.basename(e.path))
            .toSet(),
        {firstRelease, id},
      );
      // A second update on top of it.
      final next = release(12, keyText: keyText);
      final (a, m, r) = download(next, await signed(12, next));
      expect(
        (await manager.applyUpdate(a, m, result: r, pause: pause))['ok'],
        isTrue,
      );
      expect(manager.activeState()!['previous'], id);
    },
  );

  test('an app that does not quit in time is not updated', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    host.busyAttempts = 1 << 30;
    var clock = DateTime.utc(2026, 11, 11);
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      now: () => clock,
      pause: (step) async => clock = clock.add(const Duration(seconds: 30)),
    );
    expect(outcome, {
      'ok': false,
      'message': notQuitMessage,
      'relaunched': false,
    });
    expectUntouched();
    expect(host.started, isEmpty);
    expect(File(archive).existsSync(), isFalse);
    expect(
      jsonDecode(File(result).readAsStringSync())['message'],
      notQuitMessage,
    );
  });

  test('an app that quits late is started again on its own release', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    var clock = DateTime.utc(2026, 11, 11);
    // Busy past the install deadline (120 s), free within the grace.
    host.busyAttempts = 6;
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      now: () => clock,
      pause: (step) async => clock = clock.add(const Duration(seconds: 30)),
    );
    expect(outcome['ok'], isFalse);
    expect(outcome['relaunched'], isTrue);
    expectUntouched();
    expect(host.started, [
      p.join(manager.layout.release(firstRelease), 'anj_cloud.exe'),
    ]);
  });

  test('without relaunch the manager only installs', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      relaunch: false,
      pause: pause,
    );
    expect(outcome['ok'], isTrue);
    expect(outcome.containsKey('relaunched'), isFalse);
    expect(host.started, isEmpty);
  });

  test(
    'a release installed while the update waited is never replaced',
    () async {
      await install();
      final bytes = release(11, keyText: keyText);
      final (archive, manifest, result) = download(
        bytes,
        await signed(11, bytes),
      );
      // Verified against version 10. While the app is still quitting, a
      // manual update to version 12 goes in.
      final newer = release(12, keyText: keyText);
      final newerFile = File(p.join(temp.path, 'newer.zip'))
        ..writeAsBytesSync(newer);
      host.busyAttempts = 1;
      final outcome = await manager.applyUpdate(
        archive,
        manifest,
        result: result,
        pause: (_) async {
          await manager.install(
            newerFile.path,
            sha256.convert(newer).toString(),
            update: true,
          );
        },
      );
      expect(outcome['ok'], isFalse);
      expect(outcome['message'], releaseChangedMessage);
      final twelve = '${sourceOf(12)}-${sha256.convert(newer)}';
      expect(manager.activeState()!['release'], twelve);
      // Version 11 was never published, and the app comes back on version 12.
      expect(
        Directory(manager.layout.releases)
            .listSync()
            .map((e) => p.basename(e.path))
            .toSet(),
        {firstRelease, twelve},
      );
      expect(outcome['relaunched'], isTrue);
      expect(host.started, [
        p.join(manager.layout.release(twelve), 'anj_cloud.exe'),
      ]);
    },
  );

  test('a profile lock that fails still ends with the app started', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    // Not "held": the lock itself fails, for the wait and for the restart.
    host.lockError = Refused('The profile lock cannot be taken.');
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome['ok'], isFalse);
    expect(outcome['message'], 'The profile lock cannot be taken.');
    expect(outcome['relaunched'], isTrue);
    expect(host.started, [
      p.join(manager.layout.release(firstRelease), 'anj_cloud.exe'),
    ]);
    host.lockError = null;
    expectUntouched();
    expect(jsonDecode(File(result).readAsStringSync())['ok'], isFalse);
  });

  test(
    'nothing changes while the app runs, not even a release directory',
    () async {
      await install();
      final bytes = release(11, keyText: keyText);
      final (archive, manifest, result) = download(
        bytes,
        await signed(11, bytes),
      );
      host.busyAttempts = 4;
      host.alive.add(4711);
      final seen = <Set<String>>[];
      final outcome = await manager.applyUpdate(
        archive,
        manifest,
        result: result,
        appPid: 4711,
        pause: (_) async {
          seen.add(
            Directory(manager.layout.releases)
                .listSync()
                .map((e) => p.basename(e.path))
                .where((name) => !name.startsWith('.'))
                .toSet(),
          );
          expect(manager.activeState()!['release'], firstRelease);
        },
      );
      // Four refused attempts, each leaving only the installed release.
      expect(seen, List.filled(4, {firstRelease}));
      expect(outcome['ok'], isTrue);
      expect(outcome['relaunched'], isTrue);
      expect(manager.activeState()!['release'], isNot(firstRelease));
    },
  );

  test(
    'an app started again abandons the update and owns its folder',
    () async {
      await install();
      final bytes = release(11, keyText: keyText);
      final (archive, manifest, result) = download(
        bytes,
        await signed(11, bytes),
      );
      // The process that handed over (4711) has exited, yet the profile is
      // held: another instance runs.
      host.busyAttempts = 1 << 30;
      var pauses = 0;
      final outcome = await manager.applyUpdate(
        archive,
        manifest,
        result: result,
        appPid: 4711,
        pause: (_) async => pauses++,
      );
      expect(outcome, {
        'ok': false,
        'message': startedAgainMessage,
        'started_again': true,
      });
      // Given up at once (the second look), not after two minutes.
      expect(pauses, 1);
      // That instance's folder is left alone and nothing is started.
      expect(File(archive).existsSync(), isTrue);
      expect(File(manifest).existsSync(), isTrue);
      expect(File(result).existsSync(), isFalse);
      expect(host.started, isEmpty);
      host.busyAttempts = 0;
      expectUntouched();
    },
  );

  test('a slow app is told from a restarted one by its process', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    // Still quitting after two minutes; it exits during the grace.
    host.busyAttempts = 1 << 30;
    host.alive.add(4711);
    var clock = DateTime.utc(2026, 11, 11);
    final start = clock;
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      appPid: 4711,
      now: () => clock,
      pause: (_) async {
        clock = clock.add(const Duration(seconds: 30));
        if (clock.difference(start) >= const Duration(seconds: 200)) {
          host.alive.remove(4711);
          host.busyAttempts = 0;
        }
      },
    );
    expect(outcome['message'], notQuitMessage);
    expect(outcome['relaunched'], isTrue);
    expect(host.started, [
      p.join(manager.layout.release(firstRelease), 'anj_cloud.exe'),
    ]);
    expectUntouched();
    // It exited, and someone had already started it again: nothing more.
    host.started.clear();
    final again = release(11, keyText: keyText);
    final (a, m, r) = download(again, await signed(11, again));
    host.busyAttempts = 1 << 30;
    host.alive.add(4712);
    clock = DateTime.utc(2026, 11, 12);
    final second = clock;
    final later = await manager.applyUpdate(
      a,
      m,
      result: r,
      appPid: 4712,
      now: () => clock,
      pause: (_) async {
        clock = clock.add(const Duration(seconds: 30));
        if (clock.difference(second) >= const Duration(seconds: 200)) {
          host.alive.remove(4712);
        }
      },
    );
    expect(later['message'], notQuitMessage);
    expect(later['relaunched'], isFalse);
    expect(host.started, isEmpty);
    host.busyAttempts = 0;
  });

  test('a download replaced since the hand-over is not deleted', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    host.busyAttempts = 1 << 30;
    var clock = DateTime.utc(2026, 11, 11);
    var replaced = false;
    await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      now: () => clock,
      pause: (_) async {
        clock = clock.add(const Duration(seconds: 30));
        if (!replaced) {
          // A newer app instance downloads again under the same name.
          File(archive).writeAsBytesSync([...bytes, 1, 2, 3]);
          replaced = true;
        }
      },
    );
    host.busyAttempts = 0;
    expect(File(archive).existsSync(), isTrue);
    expect(File(archive).lengthSync(), bytes.length + 3);
    // The manifest is the file that was handed over: discarded.
    expect(File(manifest).existsSync(), isFalse);
    expectUntouched();
  });

  test('another manager command delays the update, or refuses it', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    // Held for two attempts, then free: installed.
    manager.transactionsHeld = 2;
    var pauses = 0;
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: (_) async => pauses++,
    );
    expect(pauses, 2);
    expect(outcome['ok'], isTrue);
    final second = manager.activeState()!['release'];
    // Held past the deadline: refused with its own reason, app restarted.
    final next = release(12, keyText: keyText);
    final (a, m, r) = download(next, await signed(12, next));
    manager.transactionsHeld = 1 << 30;
    var clock = DateTime.utc(2026, 11, 11);
    host.started.clear();
    final refusedOutcome = await manager.applyUpdate(
      a,
      m,
      result: r,
      now: () => clock,
      pause: (_) async => clock = clock.add(const Duration(seconds: 30)),
    );
    manager.transactionsHeld = 0;
    expect(refusedOutcome['message'], otherCommandMessage);
    expect(refusedOutcome['relaunched'], isTrue);
    expect(manager.activeState()!['release'], second);
    expect(host.started, [
      p.join(manager.layout.release(second as String), 'anj_cloud.exe'),
    ]);
  });

  test('a second hand-over while one runs changes nothing', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    manager.applying = true;
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome, {
      'ok': false,
      'message': 'Another update is already being applied.',
      'concurrent': true,
    });
    // The first one owns the download, the result and the restart.
    expect(File(archive).existsSync(), isTrue);
    expect(File(manifest).existsSync(), isTrue);
    expect(File(result).existsSync(), isFalse);
    expect(host.started, isEmpty);
    expectUntouched();
  });

  test('a result that cannot be written does not stop the restart', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    // Something sits where the result goes.
    Directory(result).createSync();
    File(p.join(result, 'in-the-way')).writeAsStringSync('x');
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome['ok'], isTrue);
    expect(outcome['relaunched'], isTrue);
    expect(host.started, hasLength(1));
    expect(
      File(manager.layout.log).readAsStringSync(),
      contains('update_result_unwritten'),
    );
  });

  test('a restart that fails is reported, the update stays', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    host.startError = const FileSystemException('cannot start');
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome['ok'], isTrue);
    expect(outcome['relaunched'], isFalse);
    expect(manager.activeState()!['release'], isNot(firstRelease));
    expect(jsonDecode(File(result).readAsStringSync())['ok'], isTrue);
    expect(
      File(manager.layout.log).readAsStringSync(),
      contains('update_relaunch_failed'),
    );
  });

  test('a failure after the activation is reported as installed', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    // The activation record is written; releasing the lock then fails.
    host.failAfterAction = const FileSystemException('lock release failed');
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    final id = '${sourceOf(11)}-${sha256.convert(bytes)}';
    expect(manager.activeState()!['release'], id);
    expect(outcome['ok'], isTrue);
    expect(outcome['release'], id);
    expect(outcome['problem'], contains('lock release failed'));
    expect(jsonDecode(File(result).readAsStringSync())['ok'], isTrue);
    expect(host.started, [p.join(manager.layout.release(id), 'anj_cloud.exe')]);
  });

  test('stages a killed manager left behind are swept', () async {
    await install();
    // Left by managers killed during a wait or an install (sign-out, power
    // loss); a recent check stage may still be in use.
    for (final name in ['.update-dead', '.stage-dead', '.check-recent']) {
      Directory(p.join(manager.layout.releases, name, 'payload'))
          .createSync(recursive: true);
      File(p.join(manager.layout.releases, name, 'payload', 'big.bin'))
          .writeAsBytesSync(List.filled(1024, 7));
    }
    Set<String> stages() =>
        Directory(manager.layout.releases)
            .listSync()
            .map((e) => p.basename(e.path))
            .where((name) => name.startsWith('.'))
            .toSet();
    // While another apply-update runs its stage is live: not swept by an
    // install, which still sweeps its own kind.
    manager.applying = true;
    final again = release(10, keyText: keyText);
    final file = File(p.join(temp.path, 'again.zip'))..writeAsBytesSync(again);
    await manager.install(file.path, sha256.convert(again).toString());
    expect(stages(), {'.update-dead', '.check-recent'});
    manager.applying = false;
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, result) = download(
      bytes,
      await signed(11, bytes),
    );
    Directory(p.join(manager.layout.releases, '.stage-dead')).createSync();
    final outcome = await manager.applyUpdate(
      archive,
      manifest,
      result: result,
      pause: pause,
    );
    expect(outcome['ok'], isTrue);
    expect(stages(), {'.check-recent'});
  });

  test('an installed receipt that cannot be read refuses the update', () async {
    await install();
    final bytes = release(11, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(11, bytes));
    final receipt = File(
      p.join(manager.layout.release(firstRelease), 'bundle-receipt.json'),
    );
    final original = receipt.readAsStringSync();
    for (final (text, message) in [
      ('not json', "The installed release's receipt cannot be read."),
      ('[]', "The installed release's receipt cannot be read."),
      (
        jsonEncode({...jsonDecode(original) as Map, 'version_code': 'ten'}),
        "The installed release's receipt has an invalid version.",
      ),
    ]) {
      receipt.writeAsStringSync(text);
      await expectLater(
        manager.applyUpdate(archive, manifest, check: true),
        refused(message),
      );
    }
    receipt.deleteSync();
    await expectLater(
      manager.applyUpdate(archive, manifest, check: true),
      refused("The installed release's receipt cannot be read."),
    );
    receipt.writeAsStringSync(original);
    expectUntouched();
  });

  test('a build packaged without a version counts as version 0', () async {
    // Releases made before the receipt carried a version code count as 0.
    await install(stamped: false);
    final bytes = release(1, keyText: keyText);
    final (archive, manifest, _) = download(bytes, await signed(1, bytes));
    expect(
      (await manager.applyUpdate(archive, manifest, check: true))['ok'],
      isTrue,
    );
  });
}
