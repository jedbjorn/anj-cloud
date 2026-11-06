import 'dart:convert';
import 'dart:typed_data';

/// Strict DER reading and writing for the device credential formats (PKCS#8,
/// PKCS#10, X.509). This is encoding only, never cryptography: signatures and
/// key arithmetic live in `device_crypto.dart` and come from a vetted library.
///
/// The reader rejects BER leniency on purpose: indefinite lengths, non-minimal
/// lengths, high tag numbers and trailing bytes all fail, so a certificate the
/// gateway or a peer sends can only parse one way.
class Der {
  Der._(this.tag, this.content, this.encoded);

  final int tag;
  final Uint8List content;

  /// The whole element (tag, length and content), for signed portions.
  final Uint8List encoded;

  static const integer = 0x02;
  static const bitString = 0x03;
  static const octetString = 0x04;
  static const nullTag = 0x05;
  static const oid = 0x06;
  static const utf8String = 0x0c;
  static const printableString = 0x13;
  static const t61String = 0x14;
  static const ia5String = 0x16;
  static const utcTime = 0x17;
  static const generalizedTime = 0x18;
  static const bmpString = 0x1e;
  static const boolean = 0x01;
  static const sequence = 0x30;
  static const set = 0x31;

  /// Decodes exactly one element spanning all of [bytes].
  static Der decode(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final (element, end) = _read(data, 0);
    if (end != data.length) throw const FormatException('Trailing DER data.');
    return element;
  }

  static List<Der> decodeAll(Uint8List data) {
    final items = <Der>[];
    var offset = 0;
    while (offset < data.length) {
      final (element, end) = _read(data, offset);
      items.add(element);
      offset = end;
    }
    return items;
  }

