import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

/// The QR modules of a pairing [code] (28 characters, spec #35): exactly the
/// code text a person would type, without dashes, so the app's live scan
/// (#108 Q12) reads the same code. Medium error correction.
List<List<bool>> pairingCodeModules(String code) {
  final matrix = Encoder.encode(
    code.replaceAll('-', '').toUpperCase(),
    ErrorCorrectionLevel.m,
  ).matrix!;
  return [
    for (var y = 0; y < matrix.height; y++)
      [for (var x = 0; x < matrix.width; x++) matrix.get(x, y) == 1],
  ];
}

/// A pairing code as a QR code (black on white, a 4-module quiet zone), for
/// the Admin "Invite a device" dialog. Drawn on the device; nothing leaves it.
class PairingCodeQr extends StatelessWidget {
  const PairingCodeQr({super.key, required this.code, this.size = 200});
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'QR code of the pairing code',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _QrPainter(pairingCodeModules(code))),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.modules);
  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 4;
    final count = modules.length + 2 * quiet;
    final cell = size.shortestSide / count;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final dark = Paint()..color = Colors.black;
    for (var y = 0; y < modules.length; y++) {
      for (var x = 0; x < modules[y].length; x++) {
        if (!modules[y][x]) continue;
        canvas.drawRect(
          Rect.fromLTWH((x + quiet) * cell, (y + quiet) * cell, cell, cell),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.modules != modules;
}
