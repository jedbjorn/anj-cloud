// SC-063 / spec #34 P5: after a successful pairing the app asks the gateway
// for the admin role at once, without a restart. On the VM host the gateway logged
// no `/v1/account` request after production pairing: pair() left
// pairingState at the enrollment answer ('approved'), and admin() refuses
// every call unless the state is 'paired', so neither the worker's ready
// event nor the 5-minute timer ever reached the network until a restart.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/pairing_inputs.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/state/manifest.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  if (skipSuite(
    'Admin after pairing over a synthetic TLS gateway',
    opensslSkip,
  )) {
    return;
  }
  late Directory fixture;
  late File ca;
  late File serverKey;
  Future<void> openssl(List<String> args) async {
    final result = await Process.run(testOpenssl!, args);
    if (result.exitCode != 0) {
      throw StateError('Synthetic TLS fixture setup failed.');
    }
  }

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-pair-admin-');
    ca = File('${fixture.path}/server.crt');
    serverKey = File('${fixture.path}/server.key');
    await openssl([
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-keyout',
      serverKey.path,
      '-out',
      ca.path,
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      // macOS's TLS policy requires serverAuth on a server certificate;
      // clientAuth keeps this self-signed anchor valid for client chains.
      '-addext',
      'extendedKeyUsage=serverAuth,clientAuth',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
    ]);
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  Future<String> fingerprintOf(String csrPem) async {
    final work = fixture.createTempSync('fingerprint-');
    final csr = File('${work.path}/device.csr')..writeAsStringSync(csrPem);
    await openssl([
      'req',
      '-in',
      csr.path,
      '-pubkey',
      '-noout',
      '-out',
      '${work.path}/device.pub',
    ]);
    await openssl([
      'pkey',
      '-pubin',
      '-in',
      '${work.path}/device.pub',
      '-outform',
      'DER',
      '-out',
      '${work.path}/device.der',
    ]);
    return sha256
        .convert(File('${work.path}/device.der').readAsBytesSync())
        .toString();
  }

  /// A pinned code (spec #35): 20 secret bytes and the first 16 bytes of
  /// the CA certificate's SHA-256 (DER), in the 32-character alphabet.
  Future<String> pinnedCode({bool otherCa = false}) async {
    final der = File('${fixture.path}/ca.der');
    await openssl([
      'x509',
      '-in',
      ca.path,
      '-outform',
      'DER',
      '-out',
      der.path,
    ]);
    final pin = sha256
        .convert(der.readAsBytesSync())
        .bytes
        .sublist(0, caPinBytes);
    if (otherCa) pin[0] ^= 0x01;
    final bytes = [for (var i = 0; i < pinnedSecretBytes; i++) i, ...pin];
    var number = BigInt.zero;
    for (final byte in bytes) {
      number = (number << 8) | BigInt.from(byte);
    }
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final chars = <String>[];
    for (var i = 0; i < pinnedInvitationLength; i++) {
      chars.insert(0, alphabet[(number & BigInt.from(31)).toInt()]);
      number = number >> 5;
    }
    return chars.join();
  }

  /// A gateway that approves the enrollment at once (signing the device's
  /// CSR with the fixture CA) and answers `/v1/account` as an admin. With
  /// [pinned] it serves `GET /v1/ca` and answers the first `/v1/enroll`
  /// `pending`, approving on `/v1/enroll/status` (spec #35); every request
  /// path is recorded in [paths].
  Future<(HttpServer, List<bool>)> gateway({
    bool pinned = false,
    bool pendingOnly = false,
    List<String>? paths,
  }) async {
    final accountCalls = <bool>[];
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(ca.path)
        ..usePrivateKey(serverKey.path)
        ..setTrustedCertificates(ca.path),
      requestClientCertificate: true,
    );
    var serial = 10;
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      paths?.add(request.uri.path);
      switch (request.uri.path) {
        case '/v1/ca' when pinned:
          await request.drain<void>();
          response.headers.contentType = ContentType(
            'application',
            'x-pem-file',
          );
          response.write(ca.readAsStringSync());
        case final path
            when pinned &&
                (path == '/v1/enroll' ||
                    (pendingOnly && path == '/v1/enroll/status')):
          final body = jsonDecode(await utf8.decodeStream(request)) as Map;
          response.write(
            jsonEncode({
              'state': 'pending',
              'pairing_id': 'synthetic-pairing',
              'device_id': 'synthetic-device',
              'fingerprint': await fingerprintOf(body['csr'] as String),
              'approval': 'automatic',
            }),
          );
        case '/v1/enroll' || '/v1/enroll/status':
          final body = jsonDecode(await utf8.decodeStream(request)) as Map;
          final work = fixture.createTempSync('enroll-');
          final csr = File('${work.path}/device.csr')
            ..writeAsStringSync(body['csr'] as String);
          await openssl([
            'x509',
            '-req',
            '-in',
            csr.path,
            '-CA',
            ca.path,
            '-CAkey',
            serverKey.path,
            '-set_serial',
            '${serial++}',
            '-days',
            '1',
            '-out',
            '${work.path}/device.crt',
          ]);
          await openssl([
            'req',
            '-in',
            csr.path,
            '-pubkey',
            '-noout',
            '-out',
            '${work.path}/device.pub',
          ]);
          await openssl([
            'pkey',
            '-pubin',
            '-in',
            '${work.path}/device.pub',
            '-outform',
            'DER',
            '-out',
            '${work.path}/device.der',
          ]);
          response.write(
            jsonEncode({
              'state': 'approved',
              'pairing_id': 'synthetic-pairing',
              'device_id': 'synthetic-device',
              'uid': 'synthetic-admin',
              'rights': 'write',
              'fingerprint': sha256
                  .convert(File('${work.path}/device.der').readAsBytesSync())
                  .toString(),
              'certificate': File('${work.path}/device.crt').readAsStringSync(),
              if (pinned) 'approval': 'automatic',
            }),
          );
        case '/v1/account':
          await request.drain<void>();
          accountCalls.add(request.certificate != null);
          response.write(jsonEncode({'uid': 'synthetic-admin', 'admin': true}));
        default:
          // File sync and certificate pickup are not under test here.
          await request.drain<void>();
          response.statusCode = 404;
      }
      await response.close();
    });
    return (server, accountCalls);
  }

  test('a successful pairing asks /v1/account at once and shows Admin without '
      'a restart (SC-063)', () async {
    final (server, accountCalls) = await gateway();
    final profile = Directory('${fixture.path}/profile');
    final parent = Directory('${fixture.path}/parent')..createSync();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    try {
      await controller.initialize();
      await controller.configureRoot(parent.path);
      expect(controller.isAdmin, isFalse);
      await controller.pair(
        'https://127.0.0.1:${server.port}',
        '0123456789ABCDEFGHJKMNPQRSTVWXYZ',
        caPath: ca.path,
      );
      // A first pairing on the desktop shows the first-sync screen (decision
      // #163); sync, and the Admin check with it, starts once it is
      // confirmed.
      expect(controller.firstSyncPending, isTrue);
      await controller.confirmFirstSync(const [], const {});
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!controller.isAdmin && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        accountCalls,
        isNotEmpty,
        reason: 'the gateway must see GET /v1/account right after pairing',
      );
      expect(accountCalls.first, isTrue, reason: 'sent with the new leaf');
      expect(controller.isAdmin, isTrue);
      // The device is paired now, in this process: no restart needed.
      expect(controller.pairingState, 'paired');
      expect(
        controller.sharingUnavailable,
        isNot('Pair this device to manage sharing'),
      );
    } finally {
      await controller.stop();
      controller.dispose();
      await server.close(force: true);
    }
  });

  test('a pinned code is decoded exactly as the gateway encodes it', () {
    // tests/pairing_code_vector.json, written by services/access/codes.py.
    final vector = jsonDecode(
      File('../../tests/pairing_code_vector.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      [vector['secret_bytes'], vector['ca_pin_bytes'], vector['length']],
      [pinnedSecretBytes, caPinBytes, pinnedInvitationLength],
      reason: 'dav_api.dart and services/access/codes.py must agree',
    );
    expect(vector['legacy_length'], legacyInvitationLength);
    expect(legacyInvitationLength, 32);
    expect(pinnedInvitationLength, isNot(legacyInvitationLength));
    expect(
      pinnedInvitationLength,
      invitationLength(pinnedSecretBytes + caPinBytes),
    );
    final code = vector['code'] as String;
    List<int> hex(String value) => [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
    final grouped = [
      for (var i = 0; i < code.length; i += 4)
        code.substring(i, (i + 4).clamp(0, code.length)).toLowerCase(),
    ].join('-');
    expect(normalizeInvitation(grouped), code);
    expect(invitationCaPin(code), hex(vector['pin_hex'] as String));
    expect(invitationCaPin('0' * legacyInvitationLength), isNull);
    // Spare top bits must be zero: a first character beyond them is no code.
    final spare =
        5 * pinnedInvitationLength - 8 * (pinnedSecretBytes + caPinBytes);
    if (spare > 0) {
      const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      expect(
        () => invitationCaPin(
          '${alphabet[1 << (5 - spare)]}${code.substring(1)}',
        ),
        throwsFormatException,
      );
    }
    expect(() => normalizeInvitation('${code}0'), throwsFormatException);
  }, skip: checkoutFile('../../tests/pairing_code_vector.json'));

  test('a pinned code fetches and stores the matching CA, then pairs with no '
      'fingerprint step (spec #35)', () async {
    final paths = <String>[];
    final (server, _) = await gateway(pinned: true, paths: paths);
    final profile = Directory('${fixture.path}/pinned-profile');
    final parent = Directory('${fixture.path}/pinned-parent')..createSync();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
      pairingOptions: const PairingOptions(),
    )..pairingPoll = const Duration(milliseconds: 10);
    try {
      await controller.initialize();
      await controller.configureRoot(parent.path);
      final code = await pinnedCode();
      await controller.pair('https://127.0.0.1:${server.port}', code);
      expect(controller.pairingState, 'paired');
      expect(controller.awaitingFingerprintApproval, isFalse);
      expect(paths.take(3), ['/v1/ca', '/v1/enroll', '/v1/enroll/status']);
      final stored = File('${profile.path}/household-ca.crt');
      expect(controller.ca, stored.path);
      final store = Manifest(profile);
      expect(store.setting('ca'), stored.path);
      store.close();
      // Review L2: a paired profile refuses a code pinned to any other CA
      // before fetching anything, and keeps its trust anchor.
      final before = stored.readAsStringSync();
      paths.clear();
      await expectLater(
        controller.pair(
          'https://127.0.0.1:${server.port}',
          await pinnedCode(otherCa: true),
        ),
        throwsA(isA<PairingRefused>()),
      );
      expect(
        paths.where(
          (path) => path == '/v1/ca' || path.startsWith('/v1/enroll'),
        ),
        isEmpty,
        reason: 'nothing fetched, nothing redeemed',
      );
      expect(controller.message, 'This code is not for this server.');
      expect(stored.readAsStringSync(), before);
      expect(controller.pairingState, 'paired');
      // The stored anchor is the CA itself, byte for byte as a certificate.
      String der(String path) => base64.encode(
        Process.runSync(testOpenssl!, [
              'x509',
              '-in',
              path,
              '-outform',
              'DER',
            ], stdoutEncoding: null).stdout
            as List<int>,
      );
      expect(der(stored.path), der(ca.path));
    } finally {
      await controller.stop();
      controller.dispose();
      await server.close(force: true);
    }
  });

  test('a code for another server is refused before any trust is stored '
      '(spec #35 rule 2)', () async {
    final paths = <String>[];
    final (server, _) = await gateway(pinned: true, paths: paths);
    final profile = Directory('${fixture.path}/other-profile');
    final parent = Directory('${fixture.path}/other-parent')..createSync();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
      pairingOptions: const PairingOptions(),
    );
    try {
      await controller.initialize();
      await controller.configureRoot(parent.path);
      await expectLater(
        controller.pair(
          'https://127.0.0.1:${server.port}',
          await pinnedCode(otherCa: true),
        ),
        throwsA(isA<PairingRefused>()),
      );
      expect(controller.message, 'This code is not for this server.');
      expect(paths, ['/v1/ca'], reason: 'no enrollment after a mismatch');
      expect(File('${profile.path}/household-ca.crt').existsSync(), isFalse);
      final store = Manifest(profile);
      expect(store.setting('ca'), isNull);
      expect(store.setting('server'), isNull);
      store.close();
      expect(controller.pairingState, 'unpaired');
    } finally {
      await controller.stop();
      controller.dispose();
      await server.close(force: true);
    }
  });

  test(
    'a pinned code still pending stores no trust anchor (review L2)',
    () async {
      final paths = <String>[];
      final (server, _) = await gateway(
        pinned: true,
        pendingOnly: true,
        paths: paths,
      );
      final profile = Directory('${fixture.path}/pending-profile');
      final parent = Directory('${fixture.path}/pending-parent')..createSync();
      final controller =
          ClientController(
              profile,
              secrets: MemorySecrets(),
              nativeLibrary: testNativeLibrary,
              pairingOptions: const PairingOptions(),
            )
            ..pairingPoll = const Duration(milliseconds: 10)
            ..pairingWait = const Duration(milliseconds: 50);
      try {
        await controller.initialize();
        await controller.configureRoot(parent.path);
        await controller.pair(
          'https://127.0.0.1:${server.port}',
          await pinnedCode(),
        );
        expect(controller.pairingState, 'pending');
        expect(paths, contains('/v1/enroll/status'));
        expect(File('${profile.path}/household-ca.crt').existsSync(), isFalse);
        final store = Manifest(profile);
        expect(store.setting('ca'), isNull);
        expect(store.setting('server'), isNull);
        store.close();
      } finally {
        await controller.stop();
        controller.dispose();
        await server.close(force: true);
      }
    },
  );
}
