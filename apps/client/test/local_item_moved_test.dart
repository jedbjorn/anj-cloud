// LocalItem.movedTo: a listing item moved or renamed in a view keeps every
// field, the folder birth time of flag SC-074 included (PR #98 review: the
// hand-written copies dropped fields added later).
import 'package:anj_cloud/core/state/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a moved listing item keeps every field, its birth time included', () {
    const item = LocalItem(
      'Documents/Taxes',
      ItemKind.directory,
      hash: 'h',
      size: 7,
      identity: 'f1:42',
      links: 3,
      birth: 1793929918657031590,
      scanStamp: 'f1:42:7:1:2',
      stamp: 'f1:42:7:1:2',
      stampedAt: 99,
      stampFinal: true,
    );
    final moved = item.movedTo('Documents/Taxes 2025');
    expect(moved.path, 'Documents/Taxes 2025');
    expect(moved.kind, item.kind);
    expect(moved.hash, item.hash);
    expect(moved.size, item.size);
    expect(moved.identity, item.identity);
    expect(moved.links, item.links);
    expect(moved.birth, item.birth);
    expect(moved.scanStamp, item.scanStamp);
    expect(moved.stamp, item.stamp);
    expect(moved.stampedAt, item.stampedAt);
    expect(moved.stampFinal, item.stampFinal);
  });
}
