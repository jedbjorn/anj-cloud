import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha384.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/ecc/curves/secp384r1.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

import 'der.dart';

/// Device key, CSR and certificate operations (spec #19 formats), in process
/// on every platform: Android and Windows have no OpenSSL CLI and macOS ships
/// LibreSSL (spec #28 U1). Wire and storage formats are the ones the OpenSSL
/// CLI produced, so existing Linux profiles load unchanged:
///
/// * the device key is P-256, stored as a PKCS#8 `PRIVATE KEY` PEM (what
///   `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256` writes);
/// * the CSR is PKCS#10 with subject `CN=<profile id>` (UTF8String), no
///   attributes, signed ecdsa-with-SHA256;
/// * a fingerprint is the SHA-256 of the DER SubjectPublicKeyInfo.
///
/// A platform may later supply its own implementation (for example one backed
/// by a hardware keystore); the shared gateway code only sees this interface.
abstract interface class DeviceCrypto {
  /// A new P-256 device key as PKCS#8 PEM.
  Future<String> generateKey();

  /// DER SubjectPublicKeyInfo of [privateKey]'s public half.
  Future<Uint8List> publicKeyInfo(String privateKey);

  /// A PEM PKCS#10 request for [privateKey] with subject `CN=<commonName>`.
  Future<String> certificationRequest(
    String privateKey, {
    required String commonName,
  });

  /// DER SubjectPublicKeyInfo carried by a PEM CSR (`openssl req -pubkey`;
  /// the request's signature is not checked here).
  Uint8List requestPublicKeyInfo(String request);

  /// The first certificate in [pem].
  DeviceCertificate certificate(String pem);

  /// Every certificate in [pem] (a trust anchor file).
  List<DeviceCertificate> certificates(String pem);

  /// Proves [leaf] is a client certificate issued directly by one of
  /// [anchors] and valid [at] (`openssl verify -purpose sslclient` with only
  /// the pinned issuer). Throws [CertificateRejected] otherwise.
  Future<void> verifyClientCertificate(
    DeviceCertificate leaf,
    List<DeviceCertificate> anchors, {
    required DateTime at,
  });
}

/// Lowercase hex SHA-256 of a DER SubjectPublicKeyInfo: the device
/// fingerprint the gateway, operator and pairing screens compare.
String keyFingerprint(List<int> publicKeyInfo) =>
    sha256.convert(publicKeyInfo).toString();

class CertificateRejected extends FormatException {
  const CertificateRejected(super.message);
}

abstract final class Oid {
  static const ecPublicKey = '1.2.840.10045.2.1';
  static const prime256v1 = '1.2.840.10045.3.1.7';
  static const secp384r1 = '1.3.132.0.34';
  static const ecdsaSha256 = '1.2.840.10045.4.3.2';
  static const ecdsaSha384 = '1.2.840.10045.4.3.3';
  static const ecdsaSha512 = '1.2.840.10045.4.3.4';
  static const commonName = '2.5.4.3';
  static const basicConstraints = '2.5.29.19';
  static const keyUsage = '2.5.29.15';
  static const extendedKeyUsage = '2.5.29.37';
  static const subjectAltName = '2.5.29.17';
  static const nameConstraints = '2.5.29.30';
  static const netscapeCertType = '2.16.840.1.113730.1.1';
  static const clientAuth = '1.3.6.1.5.5.7.3.2';
}

/// The parsed fields of one X.509 certificate the client needs.
class DeviceCertificate {
  DeviceCertificate._({
    required this.der,
    required this.signedPortion,
    required this.signatureAlgorithm,
    required this.signature,
    required this.issuerName,
    required this.subjectName,
    required this.subject,
    required this.notBefore,
    required this.notAfter,
    required this.publicKeyInfo,
    required this.isCa,
    required this.keyUsage,
    required this.extendedKeyUsage,
    required this.netscapeCertType,
    required this.nameConstraints,
    required this.unhandledCritical,
  });

  /// Parses one DER certificate. Malformed input throws [FormatException].
  factory DeviceCertificate.fromDer(Uint8List der) =>
      _strict(() => DeviceCertificate._parse(der));

