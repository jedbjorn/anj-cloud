import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// QR decoding for pairing (spec #28 Pairing step 3, #108 Q12), on the
/// device with the pinned zxing2 decoder and no network: the live camera
/// scan of a QR code carrying the pairing code (spec #35). The image-file
/// path (R4) went with main's spec #35 dialog, which has no QR image entry.

/// One camera frame's luminance: the Y plane of a YUV 4:2:0 image, [width]
/// by [height] pixels in rows of [rowStride] bytes.
class LuminanceFrame {
  const LuminanceFrame(this.bytes, this.width, this.height, this.rowStride);
  final Uint8List bytes;
  final int width;
  final int height;
  final int rowStride;
}

/// The QR text in [frame], or null when no QR code is readable in it.
String? decodeQrFrame(LuminanceFrame frame) {
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      frame.rowStride < frame.width ||
      frame.bytes.length < frame.rowStride * (frame.height - 1) + frame.width) {
    return null;
  }
  return _decode(_YPlane(frame));
}

/// A frame's Y plane as zxing2 luminance (Y is luminance; rows may carry
/// stride padding, which is skipped).
class _YPlane extends LuminanceSource {
  _YPlane(this.frame) : super(frame.width, frame.height);
  final LuminanceFrame frame;

  @override
  Int8List getRow(int y, Int8List? row) {
    if (y < 0 || y >= height) throw ArgumentError('Row outside the frame: $y');
    row = row == null || row.length < width ? Int8List(width) : row;
    final offset = y * frame.rowStride;
    for (var x = 0; x < width; x++) {
      row[x] = frame.bytes[offset + x].toSigned(8);
    }
    return row;
  }

  @override
  Int8List getMatrix() {
    final matrix = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      final offset = y * frame.rowStride;
      for (var x = 0; x < width; x++) {
        matrix[y * width + x] = frame.bytes[offset + x].toSigned(8);
      }
    }
    return matrix;
  }
}

String? _decode(LuminanceSource source) {
  try {
    return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source))).text;
  } on ReaderException {
    return null;
  } on ArgumentError {
    return null;
  }
}
