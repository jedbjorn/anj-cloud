/// Ed25519 signature verification (RFC 8032 section 5.1.7) for release
/// manifests (spec #37 U-core). Pure Dart over [BigInt], shared by every
/// desktop platform; it handles public data only (a public key, a manifest
/// and its signature), so constant time does not matter here.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _p = (BigInt.one << 255) - BigInt.from(19);
final _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final _d = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);
final _two = BigInt.two;

typedef _Point = (BigInt, BigInt, BigInt, BigInt);

final _identity = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

_Point _add(_Point a, _Point b) {
  final (x1, y1, z1, t1) = a;
  final (x2, y2, z2, t2) = b;
  final first = ((y1 - x1) * (y2 - x2)) % _p;
  final second = ((y1 + x1) * (y2 + x2)) % _p;
  final third = (_two * t1 * t2 * _d) % _p;
  final fourth = (_two * z1 * z2) % _p;
  final e = second - first, f = fourth - third;
  final g = fourth + third, h = second + first;
  return ((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _multiply(BigInt scalar, _Point point) {
  var result = _identity;
  var addend = point;
  var rest = scalar;
  while (rest > BigInt.zero) {
    if (rest.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    rest >>= 1;
  }
  return result;
}

BigInt _littleEndian(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

_Point? _decode(List<int> bytes) {
  var y = _littleEndian(bytes);
  final sign = (y >> 255).toInt();
  y &= (BigInt.one << 255) - BigInt.one;
  if (y >= _p) return null;
  final x2 =
      ((y * y - BigInt.one) * (_d * y * y + BigInt.one).modInverse(_p)) % _p;
  if (x2 == BigInt.zero) {
    return sign == 1 ? null : (BigInt.zero, y, BigInt.one, BigInt.zero);
  }
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return (x, y, BigInt.one, (x * y) % _p);
}

final _base = _decode(
  _encodeY((BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p),
)!;

Uint8List _encodeY(BigInt y) {
  final bytes = Uint8List(32);
  var rest = y;
  for (var i = 0; i < 32; i++) {
    bytes[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return bytes;
}

/// Whether [signature] (64 bytes) is a valid Ed25519 signature of [message]
/// by the 32-byte [publicKey]. Malformed input is simply not valid.
bool ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  if (!ed25519ValidPublicKey(publicKey)) return false;
  final key = _decode(publicKey);
  final commitment = _decode(signature.sublist(0, 32));
  if (key == null || commitment == null) return false;
  final scalar = _littleEndian(signature.sublist(32));
  if (scalar >= _l) return false;
  final challenge =
      _littleEndian(
        sha512.convert([
          ...signature.sublist(0, 32),
          ...publicKey,
          ...message,
        ]).bytes,
      ) %
      _l;
  final left = _multiply(scalar, _base);
  final right = _add(commitment, _multiply(challenge, key));
  return (left.$1 * right.$3 - right.$1 * left.$3) % _p == BigInt.zero &&
      (left.$2 * right.$3 - right.$2 * left.$3) % _p == BigInt.zero;
}

/// [8]P is the identity: P is one of the 8 low-order points.
bool _smallOrder(_Point point) {
  final (x, y, z, _) = _multiply(BigInt.from(8), point);
  return x % _p == BigInt.zero && (y - z) % _p == BigInt.zero;
}

/// Whether [bytes] encode a curve point outside the small-order subgroup:
/// a usable public key. A low-order key (the identity, or 32 zero bytes, an
/// order-4 point) would make forged signatures verify.
bool ed25519ValidPublicKey(List<int> bytes) {
  if (bytes.length != 32) return false;
  final point = _decode(bytes);
  return point != null && !_smallOrder(point);
}
