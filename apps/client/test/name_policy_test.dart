import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
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

  // The vectors' check and clash sets were decision #120's rule; spec #49
  // retired it on the client (name_rule_test.dart covers the name rule).
  test('gateway reasons map to cloud-name problems', () {
    for (final problem in CloudNameProblem.values) {
      expect(CloudNameProblem.fromReason(problem.name), problem);
    }
    expect(CloudNameProblem.fromReason('unknown'), isNull);
  });
}
