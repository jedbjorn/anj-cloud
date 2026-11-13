// The name rule end to end on Linux (spec #49 AC2, AC3, AC8): two real
// Linux sync engines, two device certificates of one account, against a
// review gateway. Run by deploy/name_fixture.py, which pairs the devices and
// checks the gateway directly; this side proves the client.
// (Plain Dart: the row's badge and visibility are covered by widget tests.)
//
//   dart run tool/name_policy_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, work, folder, devices: [{certificate, key}] x2}.
// Prints one JSON result line; exits non-zero on the first failed claim.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/cloud_names.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

/// The worker's boundary, counting each PUT by cloud path.
class _Puts extends NamedCloud {
  _Puts(super.inner, super.names);
  final puts = <String, int>{};
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    final cloud = names.cloudPath(path);
    puts[cloud] = (puts[cloud] ?? 0) + 1;
    return super.upload(path, source, etag: etag);
  }
}

class _Device {
  _Device(this.engine, this.cloud, this.raw);
  final SyncEngine engine;
  final _Puts cloud;
  final DavCloud raw;
  String get root => engine.tree.root.path;
  void close() {
    engine.close();
    raw.close();
  }
}

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(config['work'] as String);
  if (work.existsSync()) throw StateError('Fixture work path must be absent.');
  work.createSync(recursive: true);
  final folder = config['folder'] as String;
  final devices = (config['devices'] as List).cast<Map<String, dynamic>>();

  _Device open(String label, Map<String, dynamic> device) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(config['ca'] as String)
      ..useCertificateChain(device['certificate'] as String)
      ..usePrivateKey(device['key'] as String);
    final raw = DavCloud(Uri.parse(config['origin'] as String), context);
    final tree = RootTree.setup(
      (Directory('${work.path}/files-$label')..createSync()).path,
      'names-$label',
      NativeRootFs(),
    );
    final store = Manifest(Directory('${work.path}/profile-$label'))
      ..setSetting('retention', 'local');
    final names = CloudNames();
    final cloud = _Puts(raw, names);
    final engine = SyncEngine(store, tree, cloud, names: names);
    return _Device(engine, cloud, raw);
  }

  final claims = <String, Object?>{};
  void claim(String name, bool passed, [Object? detail]) {
    claims[name] = detail ?? passed;
    if (!passed) {
      stdout.writeln(jsonEncode({'failed': name, 'claims': claims}));
      exit(1);
    }
  }

  final a = open('a', devices[0]);
  final b = open('b', devices[1]);
  File local(_Device device, String name) =>
      File('${device.root}/$folder/$name');
  Future<Map<String, String>> server() async => {
    for (final item in await a.raw.snapshot())
      if (item.path.startsWith('$folder/'))
        item.path.substring(folder.length + 1): item.etag,
  };
  Future<Map<String, dynamic>> row(_Device device, String name) async => Map.of(
    await projectEntry(
      device.engine,
      device.engine.manifest.entries['$folder/$name']!,
    ),
  );
  String? identity(_Device device, String name) => device.engine.tree
      .scanItems(includeExcluded: true)['$folder/$name']
      ?.identity;

  try {
    await a.engine.tick();
    claim('folder synced down', Directory('${a.root}/$folder').existsSync());
    // AC2's folder, as the FnB's `Revit content/Furniture Families ` was:
    // held local-only by an earlier client (AC8 seeds its rows).
    const untrimmed = 'Furniture Families ';
    Directory('${a.root}/$folder/$untrimmed/Chairs')
        .createSync(recursive: true);
    for (final name in ['chair.rfa', 'Chairs/arm.rfa']) {
      local(a, '$untrimmed/$name').writeAsStringSync('local $name');
    }
    // AC3's names, verbatim on Linux; one the rule cannot resolve; a
    // temporary download.
    const verbatim = ['a:b?.txt', 'CON.txt', 'x.', 'Report.pdf', 'report.pdf'];
    for (final name in [...verbatim, '.htaccess', 'movie.mkv.part']) {
      local(a, name).writeAsStringSync('local $name', flush: true);
    }
    final folderIdentity = identity(a, untrimmed);
    final fileIdentity = identity(a, '$untrimmed/chair.rfa');
    const legacy = 'Name not allowed on other devices: rename to sync';
    a.engine.manifest.entries['$folder/$untrimmed'] = Entry(
      '$folder/$untrimmed',
      ItemKind.directory,
    )..status = legacy;
    a.engine.manifest.entries['$folder/$untrimmed/chair.rfa'] = Entry(
      '$folder/$untrimmed/chair.rfa',
      ItemKind.file,
    )..status = 'pending: the folder name is not allowed on other devices';
    a.engine.manifest.save();
    for (var pass = 0; pass < 4; pass++) {
      await a.engine.tick();
    }
    const clean = 'Furniture Families';
    claim(
      'AC2 renamed in place here',
      !Directory('${a.root}/$folder/$untrimmed').existsSync() &&
          identity(a, clean) == folderIdentity &&
          identity(a, '$clean/chair.rfa') == fileIdentity,
      {'folder': identity(a, clean) != null},
    );
    final names = await server();
    claim(
      'AC2 trimmed in the cloud',
      names.containsKey(clean) &&
          names.containsKey('$clean/chair.rfa') &&
          names.containsKey('$clean/Chairs/arm.rfa') &&
          names.keys.every(
            (name) => !name.split('/').any((s) => s != s.trim()),
          ),
      names.keys.toList(),
    );
    claim(
      'AC2 one PUT per file',
      a.cloud.puts['$folder/$clean/chair.rfa'] == 1 &&
          a.cloud.puts['$folder/$clean/Chairs/arm.rfa'] == 1,
      a.cloud.puts,
    );
    claim(
      'AC3 names synced verbatim with no row',
      verbatim.every(names.containsKey) &&
          verbatim.every(
            (name) =>
                a.engine.manifest.entries['$folder/$name']!.status ==
                'current local',
          ),
    );
    final residual = await row(a, '.htaccess');
    claim(
      'one residual row for .htaccess',
      !names.containsKey('.htaccess') &&
          residual['cantSyncName'] == true &&
          residual['status'] ==
              cantSyncNameStatus(CloudNameProblem.forbiddenName),
      residual['status'],
    );
    claim(
      'a .part file is skipped quietly',
      !names.containsKey('movie.mkv.part') &&
          !a.engine.manifest.entries.containsKey('$folder/movie.mkv.part') &&
          local(a, 'movie.mkv.part').existsSync(),
    );
    claim(
      'AC8 no old hold is left',
      a.engine.manifest.entries.values.every(
        (entry) =>
            !isLegacyNameHold(entry.status) &&
            (entry.path == '$folder/.htaccess' ||
                !isCantSyncName(entry.status)),
      ),
    );
    final etags = await server();
    // Profile B, a second device of the account, receives it all.
    await b.engine.tick();
    b.engine.setRetention(folder, Retention.local);
    for (var pass = 0; pass < 3; pass++) {
      await b.engine.tick();
    }
    claim(
      'AC2 profile B receives the trimmed folder',
      local(b, '$clean/chair.rfa').readAsStringSync() == 'local chair.rfa' &&
          local(b, '$clean/Chairs/arm.rfa').readAsStringSync() ==
              'local Chairs/arm.rfa',
    );
    claim(
      'AC3 profile B holds every name verbatim',
      verbatim.every((name) => local(b, name).existsSync()),
    );
    for (var pass = 0; pass < 2; pass++) {
      await a.engine.tick();
    }
    final after = await server();
    claim(
      'AC2 no re-upload afterwards',
      after.length == etags.length &&
          etags.entries.every((e) => after[e.key] == e.value) &&
          b.cloud.puts.isEmpty,
      {'puts_b': b.cloud.puts},
    );
    // Rename of the residual row syncs it.
    final renamed = await a.engine.renameLocal(
      '$folder/.htaccess',
      'htaccess.txt',
    );
    await a.engine.tick();
    await a.engine.tick();
    claim(
      'Rename of the residual row syncs it',
      renamed == '$folder/htaccess.txt' &&
          (await server()).containsKey('htaccess.txt') &&
          !local(a, '.htaccess').existsSync(),
    );
    stdout.writeln(jsonEncode({'passed': true, 'claims': claims}));
  } finally {
    a.close();
    b.close();
  }
}
