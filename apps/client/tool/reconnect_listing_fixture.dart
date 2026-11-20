import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/dav_listing_cache.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:crypto/crypto.dart';

/// The controller starts a new Dart process for each check and kills it
/// after this receipt. No graceful client shutdown can publish a cache.
Future<void> main(List<String> args) async {
  final config = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final phase = args[1];
  final profile = Manifest(Directory(config['profile'] as String));
  final origin = Uri.parse(config['origin'] as String);
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(config['ca'] as String)
    ..useCertificateChain(config['certificate'] as String)
    ..usePrivateKey(config['key'] as String);
  final cloud = DavCloud(
    origin,
    context,
    listingCache: phase == 'fresh' ? null : DavListingCache(profile),
  );
  try {
    if (phase == 'prime') {
      profile.transaction(() {
        profile.setSetting('server', origin.origin);
        profile.setSetting('accountUid', config['account'] as String);
        profile.setSetting('deviceId', config['device'] as String);
      });
    }
    if (phase == 'interrupt') {
      profile.db.execute('BEGIN IMMEDIATE');
      profile.setSetting('davListingTreeV1', '{"":[]}');
      stdout.writeln(jsonEncode({'pid': pid, 'uncommitted': true}));
    } else {
      final watch = Stopwatch()..start();
      if (phase != 'fresh') await cloud.incomingShares();
      final items = await cloud.snapshot()
        ..sort((a, b) => a.path.compareTo(b.path));
      final deep = config['deep'] as String;
      stdout.writeln(
        jsonEncode({
          'pid': pid,
          'rows': items.length,
          'sha256': sha256
              .convert(
                utf8.encode(
                  jsonEncode(items.map(DavListingCache.fields).toList()),
                ),
              )
              .toString(),
          'elapsed_ms': watch.elapsedMilliseconds,
          'full_walks': cloud.fullWalks,
          'folders_reused': cloud.foldersReused,
          'deep_shared': items.singleWhere((item) => item.path == deep).shared,
          'deep': {
            for (final item in items)
              if (item.path.startsWith('$deep/')) item.path: item.etag,
          },
        }),
      );
    }
    await stdout.flush();
    await stdin.drain<void>(); // The controller uses SIGKILL here.
  } finally {
    cloud.close();
    profile.close();
  }
}