  static (Der, int) _read(Uint8List data, int offset) {
    if (offset + 2 > data.length) throw const FormatException('Short DER.');
    final tag = data[offset];
    if (tag & 0x1f == 0x1f) throw const FormatException('Unsupported tag.');
    var length = data[offset + 1];
    var cursor = offset + 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 3 || cursor + count > data.length) {
        throw const FormatException('Unsupported DER length.');
      }
      if (data[cursor] == 0) throw const FormatException('Non-minimal length.');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | data[cursor + i];
      }
      cursor += count;
      if (length < 0x80) throw const FormatException('Non-minimal length.');
    }
    final end = cursor + length;
    if (end > data.length) throw const FormatException('Truncated DER.');
    return (
      Der._(
        tag,
        Uint8List.sublistView(data, cursor, end),
        Uint8List.sublistView(data, offset, end),
      ),
      end,
    );
  }

  bool get constructed => tag & 0x20 != 0;

  /// The elements of a constructed value (SEQUENCE, SET, explicit tag).
  List<Der> get children {
    if (!constructed) throw const FormatException('Not a constructed value.');
    return decodeAll(content);
  }

  Der expect(int expected) {
    if (tag != expected) throw const FormatException('Unexpected DER tag.');
    return this;
  }

  /// Children of a SEQUENCE (or SET) with tag [expected].
  List<Der> items([int expected = sequence]) => expect(expected).children;

  /// Non-negative INTEGER value.
  BigInt get unsigned {
    expect(integer);
    if (content.isEmpty || content[0] & 0x80 != 0) {
      throw const FormatException('Expected a non-negative integer.');
    }
    if (content.length > 1 && content[0] == 0 && content[1] & 0x80 == 0) {
      throw const FormatException('Non-minimal integer.');
    }
    var value = BigInt.zero;
    for (final byte in content) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  int get smallInt {
    final value = unsigned;
    if (value.bitLength > 31) throw const FormatException('Integer too large.');
    return value.toInt();
  }

  String get objectId {
    expect(oid);
    if (content.isEmpty || content.last & 0x80 != 0) {
      throw const FormatException('Malformed object identifier.');
    }
    final arcs = <int>[];
    var value = 0;
    var start = true;
    for (final byte in content) {
      if (start && byte == 0x80) {
        throw const FormatException('Non-minimal object identifier.');
      }
      if (value > 0x00ffffff) throw const FormatException('OID arc too large.');
      value = (value << 7) | (byte & 0x7f);
      start = byte & 0x80 == 0;
      if (start) {
        arcs.add(value);
        value = 0;
      }
    }
    final first = arcs.first < 80 ? arcs.first ~/ 40 : 2;
    return [first, arcs.first - first * 40, ...arcs.skip(1)].join('.');
  }

  /// BIT STRING bytes; only whole-byte strings are accepted.
  Uint8List get bits {
    expect(bitString);
    if (content.isEmpty || content[0] != 0) {
      throw const FormatException('Expected a whole-byte bit string.');
    }
    return Uint8List.sublistView(content, 1);
  }

  /// A named-bit BIT STRING (key usage) as booleans, bit 0 first.
  List<bool> get namedBits {
    expect(bitString);
    if (content.isEmpty || content[0] > 7) {
      throw const FormatException('Malformed bit string.');
    }
    final unused = content[0];
    final result = <bool>[];
    for (var i = 1; i < content.length; i++) {
      final count = i == content.length - 1 ? 8 - unused : 8;
      for (var bit = 0; bit < count; bit++) {
        result.add(content[i] & (0x80 >> bit) != 0);
      }
    }
    return result;
  }

  bool get boolValue {
    expect(boolean);
    if (content.length != 1 || (content[0] != 0 && content[0] != 0xff)) {
      throw const FormatException('Malformed boolean.');
    }
    return content[0] == 0xff;
  }

  /// UTCTime or GeneralizedTime in the DER form (`Z`, whole seconds).
  DateTime get time {
    final text = ascii.decode(content);
    final String full;
    if (tag == utcTime && RegExp(r'^\d{12}Z$').hasMatch(text)) {
      final year = int.parse(text.substring(0, 2));
      full = '${year < 50 ? 20 : 19}$text';
    } else if (tag == generalizedTime && RegExp(r'^\d{14}Z$').hasMatch(text)) {
      full = text;
    } else {
      throw const FormatException('Malformed certificate time.');
    }
    int at(int start, int length) =>
        int.parse(full.substring(start, start + length));
    final value = DateTime.utc(
      at(0, 4),
      at(4, 2),
      at(6, 2),
      at(8, 2),
      at(10, 2),
      at(12, 2),
    );
    // DateTime.utc normalizes overflow (month 13, second 61); DER may not.
    if (value.month != at(4, 2) ||
        value.day != at(6, 2) ||
        value.hour != at(8, 2) ||
        value.minute != at(10, 2) ||
        value.second != at(12, 2)) {
      throw const FormatException('Malformed certificate time.');
    }
    return value;
  }

  // --- Writing -------------------------------------------------------------

  static Uint8List element(int tag, List<int> content) {
    final length = content.length;
    final List<int> header;
    if (length < 0x80) {
      header = [tag, length];
    } else {
      final octets = <int>[];
      for (var rest = length; rest > 0; rest >>= 8) {
        octets.insert(0, rest & 0xff);
      }
      header = [tag, 0x80 | octets.length, ...octets];
    }
    return Uint8List.fromList([...header, ...content]);
  }

  static Uint8List seq(List<List<int>> items) =>
      element(sequence, [for (final item in items) ...item]);

  static Uint8List setOf(List<List<int>> items) =>
      element(set, [for (final item in items) ...item]);

  static Uint8List uint(BigInt value) {
    if (value.isNegative) throw ArgumentError.value(value);
    final bytes = <int>[];
    for (var rest = value; rest > BigInt.zero; rest >>= 8) {
      bytes.insert(0, (rest & BigInt.from(0xff)).toInt());
    }
    if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return element(integer, bytes);
  }

  static Uint8List objectIdentifier(String dotted) {
    final arcs = dotted.split('.').map(int.parse).toList();
    final values = [arcs[0] * 40 + arcs[1], ...arcs.skip(2)];
    final bytes = <int>[];
    for (final value in values) {
      final chunk = <int>[value & 0x7f];
      for (var rest = value >> 7; rest > 0; rest >>= 7) {
        chunk.insert(0, 0x80 | (rest & 0x7f));
      }
      bytes.addAll(chunk);
    }
    return element(oid, bytes);
  }

  static Uint8List bitStringOf(List<int> bytes) =>
      element(bitString, [0, ...bytes]);
}

/// The `-----BEGIN <label>-----` blocks of [text], decoded, in order. Text
/// outside the blocks is ignored, as OpenSSL's PEM reader does.
List<(String, Uint8List)> pemBlocks(String text) {
  final pattern = RegExp(
    r'-----BEGIN ([A-Z0-9 ]+)-----\r?\n([A-Za-z0-9+/=\r\n]*?)-----END \1-----',
  );
  return [
    for (final match in pattern.allMatches(text))
      (
        match.group(1)!,
        base64.decode(match.group(2)!.replaceAll(RegExp(r'\s'), '')),
      ),
  ];
}

/// PEM text in OpenSSL's layout: 64-column base64 and a trailing newline.
String pemEncode(String label, List<int> der) {
  final body = base64.encode(der);
  final lines = [
    for (var i = 0; i < body.length; i += 64)
      body.substring(i, i + 64 > body.length ? body.length : i + 64),
  ];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}
