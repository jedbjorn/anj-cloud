/// A strict, small ZIP reader for release archives (spec #32 W5): stored and
/// deflated members only, no ZIP64, no encryption, no links, bounded counts
/// and sizes, every member's CRC-32 and size checked. Windows has no
/// built-in reader the manager can trust to refuse unsafe members, so the
/// archive is parsed here and every byte is written by the manager itself.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ZipRefused implements Exception {
  ZipRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

class ZipMember {
  ZipMember(
    this.name,
    this.directory,
    this._method,
    this._compressed,
    this.size,
    this._crc,
    this._offset,
  );
  final String name;
  final bool directory;
  final int _method, _compressed, _crc, _offset;
  final int size;
}

class ZipArchive {
  ZipArchive._(this._file, this.members);

  /// Opens [file] (a private, already verified copy) and reads its central
  /// directory.
  static ZipArchive open(
    File file, {
    int maxMembers = 10000,
    int maxBytes = 2 * 1024 * 1024 * 1024,
  }) {
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      if (length < 22) throw ZipRefused('Not a ZIP archive.');
      final tail = length < 65557 ? length : 65557;
      raf.setPositionSync(length - tail);
      final end = raf.readSync(tail);
      var at = -1;
      for (var i = end.length - 22; i >= 0; i--) {
        if (_u32(end, i) == 0x06054b50) {
          at = i;
          break;
        }
      }
      if (at < 0) throw ZipRefused('Not a ZIP archive (no end record).');
      final disk = _u16(end, at + 4), cdDisk = _u16(end, at + 6);
      final count = _u16(end, at + 10);
      final cdSize = _u32(end, at + 12), cdOffset = _u32(end, at + 16);
      if (disk != 0 ||
          cdDisk != 0 ||
          count == 0xFFFF ||
          cdOffset == 0xFFFFFFFF) {
        throw ZipRefused('Multi-volume and ZIP64 archives are not supported.');
      }
      if (count > maxMembers) throw ZipRefused('Archive has too many members.');
      if (cdOffset + cdSize > length) {
        throw ZipRefused('Corrupt central directory.');
      }
      raf.setPositionSync(cdOffset);
      final cd = raf.readSync(cdSize);
      final members = <ZipMember>[];
      var p = 0, total = 0;
      for (var n = 0; n < count; n++) {
        if (p + 46 > cd.length || _u32(cd, p) != 0x02014b50) {
          throw ZipRefused('Corrupt central directory.');
        }
        final madeBy = _u16(cd, p + 4);
        final flags = _u16(cd, p + 8), method = _u16(cd, p + 10);
        final crc = _u32(cd, p + 16),
            compressed = _u32(cd, p + 20),
            size = _u32(cd, p + 24);
        final nameLength = _u16(cd, p + 28),
            extra = _u16(cd, p + 30),
            comment = _u16(cd, p + 32);
        final external = _u32(cd, p + 38), offset = _u32(cd, p + 42);
        if (p + 46 + nameLength > cd.length) {
          throw ZipRefused('Corrupt central directory.');
        }
        final rawName = cd.sublist(p + 46, p + 46 + nameLength);
        p += 46 + nameLength + extra + comment;
        if (flags & 0x1 != 0) {
          throw ZipRefused('Encrypted members are not supported.');
        }
        if (method != 0 && method != 8) {
          throw ZipRefused('Unsupported compression.');
        }
        if (compressed == 0xFFFFFFFF || size == 0xFFFFFFFF) {
          throw ZipRefused('ZIP64 is not supported.');
        }
        // Unix-made archives carry the file type: refuse links and devices.
        final type = (external >> 16) & 0xF000;
        if (madeBy >> 8 == 3 && type != 0 && type != 0x8000 && type != 0x4000) {
          throw ZipRefused('Links and special files are not supported.');
        }
        final String name;
        try {
          name = (flags & 0x800) != 0 || rawName.every((b) => b < 0x80)
              ? utf8.decode(rawName)
              : throw const FormatException();
        } on FormatException {
          throw ZipRefused('Member names must be UTF-8.');
        }
        total += size;
        if (total > maxBytes) {
          throw ZipRefused('Archive exceeds the unpacked size limit.');
        }
        final directory = name.endsWith('/');
        if (directory && size != 0) {
          throw ZipRefused('Corrupt directory member: $name');
        }
        members.add(
          ZipMember(
            directory ? name.substring(0, name.length - 1) : name,
            directory,
            method,
            compressed,
            size,
            crc,
            offset,
          ),
        );
      }
      return ZipArchive._(file, members);
    } finally {
      raf.closeSync();
    }
  }

  final File _file;
  final List<ZipMember> members;

  /// The member's bytes, with its size and CRC-32 checked.
  Uint8List read(ZipMember member) {
    final raf = _file.openSync();
    try {
      raf.setPositionSync(member._offset);
      final header = raf.readSync(30);
      if (header.length != 30 || _u32(header, 0) != 0x04034b50) {
        throw ZipRefused('Corrupt member header: ${member.name}');
      }
      raf.setPositionSync(
        member._offset + 30 + _u16(header, 26) + _u16(header, 28),
      );
      final data = raf.readSync(member._compressed);
      if (data.length != member._compressed) {
        throw ZipRefused('Truncated member: ${member.name}');
      }
      final bytes = member._method == 0 ? data : _inflate(data, member);
      if (bytes.length != member.size || crc32(bytes) != member._crc) {
        throw ZipRefused('Member does not match its checksum: ${member.name}');
      }
      return bytes;
    } finally {
      raf.closeSync();
    }
  }

  /// Inflates in small steps and stops as soon as the output passes the
  /// member's declared size, so a small member cannot expand without bound.
  static Uint8List _inflate(Uint8List data, ZipMember member) {
    final out = _Bounded(member.size, member.name);
    final sink = ZLibDecoder(raw: true).startChunkedConversion(out);
    for (var at = 0; at < data.length; at += 16 * 1024) {
      sink.add(
        data.sublist(
          at,
          at + 16 * 1024 > data.length ? data.length : at + 16 * 1024,
        ),
      );
    }
    sink.close();
    return out.bytes.takeBytes();
  }

  static int _u16(List<int> b, int i) => b[i] | (b[i + 1] << 8);
  static int _u32(List<int> b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
}

class _Bounded implements Sink<List<int>> {
  _Bounded(this.limit, this.name);
  final int limit;
  final String name;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw ZipRefused('Member expands beyond its declared size: $name');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}

final List<int> _table = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
