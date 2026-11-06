import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/app/pairing_inputs.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/first_sync.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';

import 'fakes.dart';
import 'test_platform.dart';
import 'openssl_cli.dart';

const _code = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const _deviceId = '11111111-2222-4333-8444-555555555555';

/// ClientController.pair end to end against a local HTTPS gateway fixture:
/// first pairing, pending then approved, re-pairing with the retained key
/// (the go-live re-pair), key recovery, a refused certificate, and pickup of
/// a reissued leaf over the new identity. OpenSSL plays only the operator.
void main() {
  late Directory fixture;
  late HttpServer server;
  String path(String name) => '${fixture.path}/$name';
  var approve = false;
  var serial = 1;
  String? leaf;
  String? wrongLeaf;
  final enrolled = <String>[];
  final labels = <String?>[];
  final propfinds = <String>[];

  Future<String> sign(String csr, {String subject = _deviceId}) async {
    final name = 'leaf-${serial++}';
    File(path('$name.csr')).writeAsStringSync(csr);
    await openssl([
      'x509',
      '-req',
      '-in',
      path('$name.csr'),
      '-CA',
      path('issuer.crt'),
      '-CAkey',
      path('issuer.key'),
      '-set_serial',
      '$serial',
      '-days',
      '30',
      '-subj',
      '/CN=$subject',
      '-extfile',
      path('leaf.ext'),
      '-extensions',
      'leaf',
      '-out',
      path('$name.crt'),
    ]);
    return File(path('$name.crt')).readAsStringSync();
  }

  Future<String> fingerprint(String csr) async => sha256
      .convert(
        await openssl([
          'pkey',
          '-pubin',
          '-outform',
          'DER',
        ], await openssl(['req', '-pubkey', '-noout'], utf8.encode(csr))),
      )
      .toString();

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-pairing-');
    await openssl([
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-days',
      '60',
      '-subj',
      '/CN=Pairing fixture issuer',
      '-keyout',
      path('issuer.key'),
      '-out',
      path('issuer.crt'),
      '-addext',
      'basicConstraints=critical,CA:TRUE,pathlen:0',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
    ]);
    File(path('server.ext')).writeAsStringSync(
      '[leaf]\nbasicConstraints=critical,CA:FALSE\n'
      'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
      'subjectAltName=IP:127.0.0.1\n',
    );
    await openssl([
      'req',
      '-new',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-noenc',
      '-subj',
      '/CN=127.0.0.1',
      '-keyout',
      path('server.key'),
      '-out',
      path('server.csr'),
    ]);
    await openssl([
      'x509',
      '-req',
      '-in',
      path('server.csr'),
      '-CA',
      path('issuer.crt'),
      '-CAkey',
      path('issuer.key'),
      '-set_serial',
      '900',
      '-days',
      '30',
      '-extfile',
      path('server.ext'),
      '-extensions',
      'leaf',
      '-out',
      path('server.crt'),
    ]);
    File(path('leaf.ext')).writeAsStringSync(
      '[leaf]\nbasicConstraints=critical,CA:FALSE\n'
      'keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n',
    );
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(path('server.crt'))
        ..usePrivateKey(path('server.key'))
        ..setTrustedCertificates(path('issuer.crt')),
      requestClientCertificate: true,
    );
    server.listen((request) async {
      final response = request.response..headers.contentType = ContentType.json;
      if (request.uri.path == '/v1/ca') {
        // Spec #35 rule 2: the household CA, unauthenticated.
        response.headers.contentType = ContentType('application', 'x-pem-file');
        response.write(File(path('issuer.crt')).readAsStringSync());
        await response.close();
        return;
      }
      if (request.uri.path == '/v1/device/certificate') {
        if (request.certificate == null) {
          response.statusCode = 401;
        } else {
          response.write(
            jsonEncode({'device_id': _deviceId, 'certificate': leaf}),
          );
        }
        await response.close();
        return;
      }
      if (request.method == 'PROPFIND') {
        // The first-sync listing (decision #118), over the device's mTLS.
        propfinds.add(await utf8.decoder.bind(request).join());
        if (request.certificate == null ||
            (request.uri.path != '/dav/' &&
                request.uri.path != '/dav/Music' &&
                request.uri.path != '/dav/Music/')) {
          response.statusCode = 401;
          await response.close();
          return;
        }
        String item(String href, {bool folder = false, String? size}) =>
            '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '<d:resourcetype>${folder ? '<d:collection/>' : ''}</d:resourcetype>'
            '<d:getetag>"e"</d:getetag>${folder ? '' : '<d:getcontentlength>7</d:getcontentlength>'}'
            '${size == null ? '' : '<oc:size>$size</oc:size>'}'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
        // Inside a top folder (decision #163): its subfolders and files.
        if (request.uri.path.startsWith('/dav/Music')) {
          response
            ..statusCode = 207
            ..headers.contentType = ContentType('application', 'xml')
            ..write(
              '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
              '${item('/dav/Music/', folder: true)}'
              '${item('/dav/Music/Albums/', folder: true, size: '4096')}'
              '${item('/dav/Music/single.mp3', size: '7')}'
              '</d:multistatus>',
            );
          await response.close();
          return;
        }
        response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write(
            '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
            '${item('/dav/', folder: true, size: '9999')}'
            '${item('/dav/Photos/', folder: true, size: '2048')}'
            '${item('/dav/Music/', folder: true)}'
            '${item('/dav/notes.txt', size: '7')}'
            '${item('/dav/.DS_Store', size: '5')}'
            '</d:multistatus>',
          );
        await response.close();
        return;
      }
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      labels.add(body['label'] as String?);
      final csr = body['csr'] as String;
      if (request.uri.path == '/v1/enroll') enrolled.add(csr);
      final served = await fingerprint(csr);
      // Spec #35: Pair again re-sends the enrollment, which answers approved
      // once the operator has approved the fingerprint.
      if (!approve) {
        response.write(jsonEncode({'state': 'pending', 'fingerprint': served}));
      } else {
        leaf = wrongLeaf ?? await sign(csr);
        response.write(
          jsonEncode({
            'state': 'approved',
            'fingerprint': served,
            'uid': 'fixture-user',
            'rights': 'write',
            'device_id': _deviceId,
            'certificate': leaf,
          }),
        );
      }
      await response.close();
    });
  });
  tearDownAll(() async {
    await server.close(force: true);
    fixture.deleteSync(recursive: true);
  });

  /// A pinned code (spec #35, decision #153) for the fixture's CA, or for
  /// another CA when [otherCa].
  String pinnedCode({bool otherCa = false}) {
    final der = singleCertificateDer(
      File(path('issuer.crt')).readAsBytesSync(),
    )!;
    final pin = caPinOf(der);
    if (otherCa) pin[0] ^= 0x01;
    var number = BigInt.zero;
    for (final byte in [
      for (var i = 0; i < pinnedSecretBytes; i++) 0x40 + i,
      ...pin,
    ]) {
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

  Future<void> pairOnce(ClientController controller) async {
    final origin = 'https://127.0.0.1:${server.port}';
    approve = false;
    await controller.pair(origin, _code, caPath: path('issuer.crt'));
    expect(controller.pairingState, 'pending');
    approve = true;
    await controller.pair(origin, _code, caPath: path('issuer.crt'));
    expect(controller.pairingState, 'paired');
  }

  test(
    'first pairing, retained-key re-pairing, key recovery and pickup',
    () async {
      final profile = Directory(path('profile'));
      final secrets = MemorySecrets();
      final controller = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: testNativeLibrary,
      );
      addTearDown(controller.dispose);

      // 1. First pairing: new in-process key and CSR, then approval.
      await pairOnce(controller);
      var store = Manifest(profile);
      final identity = DeviceIdentity(store, secrets);
      final keyRef = identity.privateKeyRef;
      final key = await secrets.read(keyRef);
      final keyPrint = store.setting('fingerprint')!;
      final csr = store.setting('csr')!;
      expect(keyPrint, await fingerprint(csr));
      expect(store.setting('certificate'), leaf);
      expect(identity.enrolled, isTrue);
      expect(
        DateTime.parse(store.setting('certificateExpires')!).isUtc,
        isTrue,
      );
      store.close();

      // 2. Re-pairing (production go-live): same key, CSR and fingerprint.
      await pairOnce(controller);
      store = Manifest(profile);
      expect(await secrets.read(keyRef), key);
      expect(store.setting('csr'), csr);
      expect(store.setting('fingerprint'), keyPrint);
      expect(store.setting('keyRecovery'), isNull);
      expect(enrolled.toSet(), {csr});

      // 3. The paired identity authenticates and adopts a reissued leaf.
      final working = store.setting('certificate')!;
      leaf = await sign(csr);
      final pickup = await CertificatePickup(store, key!).run();
      expect(pickup.outcome, PickupOutcome.renewed);
      expect(store.setting('certificate'), isNot(working));
      store.close();

      // 4. A certificate for another key is refused and nothing is stored.
      final otherKey = utf8.decode(
        await openssl([
          'genpkey',
          '-algorithm',
          'EC',
          '-pkeyopt',
          'ec_paramgen_curve:P-256',
        ]),
      );
      File(path('other.key')).writeAsStringSync(otherKey);
      final otherCsr = utf8.decode(
        await openssl([
          'req',
          '-new',
          '-key',
          path('other.key'),
          '-subj',
          '/CN=x',
        ]),
      );
      wrongLeaf = await sign(otherCsr);
      store = Manifest(profile);
      final kept = store.setting('certificate');
      store.close();
      await expectLater(pairOnce(controller), throwsA(anything));
      wrongLeaf = null;
      store = Manifest(profile);
      expect(store.setting('certificate'), kept);
      store.close();

      // 5. Key recovery: a lost key yields a new key, CSR and fingerprint.
      await secrets.delete(keyRef);
      await pairOnce(controller);
      store = Manifest(profile);
      expect(store.setting('fingerprint'), isNot(keyPrint));
      expect(store.setting('csr'), isNot(csr));
      expect(
        store.setting('fingerprint'),
        await fingerprint(store.setting('csr')!),
      );
      expect(store.setting('keyRecovery'), isNull);
      expect(DeviceIdentity(store, secrets).enrolled, isTrue);
      store.close();
    },
  );

  test('Android pairing: pinned code, the CA from the server, device label and the first-sync gate', () async {
    final profile = Directory(path('android-profile'));
    final secrets = MemorySecrets();
    final options = PairingOptions(
      liveScan: true,
      firstSync: FirstSyncDefault.cloud,
      deviceLabel: () async => 'Pixel\u0007 of sam${'x' * 90}',
    );
    final controller = ClientController(
      nativeLibrary: testNativeLibrary,
      profile,
      secrets: secrets,
      pairingOptions: options,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    // Android runs the unpaired worker from the first open, so local rows
    // (never synchronized) may exist before the first pairing.
    final seeded = Manifest(profile);
    seeded.entries['local-only'] = Entry('local-only', ItemKind.directory);
    seeded.save();
    seeded.close();
    labels.clear();
    final origin = 'https://127.0.0.1:${server.port}';
    // A code for another household's CA: refused before any enrollment,
    // and no CA is stored (spec #35 rule 2). No CA file, no fingerprint.
    approve = true;
    await expectLater(
      controller.pair(origin, pinnedCode(otherCa: true)),
      throwsA(isA<PairingRefused>()),
    );
    expect(labels, isEmpty);
    expect(controller.pairingMessage, notThisServer);
    var store = Manifest(profile);
    expect(store.setting('ca'), isNull);
    expect(store.setting(firstSyncSetting), isNull);
    store.close();

    // The right code pairs at once: the server approves by itself.
    await controller.pair(origin, pinnedCode());
    expect(controller.pairingState, 'paired');
    expect(controller.awaitingFingerprintApproval, isFalse);
    // Label: the phone's name, control characters removed, 80 characters.
    expect(labels.first, startsWith('Pixel of sam'));
    expect(labels.first!.length, 80);
    store = Manifest(profile);
    final kept = store.setting('ca')!;
    expect(p.dirname(kept), profile.path);
    expect(
      singleCertificateDer(File(kept).readAsBytesSync()),
      singleCertificateDer(File(path('issuer.crt')).readAsBytesSync()),
    );
    expect(store.setting(firstSyncSetting), 'pending');
    expect(controller.firstSyncPending, isTrue);
    store.close();

    // The screen's listing (decision #163): the root and inside Music, each
    // one PROPFIND asking oc:size, over mTLS.
    propfinds.clear();
    final listing = await controller.firstSyncListing();
    expect(propfinds, [firstSyncPropfind, firstSyncPropfind]);
    expect(listing.tops, ['Documents', 'Music', 'Videos']);
    expect(listing.choices.map((c) => (c.path, c.size)), [
      ('Documents', 0),
      ('Music/Albums', 4096),
      ('Music', 7),
      ('Videos', 0),
      ('Photos', 2048),
    ]);
    expect(listing.rootFiles, 1);
    expect(listing.rootFilesSize, 7);
    expect(listing.sizesComplete, isTrue);

    // Closing the app before confirming: the next start keeps the gate
    // and starts no worker, so nothing downloads.
    store = Manifest(profile);
    store.setSetting('root', path('android-root'));
    store.close();
    final reopened = ClientController(
      nativeLibrary: testNativeLibrary,
      profile,
      secrets: secrets,
      pairingOptions: options,
    );
    await reopened.initialize();
    expect(reopened.firstSyncPending, isTrue);
    expect(reopened.message, 'Choose which folders to keep on this device.');
    expect(reopened.canCreateFolder, isFalse);
    reopened.dispose();
    store = Manifest(profile);
    store.deleteSetting('root');
    store.close();
    controller.root = null;

    await controller.confirmFirstSync(listing.paths, {'Music/Albums'});
    expect(controller.firstSyncPending, isFalse);
    store = Manifest(profile);
    expect(store.setting(firstSyncSetting), 'done');
    expect(store.entries['Music/Albums']!.override, Retention.local);
    expect(store.entries['Music']!.override, Retention.cloud);
    expect(store.entries['Photos']!.override, Retention.cloud);
    expect(store.entries['Documents']!.override, Retention.cloud);
    expect(store.entries['Videos']!.override, Retention.cloud);
    store.close();

    // A re-pair of this device never shows the screen again.
    approve = true;
    await controller.pair(origin, pinnedCode());
    expect(controller.pairingState, 'paired');
    expect(controller.firstSyncPending, isFalse);
  });

  test('secure storage that fails at startup: no silent new key; reset pairs again (PR #60 F5)', () async {
    final profile = Directory(path('broken-store-profile'));
    final secrets = FailingStartSecrets();
    final controller = ClientController(
      profile,
      secrets: secrets,
      nativeLibrary: testNativeLibrary,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await pairOnce(controller);
    var store = Manifest(profile);
    final firstPrint = store.setting('fingerprint')!;
    final csr = store.setting('csr')!;
    store.close();

    // The plugin cannot start: every call fails, delete included.
    secrets.broken = true;
    final reopened = ClientController(
      profile,
      secrets: secrets,
      nativeLibrary: testNativeLibrary,
    );
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.keyUnavailable, isTrue);
    expect(reopened.canResetIdentity, isTrue);
    await expectLater(
      secrets.delete('anything'),
      throwsA(isA<PlatformException>()),
    );
    final origin = 'https://127.0.0.1:${server.port}';
    await expectLater(
      reopened.pair(origin, _code, caPath: path('issuer.crt')),
      throwsA(anything),
    );
    expect(reopened.keyUnavailable, isTrue);
    store = Manifest(profile);
    // Never a silently created identity.
    expect(store.setting('fingerprint'), firstPrint);
    expect(store.setting('csr'), csr);
    store.close();

    await reopened.resetDeviceIdentity();
    expect(secrets.resets, 1);
    expect(reopened.keyUnavailable, isFalse);
    expect(reopened.pairingState, 'new device key; obtain a new invitation');
    store = Manifest(profile);
    expect(store.setting('certificate'), isNull);
    expect(store.setting('keyRecovery'), 'new invitation required');
    expect(store.setting('accountUid'), 'fixture-user');
    store.close();

    // Pairs again with a new key; the account binding is unchanged.
    await pairOnce(reopened);
    store = Manifest(profile);
    expect(store.setting('fingerprint'), isNot(firstPrint));
    expect(store.setting('keyRecovery'), isNull);
    expect(store.setting('accountUid'), 'fixture-user');
    store.close();
  });

  test(
    'Linux keyring: no start-up probe; reset refused while the key reads',
    () async {
      final profile = Directory(path('probe-profile'));
      final secrets = _CountingSecrets();
      final controller = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: testNativeLibrary,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      // No Secret Service read (and no unlock prompt) at start (F3).
      expect(secrets.reads, 0);
      final resettable = FailingStartSecrets();
      final android = ClientController(
        nativeLibrary: testNativeLibrary,
        Directory(path('probe-android-profile')),
        secrets: resettable,
      );
      addTearDown(android.dispose);
      await android.initialize();
      expect(android.keyUnavailable, isFalse);
      // A readable key is never reset (F4).
      await expectLater(android.resetDeviceIdentity(), throwsStateError);
      expect(resettable.resets, 0);
    },
  );

  test('a key reset while the folder choice is pending: the next approval shows the screen again', () async {
    final profile = Directory(path('reset-pending-profile'));
    final secrets = FailingStartSecrets();
    const options = PairingOptions(firstSync: FirstSyncDefault.cloud);
    final controller = ClientController(
      nativeLibrary: testNativeLibrary,
      profile,
      secrets: secrets,
      pairingOptions: options,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await pairOnce(controller);
    expect(controller.firstSyncPending, isTrue);

    secrets.broken = true;
    final reopened = ClientController(
      nativeLibrary: testNativeLibrary,
      profile,
      secrets: secrets,
      pairingOptions: options,
    );
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.firstSyncPending, isTrue);
    expect(reopened.keyUnavailable, isTrue);
    await reopened.resetDeviceIdentity();
    // Pairing comes first again; the gate is not left pointing at a
    // listing that can only fail.
    expect(reopened.firstSyncPending, isFalse);
    var store = Manifest(profile);
    expect(store.setting(firstSyncSetting), isNull);
    store.close();

    await pairOnce(reopened);
    expect(reopened.firstSyncPending, isTrue);
    store = Manifest(profile);
    expect(store.setting(firstSyncSetting), 'pending');
    store.close();
  });
}

class _CountingSecrets extends MemorySecrets {
  int reads = 0;
  @override
  Future<String?> read(String key) {
    reads++;
    return super.read(key);
  }
}

/// flutter_secure_storage that fails to start: while [broken], every call
/// throws as the plugin does; [resetAll] is the native wipe around it.
class FailingStartSecrets implements SecretStore, SecretStoreReset {
  final values = <String, String>{};
  bool broken = false;
  int resets = 0;
  Never _fail() => throw PlatformException(code: 'Exception encountered');
  @override
  Future<String?> read(String key) async => broken ? _fail() : values[key];
  @override
  Future<void> write(String key, String value) async =>
      broken ? _fail() : values[key] = value;
  @override
  Future<void> delete(String key) async =>
      broken ? _fail() : values.remove(key);
  @override
  Future<void> resetAll() async {
    values.clear();
    broken = false;
    resets++;
  }
}
