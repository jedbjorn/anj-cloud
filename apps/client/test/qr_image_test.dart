import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'qr_image.dart';

/// A QR image decodes whatever its PNG format (a 1-bit
/// palette PNG, qrencode's default, failed to decode).
void main() {
  test('a 1-bit palette PNG decodes', () {
    expect(
      decodeQrImage(
        File('test/fixtures/qr/palette-1bit.png').readAsBytesSync(),
      ),
      'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
    );
  });

  test('an image that is not a QR code is refused', () {
    expect(() => decodeQrImage(Uint8List(0)), throwsA(isA<Object>()));
  });
}
