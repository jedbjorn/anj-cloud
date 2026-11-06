import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/qr_decode.dart';
import 'package:anj_cloud/ui/pairing_code_qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pairing code as a QR code (#97 review M3): the Admin dialog and the
/// CLIs show the same 28-character code the app's live scan reads.
void main() {
  const code = '0BCDEFGHJKMNPQRSTVWXYZ012345';

  /// [modules] (dark = true) as a camera's Y plane: [scale] pixels per
  /// module and a 4-module quiet zone.
  LuminanceFrame frame(List<List<bool>> modules, {int scale = 4}) {
    final side = (modules.length + 8) * scale;
    final bytes = Uint8List(side * side)..fillRange(0, side * side, 0xff);
    for (var y = 0; y < modules.length; y++) {
      for (var x = 0; x < modules[y].length; x++) {
        if (!modules[y][x]) continue;
        for (var dy = 0; dy < scale; dy++) {
          final row = ((y + 4) * scale + dy) * side;
          bytes.fillRange(row + (x + 4) * scale, row + (x + 5) * scale, 0);
        }
      }
    }
    return LuminanceFrame(bytes, side, side, side);
  }

  test('the modules decode to exactly the code, without dashes', () {
    expect(decodeQrFrame(frame(pairingCodeModules(code))), code);
    expect(
      decodeQrFrame(
        frame(pairingCodeModules('0BCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345')),
      ),
      code,
    );
  });

  testWidgets('the drawn QR code decodes to exactly the code', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: const PairingCodeQr(code: code, size: 300),
          ),
        ),
      ),
    );
    final decoded = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      final luma = Uint8List(image.width * image.height);
      for (var i = 0; i < luma.length; i++) {
        luma[i] = rgba[i * 4];
      }
      return decodeQrFrame(
        LuminanceFrame(luma, image.width, image.height, image.width),
      );
    });
    expect(decoded, code);
  });

  test(
    "the CLIs' terminal QR (qrencode ANSIUTF8, as guide.qr_text) decodes to "
    'exactly the code',
    () {
      final process = Process.runSync('sh', [
        '-c',
        "printf %s '$code' | qrencode -t ANSIUTF8 -m 2",
      ]);
      expect(process.exitCode, 0);
      // White glyphs on black: a glyph's lit half is a light module.
      final lines = (process.stdout as String)
          .replaceAll(RegExp('\x1b\\[[0-9;]*m'), '')
          .split('\n')
          .where((line) => line.isNotEmpty)
          .toList();
      final modules = <List<bool>>[];
      for (final line in lines) {
        final top = <bool>[];
        final bottom = <bool>[];
        for (final rune in line.runes) {
          final char = String.fromCharCode(rune);
          top.add(!(char == '█' || char == '▀'));
          bottom.add(!(char == '█' || char == '▄'));
        }
        modules
          ..add(top)
          ..add(bottom);
      }
      expect(decodeQrFrame(frame(modules)), code);
    },
    skip: Process.runSync('sh', ['-c', 'command -v qrencode']).exitCode == 0
        ? false
        : 'qrencode not installed',
  );
}
