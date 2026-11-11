import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Test support: the text of the QR code in an image file's [bytes], for
/// the Windows seat run, which reads one pairing code from a QR image as a
/// person would scan it. The app itself decodes camera frames
/// (lib/core/app/qr_decode.dart) and has no image entry. Every PNG or JPEG
/// format is first converted to 8-bit RGBA: a 1-bit palette PNG (qrencode's
/// default) otherwise yields packed bytes too short for the luminance source.
String decodeQrImage(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null || image.width > 4096 || image.height > 4096) {
    throw const FormatException('Unsupported QR image.');
  }
  final rgba = image.convert(format: img.Format.uint8, numChannels: 4);
  final luminance = RGBLuminanceSource(
    rgba.width,
    rgba.height,
    Uint8List.fromList(rgba.getBytes(order: img.ChannelOrder.abgr)).buffer
        .asInt32List(),
  );
  return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(luminance))).text;
}
