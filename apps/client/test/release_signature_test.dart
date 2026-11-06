// Spec #37 U-core: Ed25519 release signatures, the desktop manifest rule and
// the built-in release key, against RFC 8032 and the vector the gateway
// (services/access/release_manifest.py) and the Linux manager
// (tool/linux_install.py) also test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/update/ed25519.dart';
import 'package:anj_cloud/core/update/release.dart';

List<int> hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

void main() {
  final vector = jsonDecode(
    File('tool/testdata/release_signature_vector.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final served = Map<String, Object?>.from(vector['manifest'] as Map);
  final key = ReleaseKey.parse(vector['public_key_file'] as String)!;
  final manifest = ReleaseManifest.fromJson(served, linuxReleaseTarget);

  group('Ed25519', () {
    // RFC 8032 section 7.1, tests 1-3.
    const rfc = [
      (
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        '',
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      ),
      (
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        '72',
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      ),
      (
        'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        'af82',
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
      ),
    ];
    test('RFC 8032 vectors verify; any changed byte does not', () {
      for (final (publicKey, message, signature) in rfc) {
        final k = hex(publicKey), m = hex(message), s = hex(signature);
        expect(ed25519Verify(k, m, s), isTrue);
        expect(ed25519Verify(k, [...m, 1], s), isFalse);
        expect(ed25519Verify(k, m, [...s.sublist(0, 63), s[63] ^ 1]), isFalse);
        expect(ed25519Verify([k[0] ^ 1, ...k.sublist(1)], m, s), isFalse);
        expect(ed25519Verify(k.sublist(1), m, s), isFalse);
        expect(ed25519Verify(k, m, s.sublist(1)), isFalse);
        // A non-canonical S (>= L) is refused.
        expect(
          ed25519Verify(k, m, [...s.sublist(0, 32), ...List.filled(32, 0xff)]),
          isFalse,
        );
      }
    });
  });

  group('desktop manifest', () {
    test('the shared vector: same bytes signed, signature verifies', () {
      expect(utf8.decode(manifest.signedMessage), vector['signed_message']);
      expect(key.id, vector['key_id']);
      expect(key.verify(manifest), isTrue);
      expect(manifest.toJson(), served);
      expect(desktopRefusal(manifest, key, 611, linuxReleaseTarget), isNull);
    });

    test(
      'every tampered field, another key, a downgrade or target is refused',
      () {
        final tampered = <String, Object>{
          'version': '2026.11.05.613',
          'version_code': 613,
          'size': 1,
          'sha256': '6f' * 32,
          'key_id': '0' * 16,
          'signature': '${'A' * 86}==',
        };
        for (final entry in tampered.entries) {
          final changed = ReleaseManifest.fromJson({
            ...served,
            entry.key: entry.value,
          }, linuxReleaseTarget);
          expect(
            desktopRefusal(changed, key, 1, linuxReleaseTarget),
            isNotNull,
            reason: entry.key,
          );
        }
        expect(
          desktopRefusal(manifest, key, 612, linuxReleaseTarget),
          contains('not newer'),
        );
        expect(
          desktopRefusal(manifest, key, 700, linuxReleaseTarget),
          contains('not newer'),
        );
        expect(
          desktopRefusal(manifest, key, 1, macosReleaseTarget),
          contains('another platform'),
        );
        expect(
          desktopRefusal(manifest, null, 1, linuxReleaseTarget),
          contains('no release key'),
        );
        final other = ReleaseKey(hex(rfcKey));
        expect(
          desktopRefusal(manifest, other, 1, linuxReleaseTarget),
          contains('different key'),
        );
      },
    );

    test('the gateway rule: fields, shapes, optional minimum', () {
      for (final bad in <Map<String, Object?>>[
        {...served}..remove('signature'),
        {...served}..remove('key_id'),
        {...served, 'signer_sha256': 'ab' * 32},
        {...served, 'key_id': '0123456789ABCDEF'},
        {...served, 'signature': 'A' * 88},
        {...served, 'min_client_version_code': 613},
        {...served, 'min_client_version_code': '1'},
        {...served, 'target': macosReleaseTarget},
      ]) {
        expect(
          () => ReleaseManifest.fromJson(bad, linuxReleaseTarget),
          throwsFormatException,
          reason: '$bad',
        );
      }
      final floor = ReleaseManifest.fromJson({
        ...served,
        'min_client_version_code': 600,
      }, linuxReleaseTarget);
      expect(floor.minClientVersionCode, 600);
      // Android keeps its signer field and no desktop fields.
      final android = {
        'target': androidReleaseTarget,
        'version': '1.0.2',
        'version_code': 2,
        'size': 10,
        'sha256': 'ab' * 32,
        'signer_sha256': 'cd' * 32,
      };
      expect(
        ReleaseManifest.fromJson(android, androidReleaseTarget).toJson(),
        android,
      );
      expect(
        () => ReleaseManifest.fromJson({
          ...android,
          'key_id': '0' * 16,
        }, androidReleaseTarget),
        throwsFormatException,
      );
    });
  });

  group('built-in key', () {
    test('key files: none, one key, malformed', () {
      expect(ReleaseKey.parse('# no key yet\n'), isNull);
      expect(ReleaseKey.parse(''), isNull);
      for (final text in [
        'ed25519 AAAA\n',
        'ed25519 !!\n',
        'rsa ${'A' * 44}\n',
        // Low-order keys (review L1): 32 zero bytes, the identity point.
        'ed25519 ${base64.encode(List.filled(32, 0))}\n',
        'ed25519 ${base64.encode([1, ...List.filled(31, 0)])}\n',
        '${vector['public_key_file']}${vector['public_key_file']}',
      ]) {
        expect(() => ReleaseKey.parse(text), throwsFormatException);
      }
    });

    test('the committed asset parses (a key, or none before keygen)', () {
      final text = File(ReleaseKey.asset).readAsStringSync();
      expect(() => ReleaseKey.parse(text), returnsNormally);
    });
  });
}

const rfcKey =
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