  factory DeviceCertificate._parse(Uint8List der) {
    final outer = Der.decode(der).items();
    if (outer.length != 3) {
      throw const FormatException('Malformed certificate.');
    }
    final tbs = outer[0].items();
    final algorithm = outer[1].expect(Der.sequence);
    var index = 0;
    var version = 1;
    if (tbs[index].tag == 0xa0) {
      final explicit = tbs[index++].children;
      if (explicit.length != 1) {
        throw const FormatException('Malformed certificate version.');
      }
      version = explicit.single.smallInt + 1;
    }
    tbs[index++].expect(Der.integer); // serial number
    final innerAlgorithm = tbs[index++].expect(Der.sequence);
    if (!_bytesEqual(innerAlgorithm.encoded, algorithm.encoded)) {
      throw const FormatException('Certificate signature algorithm mismatch.');
    }
    final issuer = tbs[index++].expect(Der.sequence);
    final validity = tbs[index++].items();
    if (validity.length != 2) {
      throw const FormatException('Malformed validity.');
    }
    final subject = tbs[index++].expect(Der.sequence);
    final spki = tbs[index++].expect(Der.sequence);
    bool? isCa;
    List<bool>? keyUsage;
    Set<String>? extendedKeyUsage;
    List<bool>? netscapeCertType;
    var nameConstraints = false;
    var unhandledCritical = false;
    while (index < tbs.length) {
      final element = tbs[index++];
      if (element.tag == 0x81 || element.tag == 0x82) continue; // unique IDs
      if (element.tag != 0xa3 || index != tbs.length || version != 3) {
        throw const FormatException('Malformed certificate extensions.');
      }
      final wrapped = element.children;
      if (wrapped.length != 1) {
        throw const FormatException('Malformed certificate extensions.');
      }
      final seen = <String>{};
      for (final extension in wrapped.single.items()) {
        final fields = extension.items();
        if (fields.length < 2 || fields.length > 3) {
          throw const FormatException('Malformed certificate extension.');
        }
        final id = fields[0].objectId;
        final critical = fields.length == 3 && fields[1].boolValue;
        final value = Der.decode(fields.last.expect(Der.octetString).content);
        if (!seen.add(id)) {
          throw const FormatException('Duplicate certificate extension.');
        }
        switch (id) {
          case Oid.basicConstraints:
            final items = value.items();
            isCa = items.isNotEmpty && items.first.tag == Der.boolean
                ? items.first.boolValue
                : false;
          case Oid.keyUsage:
            keyUsage = value.namedBits;
          case Oid.extendedKeyUsage:
            extendedKeyUsage = {
              for (final usage in value.items()) usage.objectId,
            };
          case Oid.subjectAltName:
            value.expect(Der.sequence);
          case Oid.netscapeCertType:
            netscapeCertType = value.namedBits;
          case Oid.nameConstraints:
            // Never evaluated: any certificate carrying it is refused.
            nameConstraints = true;
          default:
            if (critical) unhandledCritical = true;
        }
      }
    }
    final signatureId = algorithm.children;
    return DeviceCertificate._(
      der: der,
      signedPortion: outer[0].encoded,
      signatureAlgorithm: signatureId.first.objectId,
      signature: outer[2].bits,
      issuerName: issuer.encoded,
      subjectName: subject.encoded,
      subject: distinguishedName(subject),
      notBefore: validity[0].time,
      notAfter: validity[1].time,
      publicKeyInfo: spki.encoded,
      isCa: isCa,
      keyUsage: keyUsage,
      extendedKeyUsage: extendedKeyUsage,
      netscapeCertType: netscapeCertType,
      nameConstraints: nameConstraints,
      unhandledCritical: unhandledCritical,
    );
  }

  final Uint8List der;
  final Uint8List signedPortion;
  final String signatureAlgorithm;
  final Uint8List signature;
  final Uint8List issuerName;
  final Uint8List subjectName;

  /// Subject in OpenSSL's `-nameopt RFC2253` form, e.g. `CN=<device id>`.
  final String subject;
  final DateTime notBefore;

  /// Expiry, UTC (what `openssl x509 -enddate -dateopt iso_8601` reports).
  final DateTime notAfter;

  /// DER SubjectPublicKeyInfo exactly as the certificate carries it.
  final Uint8List publicKeyInfo;

  /// basicConstraints cA; null when the extension is absent.
  final bool? isCa;

  /// keyUsage bits (0 = digitalSignature); null when absent.
  final List<bool>? keyUsage;

  /// extendedKeyUsage OIDs; null when absent.
  final Set<String>? extendedKeyUsage;

  /// Netscape certificate type bits (0 = SSL client); null when absent.
  final List<bool>? netscapeCertType;

  /// A nameConstraints extension is present (critical or not).
  final bool nameConstraints;

  /// A critical extension this verifier does not process (OpenSSL rejects).
  final bool unhandledCritical;

  bool get selfIssued => _bytesEqual(issuerName, subjectName);

