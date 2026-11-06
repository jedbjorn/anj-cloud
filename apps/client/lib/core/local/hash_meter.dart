import 'dart:io';

import 'package:crypto/crypto.dart';

/// Counts content reads (files and bytes hashed), in total and by purpose.
/// Purposes name the call site, e.g. `scan`, `upload-snapshot`,
/// `replace-check`, `eviction`, `working`, `finish-editing`, `conflict`.
class HashMeter {
  int files = 0;
  int bytes = 0;
  final Map<String, int> filesBy = {};
  final Map<String, int> bytesBy = {};
  void record(String purpose, int length) {
    files++;
    bytes += length;
    filesBy[purpose] = (filesBy[purpose] ?? 0) + 1;
    bytesBy[purpose] = (bytesBy[purpose] ?? 0) + length;
  }

  /// SHA-256 of a whole file, counted under [purpose].
  Future<String> hashFile(File file, String purpose) async {
    var total = 0;
    try {
      return (await sha256
              .bind(
                file.openRead().map((chunk) {
                  total += chunk.length;
                  return chunk;
                }),
              )
              .first)
          .toString();
    } finally {
      record(purpose, total);
    }
  }

  Map<String, Object> toJson() => {
    'files': files,
    'bytes': bytes,
    'filesBy': Map<String, int>.of(filesBy),
    'bytesBy': Map<String, int>.of(bytesBy),
  };
}
