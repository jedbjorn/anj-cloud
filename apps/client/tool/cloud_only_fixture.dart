// Per-file Cloud-only end to end (spec #45 F1): a real Linux sync engine
// against a review gateway and Nextcloud. Run by
// deploy/cloud_only_fixture.py, which pairs the device and removes the
// fixture's files from the server afterwards.
//
//   dart run tool/cloud_only_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, certificate, key, work (absent), names: [one, two]}.
// Music is Local; two loose files are synchronized; one is set Cloud-only
// and released (its local bytes gone, the server's version and bytes
// unchanged); the other is untouched; Keep on this device downloads it again
// with the same hash. Prints one JSON line last and exits non-zero on the
// first failed claim.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:crypto/crypto.dart';

import 'eviction_fixture.dart' show ownedAllocated;

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(config['work'] as String);
  if (work.existsSync()) throw StateError('Fixture work path must be absent.');
  work.createSync(recursive: true);
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(config['ca'] as String)
    ..useCertificateChain(config['certificate'] as String)
    ..usePrivateKey(config['key'] as String);
  final cloud = DavCloud(Uri.parse(config['origin'] as String), context);
  final names = (config['names'] as List).cast<String>();
  final one = 'Music/${names[0]}';
  final two = 'Music/${names[1]}';

  final claims = <String, Object?>{};
  late SyncEngine engine;
  void claim(String name, bool passed, [Object? detail]) {
    claims[name] = detail ?? passed;
    if (!passed) {
      stdout.writeln(jsonEncode({'failed': name, 'claims': claims}));
      engine.close();
      exit(1);
    }
  }

  final tree = RootTree.setup(
    (Directory('${work.path}/files')..createSync()).path,
    'cloud-only-e2e',
    NativeRootFs(),
  );
  final store = Manifest(Directory('${work.path}/profile'));
  engine = SyncEngine(store, tree, cloud);
  File local(String path) => File('${tree.root.path}/$path');
  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  Future<String> serverHash(String path) async {
    final copy = File('${work.path}/check-${path.hashCode}');
    try {
      await cloud.download(path, copy, etag: store.entries[path]!.etag!);
      return digest(await copy.readAsBytes());
    } finally {
      if (copy.existsSync()) copy.deleteSync();
    }
  }

  Future<void> passes(bool Function() done, String what) async {
    for (var i = 0; i < 10 && !done(); i++) {
      await engine.tick();
    }
    claim(what, done());
  }

  // Two loose songs in Music, which keeps new and loose files on the device.
  final random = Random.secure();
  for (final path in [one, two]) {
    local(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(
        List.generate(1 << 20, (_) => random.nextInt(256)),
        flush: true,
      );
  }
  await passes(
    () => [one, two].every((path) => store.entries[path]?.etag != null),
    'both songs uploaded',
  );
  claim('Music keeps loose files', engine.retention(two) == Retention.local);
  final hash = digest(local(one).readAsBytesSync());
  final etag = store.entries[one]!.etag;
  final otherHash = digest(local(two).readAsBytesSync());
  final otherStat = local(two).statSync();
  final allocatedBefore = ownedAllocated(tree);

  // One song Cloud-only.
  engine.setRetention(one, Retention.cloud);
  await passes(() => !local(one).existsSync(), 'the song is released');
  final row = await projectEntry(engine, store.entries[one]!);
  claim('its row is Cloud-only', row['effectiveRetention'] == 'cloud', {
    'effectiveRetention': row['effectiveRetention'],
    'status': row['status'],
    'override': row['override'],
  });
  claim('status cloud-only', row['status'] == 'cloud-only');
  final allocatedAfter = ownedAllocated(tree);
  claim('local bytes freed', allocatedBefore - allocatedAfter >= 1 << 20, {
    'before': allocatedBefore,
    'after': allocatedAfter,
  });
  claim(
    'the server keeps the same version and bytes',
    store.entries[one]!.etag == etag && await serverHash(one) == hash,
  );
  final otherNow = local(two).statSync();
  claim(
    'the other song is untouched',
    digest(local(two).readAsBytesSync()) == otherHash &&
        otherNow.modified == otherStat.modified &&
        store.entries[two]!.override == null &&
        engine.retention(two) == Retention.local,
  );

  // Keep on this device brings it back.
  engine.setRetention(one, Retention.local);
  await passes(() => local(one).existsSync(), 'Keep downloads it again');
  claim('identical hash', digest(local(one).readAsBytesSync()) == hash, hash);
  claim('as folder again', store.entries[one]!.override == null);
  engine.close();
  stdout.writeln(jsonEncode({'claims': claims}));
}