  bool usage(int bit) {
    final bits = keyUsage;
    return bits == null || (bit < bits.length && bits[bit]);
  }
}

/// Pure-Dart [DeviceCrypto] on the vetted `pointycastle` library (pinned in
/// pubspec): P-256 key generation from an OS-seeded Fortuna generator,
/// deterministic RFC 6979 ECDSA signing and ECDSA verification. Encoding is
/// strict DER (`der.dart`); no primitive is implemented here.
class DartDeviceCrypto implements DeviceCrypto {
  const DartDeviceCrypto();

  static final _p256 = ECCurve_prime256v1();

  @override
  Future<String> generateKey() async {
    final os = Random.secure();
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => os.nextInt(256))),
        ),
      );
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_p256), random));
    final pair = generator.generateKeyPair();
    final d = pair.privateKey.d!;
    final point = pair.publicKey.Q!.getEncoded(false);
    final ecPrivateKey = Der.seq([
      Der.uint(BigInt.one),
      Der.element(Der.octetString, _fixed(d, 32)),
      Der.element(0xa1, Der.bitStringOf(point)),
    ]);
    final pkcs8 = Der.seq([
      Der.uint(BigInt.zero),
      Der.seq([
        Der.objectIdentifier(Oid.ecPublicKey),
        Der.objectIdentifier(Oid.prime256v1),
      ]),
      Der.element(Der.octetString, ecPrivateKey),
    ]);
    final pem = pemEncode('PRIVATE KEY', pkcs8);
    _privateKey(pem); // round-trip before anything stores it
    return pem;
  }

  @override
  Future<Uint8List> publicKeyInfo(String privateKey) async =>
      _spki(_privateKey(privateKey).$2);

  @override
  Future<String> certificationRequest(
    String privateKey, {
    required String commonName,
  }) async {
    final (d, point) = _privateKey(privateKey);
    final info = Der.seq([
      Der.uint(BigInt.zero),
      Der.seq([
        Der.setOf([
          Der.seq([
            Der.objectIdentifier(Oid.commonName),
            Der.element(Der.utf8String, utf8.encode(commonName)),
          ]),
        ]),
      ]),
      _spki(point),
      Der.element(0xa0, const []), // no attributes, as `openssl req -new`
    ]);
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _p256)));
    final signature = signer.generateSignature(info) as ECSignature;
    final request = Der.seq([
      info,
      Der.seq([Der.objectIdentifier(Oid.ecdsaSha256)]),
      Der.bitStringOf(Der.seq([Der.uint(signature.r), Der.uint(signature.s)])),
    ]);
    return pemEncode('CERTIFICATE REQUEST', request);
  }

  @override
  Uint8List requestPublicKeyInfo(String request) =>
      _strict(() => _requestPublicKeyInfo(request));

  Uint8List _requestPublicKeyInfo(String request) {
    final block = pemBlocks(request).where(
      (b) => b.$1 == 'CERTIFICATE REQUEST' || b.$1 == 'NEW CERTIFICATE REQUEST',
    );
    if (block.isEmpty) throw const FormatException('No certificate request.');
    final outer = Der.decode(block.first.$2).items();
    if (outer.length != 3) throw const FormatException('Malformed request.');
    final info = outer[0].items();
    if (info.length != 4 || info[0].smallInt != 0) {
      throw const FormatException('Malformed request.');
    }
    final spki = info[2].expect(Der.sequence);
    _publicKey(spki.encoded); // must be a valid EC key
    return spki.encoded;
  }

  @override
  DeviceCertificate certificate(String pem) {
    final all = certificates(pem);
    if (all.isEmpty) throw const FormatException('No certificate.');
    return all.first;
  }

  @override
  List<DeviceCertificate> certificates(String pem) => [
    for (final (label, der) in pemBlocks(pem))
      if (label == 'CERTIFICATE') DeviceCertificate.fromDer(der),
  ];

  @override
  Future<void> verifyClientCertificate(
    DeviceCertificate leaf,
    List<DeviceCertificate> anchors, {
    required DateTime at,
  }) async {
    final issuer = anchors.where(
      (anchor) =>
          _bytesEqual(anchor.subjectName, leaf.issuerName) &&
          anchor.selfIssued &&
          _signedBy(leaf, anchor),
    );
    if (issuer.isEmpty) {
      throw const CertificateRejected('Not issued by the trusted issuer.');
    }
    final anchor = issuer.first;
    for (final certificate in [leaf, anchor]) {
      // OpenSSL X509_cmp_time: valid from notBefore, expired at notAfter.
      if (at.isBefore(certificate.notBefore) ||
          !at.isBefore(certificate.notAfter)) {
        throw const CertificateRejected('Certificate is outside its validity.');
      }
      if (certificate.unhandledCritical) {
        throw const CertificateRejected('Unhandled critical extension.');
      }
      // Name constraints are never evaluated here, so their presence, critical
      // or not, refuses the chain rather than being silently ignored.
      if (certificate.nameConstraints) {
        throw const CertificateRejected('Name constraints are not supported.');
      }
      // Purpose sslclient applies the EKU rule at every depth (xku_reject).
      final eku = certificate.extendedKeyUsage;
      if (eku != null && !eku.contains(Oid.clientAuth)) {
        throw const CertificateRejected('Not valid for client authentication.');
      }
    }
    // Issuer: a v3 CA allowed to sign certificates (OpenSSL check_ca).
    if (anchor.isCa != true || !anchor.usage(5)) {
      throw const CertificateRejected('Issuer is not a certificate authority.');
    }
    // Leaf, purpose sslclient: digitalSignature or keyAgreement, and a
    // Netscape certificate type, when present, that includes SSL client.
    final nsType = leaf.netscapeCertType;
    if (!(leaf.usage(0) || leaf.usage(4)) ||
        (nsType != null && (nsType.isEmpty || !nsType[0]))) {
      throw const CertificateRejected('Not a client certificate.');
    }
  }

  bool _signedBy(DeviceCertificate subject, DeviceCertificate issuer) {
    final Digest digest;
    switch (subject.signatureAlgorithm) {
      case Oid.ecdsaSha256:
        digest = SHA256Digest();
      case Oid.ecdsaSha384:
        digest = SHA384Digest();
      case Oid.ecdsaSha512:
        digest = SHA512Digest();
      default:
        return false;
    }
    try {
      final (params, point) = _publicKey(issuer.publicKeyInfo);
      final values = Der.decode(subject.signature).items();
      if (values.length != 2) return false;
      final signer = ECDSASigner(digest)
        ..init(
          false,
          PublicKeyParameter<ECPublicKey>(ECPublicKey(point, params)),
        );
      return signer.verifySignature(
        subject.signedPortion,
        ECSignature(values[0].unsigned, values[1].unsigned),
      );
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  /// `(d, Q)` of a PKCS#8 P-256 key. The public point is always derived from
  /// `d`; an embedded public key must agree with it.
  (BigInt, ECPoint) _privateKey(String pem) => _strict(() => _readKey(pem));

  (BigInt, ECPoint) _readKey(String pem) {
    final blocks = pemBlocks(pem).where((b) => b.$1 == 'PRIVATE KEY');
    if (blocks.isEmpty) throw const FormatException('No device key.');
    final info = Der.decode(blocks.first.$2).items();
    if (info.length != 3 || info[0].smallInt != 0) {
      throw const FormatException('Unsupported device key.');
    }
    _expectP256Algorithm(info[1]);
    final key = Der.decode(info[2].expect(Der.octetString).content).items();
    if (key.length < 2 || key[0].smallInt != 1) {
      throw const FormatException('Unsupported device key.');
    }
    final secret = key[1].expect(Der.octetString).content;
    if (secret.length != 32) throw const FormatException('Bad key length.');
    final d = _unsigned(secret);
    if (d == BigInt.zero || d >= _p256.n) {
      throw const FormatException('Device key out of range.');
    }
    final point = (_p256.G * d)!;
    Uint8List? embedded;
    for (final field in key.skip(2)) {
      if (field.tag == 0xa0) {
        if (field.children.single.objectId != Oid.prime256v1) {
          throw const FormatException('Unsupported device key curve.');
        }
      } else if (field.tag == 0xa1 && embedded == null) {
        embedded = field.children.single.bits;
      } else {
        throw const FormatException('Malformed device key.');
      }
    }
    if (embedded != null && !_bytesEqual(embedded, point.getEncoded(false))) {
      throw const FormatException('Device key is inconsistent.');
    }
    return (d, point);
  }

  static void _expectP256Algorithm(Der algorithm) {
    final ids = algorithm.items();
    if (ids.length != 2 ||
        ids[0].objectId != Oid.ecPublicKey ||
        ids[1].objectId != Oid.prime256v1) {
      throw const FormatException('Expected a P-256 key.');
    }
  }

  static Uint8List _spki(ECPoint point) => Der.seq([
    Der.seq([
      Der.objectIdentifier(Oid.ecPublicKey),
      Der.objectIdentifier(Oid.prime256v1),
    ]),
    Der.bitStringOf(point.getEncoded(false)),
  ]);

  /// An EC public key (P-256 or P-384, uncompressed) from a DER SPKI, checked
  /// to lie on its curve.
  static (ECDomainParameters, ECPoint) _publicKey(Uint8List spki) =>
      _strict(() => _readPublicKey(spki));

  static (ECDomainParameters, ECPoint) _readPublicKey(Uint8List spki) {
    final fields = Der.decode(spki).items();
    if (fields.length != 2) throw const FormatException('Malformed key.');
    final ids = fields[0].items();
    if (ids.length != 2 || ids[0].objectId != Oid.ecPublicKey) {
      throw const FormatException('Expected an EC key.');
    }
    final ECDomainParameters params = switch (ids[1].objectId) {
      Oid.prime256v1 => _p256,
      Oid.secp384r1 => ECCurve_secp384r1(),
      _ => throw const FormatException('Unsupported curve.'),
    };
    final encoded = fields[1].bits;
    final size = (params.curve.fieldSize + 7) ~/ 8;
    if (encoded.length != 2 * size + 1 || encoded[0] != 4) {
      throw const FormatException('Expected an uncompressed point.');
    }
    final x = _unsigned(Uint8List.sublistView(encoded, 1, 1 + size));
    final y = _unsigned(Uint8List.sublistView(encoded, 1 + size));
    final q = (params.curve as fp.ECCurve).q!;
    if (x >= q || y >= q) throw const FormatException('Point out of range.');
    final curve = params.curve;
    final fx = curve.fromBigInteger(x);
    final fy = curve.fromBigInteger(y);
    if (fy.square() != fx * fx * fx + curve.a! * fx + curve.b!) {
      throw const FormatException('Point is not on the curve.');
    }
    return (params, curve.createPoint(x, y));
  }
}

/// Runs a parser, reporting structural surprises (a missing element, a
/// short list) as [FormatException] instead of a range or state error.
T _strict<T>(T Function() parse) {
  try {
    return parse();
  } on RangeError {
    throw const FormatException('Malformed DER structure.');
  } on StateError {
    throw const FormatException('Malformed DER structure.');
  } on ArgumentError {
    throw const FormatException('Malformed DER value.');
  }
}

BigInt _unsigned(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _fixed(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  if (rest != BigInt.zero) throw ArgumentError.value(value);
  return out;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// RFC 2253 rendering of a DER Name, matching OpenSSL's `-nameopt RFC2253`
/// for the attribute types and string kinds certificates here use.
String distinguishedName(Der name) {
  const short = {
    '2.5.4.3': 'CN',
    '2.5.4.6': 'C',
    '2.5.4.7': 'L',
    '2.5.4.8': 'ST',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
    '2.5.4.9': 'STREET',
    '0.9.2342.19200300.100.1.25': 'DC',
    '0.9.2342.19200300.100.1.1': 'UID',
  };
  final rdns = <String>[];
  for (final rdn in name.items()) {
    final parts = <String>[];
    for (final attribute in rdn.items(Der.set)) {
      final fields = attribute.items();
      if (fields.length != 2) throw const FormatException('Malformed name.');
      final id = fields[0].objectId;
      parts.add('${short[id] ?? id}=${_attributeValue(fields[1])}');
    }
    if (parts.isEmpty) throw const FormatException('Malformed name.');
    rdns.add(parts.join('+'));
  }
  return rdns.reversed.join(',');
}

String _attributeValue(Der value) {
  final String text;
  switch (value.tag) {
    case Der.utf8String:
      text = utf8.decode(value.content);
    case Der.printableString || Der.ia5String:
      text = ascii.decode(value.content);
    case Der.t61String:
      text = latin1.decode(value.content);
    case Der.bmpString:
      if (value.content.length.isOdd) {
        throw const FormatException('Malformed name.');
      }
      text = String.fromCharCodes([
        for (var i = 0; i < value.content.length; i += 2)
          (value.content[i] << 8) | value.content[i + 1],
      ]);
    default:
      final hex = value.encoded
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      return '#$hex';
  }
  final bytes = utf8.encode(text);
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    final char = String.fromCharCode(byte);
    final edge =
        (i == 0 && (char == ' ' || char == '#')) ||
        (i == bytes.length - 1 && char == ' ');
    if (byte < 0x20 || byte >= 0x7f) {
      out.write('\\${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    } else if (edge || r',+"\<>;'.contains(char)) {
      out.write('\\$char');
    } else {
      out.write(char);
    }
  }
  return out.toString();
}
