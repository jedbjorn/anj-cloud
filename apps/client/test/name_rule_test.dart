import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_platform.dart';

/// The name rule of spec #49 (D2) against the shared `rule` vectors, which
/// the gateway's name_rule.py also runs (tests/test_name_rule.py).
void main() {
  const vectorsPath = '../../tests/name_policy_vectors.json';
  if (skipSuite('shared name rule vectors', checkoutFile(vectorsPath))) {
    return;
  }
  final rule =
      (jsonDecode(File(vectorsPath).readAsStringSync())
              as Map<String, dynamic>)['rule']
          as Map<String, dynamic>;
  List<Map> list(String key) => (rule[key] as List).cast<Map>();
  List<NameEntry> entries(Map vector) => [
    for (final e in (vector['entries'] as List).cast<List>())
      NameEntry(e[0] as String, fileId: e[1] as int?, folder: e[2] as bool),
  ];
  NameOs os(Map vector) => NameOs.values.byName(vector['os'] as String);
  Map<String, String> local(Map vector) =>
      (vector['local'] as Map).cast<String, String>();

  test('version and constants match the vectors', () {
    expect(rule['version'], NameRule.version);
    expect(rule['maxBytes'], NameRule.maxBytes);
    expect(
      (rule['whitespace'] as List).cast<int>().toSet(),
      NameRule.whitespace,
    );
  });

  test('cleanup', () {
    for (final vector in list('cleanup')) {
      final siblings = (vector['siblings'] as List).cast<String>();
      final folder = vector['folder'] as bool;
      final result = NameRule.cleanup(
        vector['name'] as String,
        siblings: siblings,
        folder: folder,
      );
      expect(result, vector['result'], reason: jsonEncode(vector));
      expect(
        NameRule.cleanup(result, siblings: siblings, folder: folder),
        result,
        reason: 'idempotent: ${jsonEncode(vector)}',
      );
      if (folder) {
        // Decision #195: only a file may stay a .part/.filepart temporary.
        expect(
          NameRule.cloudCheck(result),
          isNot(CloudNameProblem.forbiddenExtension),
          reason: jsonEncode(vector),
        );
      }
    }
  });

  test('cloud check', () {
    for (final vector in list('cloudCheck')) {
      expect(
        NameRule.cloudCheck(vector['name'] as String)?.name,
        vector['reason'],
        reason: jsonEncode(vector['name']),
      );
    }
    expect({for (final v in list('cloudCheck')) v['reason']}..remove(null), {
      for (final problem in CloudNameProblem.values) problem.name,
    });
  });

  test('local names are stable under sibling reordering', () {
    for (final vector in list('localNames')) {
      final items = entries(vector);
      for (var start = 0; start < items.length; start++) {
        final rotated = [...items.skip(start), ...items.take(start)];
        for (final listing in [rotated, rotated.reversed.toList()]) {
          expect(
            NameRule.localNames(listing, os(vector)),
            local(vector),
            reason: jsonEncode(vector['entries']),
          );
        }
      }
      for (final item in items) {
        expect(
          NameRule.localName(item.name, items.reversed, os(vector)),
          local(vector)[item.name],
          reason: jsonEncode(vector['entries']),
        );
      }
    }
  });

  test('local names are one to one and reverse', () {
    for (final vector in list('localNames')) {
      final items = entries(vector);
      final mapped = NameRule.localNames(items, os(vector));
      final folds = os(vector) == NameOs.windows || os(vector) == NameOs.macos;
      expect(
        {for (final n in mapped.values) folds ? NamePolicy.foldKey(n) : n},
        hasLength(items.length),
        reason: jsonEncode(vector['entries']),
      );
      for (final item in items) {
        expect(
          NameRule.cloudName(mapped[item.name]!, items, os(vector)),
          item.name,
        );
        if (os(vector) == NameOs.windows) {
          expect(NamePolicy.check(mapped[item.name]!), isNull);
        }
      }
    }
  });

  test('reverse', () {
    for (final vector in list('reverse')) {
      expect(
        NameRule.cloudName(
          vector['local'] as String,
          entries(vector),
          os(vector),
        ),
        vector['cloud'],
        reason: jsonEncode(vector),
      );
    }
  });

  test('an item missing from the listing is the newest', () {
    expect(
      NameRule.localName('report.pdf', const [
        NameEntry('Report.pdf', fileId: 7),
      ], NameOs.windows),
      'report (2).pdf',
    );
  });
}
