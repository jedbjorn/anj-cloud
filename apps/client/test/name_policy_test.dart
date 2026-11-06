import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_tables.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_platform.dart';

/// The shared vectors the gateway's portable_names.py also runs
/// (tests/test_portable_names.py), so the two implementations cannot drift.
void main() {
  const vectorsPath = '../../tests/name_policy_vectors.json';
  if (skipSuite('shared name policy vectors', checkoutFile(vectorsPath))) {
    return;
  }
  final vectors =
      jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, dynamic>;

  test('tables and vectors share one Unicode version', () {
    expect(vectors['unicode'], nameTablesUnicodeVersion);
  });

  test('checks match the shared vectors', () {
    for (final vector in (vectors['check'] as List).cast<Map>()) {
      expect(
        NamePolicy.check(vector['name'] as String)?.name,
        vector['reason'],
        reason: jsonEncode(vector['name']),
      );
    }
  });

  test('fold keys match the shared vectors', () {
    final fold = (vectors['fold'] as List).cast<Map>();
    expect(fold.length, greaterThan(1000));
    for (final vector in fold) {
      expect(
        NamePolicy.foldKey(vector['name'] as String),
        vector['key'],
        reason: jsonEncode(vector['name']),
      );
    }
  });

  test('NFC matches the shared vectors (decision #138)', () {
    final nfc = (vectors['nfc'] as List).cast<Map>();
    expect(nfc.length, greaterThan(2000));
    for (final vector in nfc) {
      expect(
        NamePolicy.nfc(vector['name'] as String),
        vector['nfc'],
        reason: jsonEncode(vector['name']),
      );
    }
    expect(
      NamePolicy.nfc('cafe\u0301/Re\u0301sume\u0301'),
      'caf\u00e9/R\u00e9sum\u00e9',
    );
    expect(NamePolicy.sameInCloud('caf\u00e9', 'cafe\u0301'), isTrue);
    expect(NamePolicy.sameInCloud('caf\u00e9', 'Cafe\u0301'), isFalse);
  });

  test('clashes match the shared vectors', () {
    for (final vector in (vectors['clash'] as List).cast<Map>()) {
      expect(
        NamePolicy.clashWith(
          vector['name'] as String,
          (vector['siblings'] as List).cast<String>(),
        ),
        vector['clash'],
        reason: jsonEncode(vector),
      );
    }
  });

  test('gateway reasons map to problems', () {
    for (final problem in NameProblem.values) {
      expect(NameProblem.fromReason(problem.name), problem);
    }
    expect(NameProblem.fromReason('unknown'), isNull);
    expect(NamePolicy.problem('a.txt', ['A.TXT']), NameProblem.clash);
    expect(NamePolicy.problem('CON', ['con']), NameProblem.reserved);
    expect(NamePolicy.problem('.bashrc', ['.profile']), isNull);
  });
}
