import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/fetch_jobs.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/ui/downloader_tab.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Spec #42 "Tab behaviour" against a throwaway review stack that runs the
/// fetch worker and its fixture site: the real client, worker, mTLS gateway
/// and fetch worker. Opt-in: `ANJ_LIVE_FETCH_CONFIG` names a private JSON
/// file with `runtime` (the checkout that owns the stack's state), `project`
/// (`anj-cloud-review-<tag>`), `port`, `uid` (a fixture account), `evidence`
/// (a directory for the screenshots and the progress record), `fixture` (an
/// absent path for the profile and the synced folder), `site` (the fixture
/// site as the worker reaches it) and optionally `extra` (one more video
/// link, e.g. a small public one; its outcome is recorded, never required).
///
/// It pairs one device, submits links through the tab, waits for the rows to
/// finish and for the files to arrive in the synced folder, then removes its
/// rows and files and revokes its device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Downloader on a live review stack', (tester) async {
    final configFile = File(Platform.environment['ANJ_LIVE_FETCH_CONFIG']!);
    if ((configFile.statSync().mode & 0077) != 0) {
      throw StateError('Live fixture configuration must be private.');
    }
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final runtime = config['runtime'] as String;
    final project = config['project'] as String;
    final port = config['port'] as int;
    final uid = config['uid'] as String;
    final site = config['site'] as String;
    final extra = config['extra'] as String?;
    final evidence = Directory(config['evidence'] as String)
      ..createSync(recursive: true);
    if (!RegExp(r'^anj-cloud-review-[a-z0-9-]+$').hasMatch(project)) {
      throw StateError('Use a throwaway review project, never the dev stack.');
    }
    final origin = Uri.parse('https://127.0.0.1:$port');
    final ca = File('$runtime/deploy/.local/$project/operator/issuer.crt');
    final fixture = Directory(config['fixture'] as String);
    if (fixture.existsSync()) throw StateError('Fixture path must be absent.');
    fixture.createSync(recursive: true);
    final events = <Map<String, Object?>>[];
    void record(String claim, [Map<String, Object?> facts = const {}]) {
      events.add({'claim': claim, ...facts});
      File('${evidence.path}/progress.json')
          .writeAsStringSync(jsonEncode(events), flush: true);
      stdout.writeln('Downloader GUI: $claim ${jsonEncode(facts)}');
    }

    Future<Object?> operator(List<String> arguments) async {
      final result = await Process.run(
        '$runtime/deploy/.local/access-venv/bin/python',
        [
          '-m',
          'deploy.access_operator',
          '--project',
          project,
          '--port',
          '$port',
          ...arguments,
        ],
        workingDirectory: runtime,
        environment: {'ANJ_PROFILE': 'deploy/profile.example.toml'},
      );
      if (result.exitCode != 0) {
        throw StateError(
          'operator ${arguments.first} failed (exit ${result.exitCode})',
        );
      }
      return jsonDecode(result.stdout as String);
    }

    Future<void> wait(
      bool Function() condition,
      String what, {
      int seconds = 60,
      void Function()? each,
    }) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        each?.call();
        if (condition()) return;
      }
      throw StateError('Timed out waiting for $what');
    }

    Future<void> until(Finder finder, {int seconds = 60}) =>
        wait(() => finder.evaluate().isNotEmpty, '$finder', seconds: seconds);

    final boundary = GlobalKey();
    Future<void> screenshot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundary),
      );
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${evidence.path}/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
      });
    }

    final secrets = _MemorySecrets();
    final profile = Directory('${fixture.path}/profile');
    var controller = ClientController(profile, secrets: secrets);
    String? fingerprint;
    final placed = <String>{};
    Set<String>? before;
    try {
      // Pair one device for the fixture account, as the Admin fixture does.
      await tester.runAsync(() async {
        await controller.initialize();
        final parent = Directory('${fixture.path}/files')..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        final invitation =
            await operator(['invite', uid, '--rights', 'write']) as Map;
        controller.pairingWait = Duration.zero;
        await controller.pair(
          origin.toString(),
          invitation['code'] as String,
          caPath: ca.path,
        );
        await controller.stop();
        fingerprint = controller.fingerprint;
        if (controller.pairingState != 'paired') {
          await operator([
            'approve',
            invitation['id'] as String,
            '--fingerprint',
            controller.fingerprint!,
          ]);
          await controller.pair(
            origin.toString(),
            invitation['code'] as String,
            caPath: ca.path,
          );
        }
        expect(controller.pairingState, 'paired');
        if (controller.firstSyncPending) {
          final choice = await controller.firstSyncListing();
          await controller.confirmFirstSync(choice.paths, choice.paths.toSet());
        }
        await controller.stop();
        controller.dispose();
      });
      record('paired', {'uid': uid});

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      controller = ClientController(profile, secrets: secrets);
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.start();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: CloudApp(controller: controller),
        ),
      );
      final jobs = controller.fetchJobs;

      // 1. The tab appears from the real gateway's answer.
      final tab = find.widgetWithText(Tab, 'Downloader');
      await until(tab);
      expect(jobs.availability, FetchAvailability.available);
      record('tab shown after the gateway answered the job list');
      await screenshot('01-home-with-downloader-tab');

      await tester.tap(tab);
      await until(find.byType(DownloaderTab));
      expect(jobs.tabVisible, isTrue);
      if (config['clean_first'] == true) {
        // Rows an interrupted earlier run left in this fixture account.
        final left = jobs.jobs.length;
        for (final job in jobs.jobs) {
          await tester.runAsync(
            () => job.isFinished ? jobs.remove(job.id) : jobs.cancel(job.id),
          );
        }
        await tester.runAsync(jobs.refresh);
        for (final job in jobs.jobs) {
          await tester.runAsync(() => jobs.remove(job.id));
        }
        await tester.runAsync(jobs.refresh);
        await tester.pump(const Duration(milliseconds: 500));
        record('rows of an earlier run removed', {
          'found': left,
          'left': jobs.jobs.length,
        });
      }
      before = {for (final job in jobs.jobs) job.id};
      record('tab opened', {'rows_already_in_the_account': before.length});
      await screenshot('02-tab-before-submit');

      List<FetchJob> mine() => [
        for (final job in jobs.jobs)
          if (!before!.contains(job.id)) job,
      ];
      FetchJob? row(String url) =>
          mine().where((job) => job.url == url).firstOrNull;
      final seen = <String, List<String>>{};
      void watch() {
        for (final job in mine()) {
          final states = seen.putIfAbsent(job.url ?? job.id, () => []);
          final label = fetchStateLabel(job);
          if (states.isEmpty || states.last != label) states.add(label);
        }
      }

      Future<void> submit(String text) async {
        // As a person would: click into the field, then type. (The tester
        // types only into the field it last focused itself, so it is told
        // to focus again after the chips or a button took the focus.)
        await tester.tap(find.byKey(const ValueKey('downloader-links')));
        await tester.pump(const Duration(milliseconds: 300));
        tester.binding.focusedEditable = null;
        await tester.enterText(
          find.byKey(const ValueKey('downloader-links')),
          text,
        );
        await tester.pump(const Duration(milliseconds: 300));
        final typed = tester
            .widget<TextField>(find.byKey(const ValueKey('downloader-links')))
            .controller!
            .text;
        final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('downloader-submit')),
        );
        final count = jobs.jobs.length;
        record('field filled', {
          'typed_as_given': typed == text,
          'download_enabled': button.onPressed != null,
        });
        expect(typed, text, reason: 'the field took the text');
        await tester.tap(find.byKey(const ValueKey('downloader-submit')));
        await wait(
          () => !jobs.submitting && jobs.jobs.length > count,
          'the submit answer',
          each: watch,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('downloader-error')),
          findsNothing,
          reason: 'submit refused',
        );
      }

      // 2. One audio link, then video links pasted together.
      final song = '$site/item/song.html';
      final low = '$site/item/low.html';
      final unfit = '$site/item/vp9.html';
      expect(find.text('Saves to Music'), findsOneWidget);
      await submit(song);
      expect(row(song), isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('downloader-links')))
            .controller!
            .text,
        isEmpty,
      );
      record('audio link submitted through the field');

      await tester.tap(find.byKey(const ValueKey('downloader-video')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('downloader-720p')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Saves to Videos'), findsOneWidget);
      final videos = [low, unfit, ?extra];
      await submit(videos.join('\n'));
      for (final url in videos) {
        expect(row(url), isNotNull, reason: url);
      }
      record('video links submitted at 720p', {'links': videos.length});
      await screenshot('03-rows-just-submitted');

      // Rows move through their states; one picture while something runs.
      var running = false;
      await wait(
        () => [song, low, unfit].every((url) => row(url)!.isFinished),
        'the fixture rows to finish',
        seconds: 420,
        each: () {
          watch();
          running =
              running ||
              mine().any((job) => job.state == FetchState.downloading);
        },
      );
      if (extra != null) {
        try {
          await wait(
            () => row(extra)!.isFinished,
            'the extra row',
            seconds: 240,
            each: watch,
          );
        } on StateError {
          record('the extra link did not finish in time (not required)');
        }
      }
      await tester.pump(const Duration(seconds: 1));
      record('rows finished', {
        'states_seen': seen,
        'downloading_seen': running,
        'rows': [
          for (final job in mine())
            {
              'url': job.url,
              'state': job.state.name,
              'label': fetchStateLabel(job),
              'title': job.title,
              'path': job.path,
              'height': job.height,
              'message': job.message,
            },
        ],
      });
      await screenshot('04-rows-finished');

      final audio = row(song)!;
      expect(audio.state, FetchState.done);
      expect(audio.path, matches(RegExp(r'^Music/.+\.m4a$')));
      expect(
        tester.widget<Text>(find.byKey(ValueKey('job-state:${audio.id}'))).data,
        'Done',
      );
      final video = row(low)!;
      expect(video.state, FetchState.done);
      expect(video.path, matches(RegExp(r'^Videos/.+\.mp4$')));
      expect(video.height, 480);
      expect(
        tester.widget<Text>(find.byKey(ValueKey('job-state:${video.id}'))).data,
        'Done · 480p',
      );
      // 3. A source that fits no preset: its sentence is on the row.
      final rejected = row(unfit)!;
      expect(rejected.state, FetchState.rejected);
      expect(rejected.path, isNull);
      expect(rejected.message, isNotNull);
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('job-state:${rejected.id}')))
            .data,
        'Not supported',
      );
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('job-message:${rejected.id}')))
            .data,
        rejected.message,
      );
      expect(find.byKey(ValueKey('job-show:${rejected.id}')), findsNothing);
      record('done and rejected rows shown as specified');

      // The files arrive in the synced folder by ordinary sync.
      final done = [
        for (final job in mine())
          if (job.state == FetchState.done && job.path != null) job,
      ];
      placed.addAll([for (final job in done) job.path!]);
      await wait(
        () => placed.every((path) {
          final file = File('${controller.root}/$path');
          return file.existsSync() &&
              file.lengthSync() > 0 &&
              controller.entries.any(
                (entry) =>
                    entry['path'] == path &&
                    (entry['status'] as String).startsWith('current'),
              );
        }),
        'the files in the synced folder',
        seconds: 240,
      );
      record('files arrived locally', {
        'files': {
          for (final path in placed)
            path: File('${controller.root}/$path').lengthSync(),
        },
      });

      // Show in folder: the library's reveal on Home.
      await tester.tap(find.byKey(ValueKey('job-show:${audio.id}')));
      await until(find.byKey(ValueKey('row:${audio.path}')));
      expect(find.byType(DownloaderTab), findsNothing);
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(jobs.tabVisible, isFalse);
      record('Show in folder revealed the file on Home');
      await screenshot('05-show-in-folder');

      // Remove this run's rows through the tab (others are left alone).
      await tester.tap(tab);
      await until(find.byType(DownloaderTab));
      for (final job in mine()) {
        final action = find.byKey(
          ValueKey('job-${job.isFinished ? 'remove' : 'cancel'}:${job.id}'),
        );
        await tester.ensureVisible(action);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(action);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await wait(
        () => mine().every((job) => job.isFinished),
        'cancelled rows to settle',
        seconds: 60,
      );
      for (final job in mine()) {
        final remove = find.byKey(ValueKey('job-remove:${job.id}'));
        if (remove.evaluate().isEmpty) continue;
        await tester.ensureVisible(remove);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(remove);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await wait(() => mine().isEmpty, 'the rows to be removed');
      await tester.runAsync(jobs.refresh);
      expect(mine(), isEmpty);
      expect({for (final job in jobs.jobs) job.id}, before);
      record('this run\'s rows removed; the others untouched');
      await screenshot('06-rows-removed');
    } finally {
      // This run's rows, the files it placed (everywhere), then the device.
      try {
        final known = before;
        if (known != null) {
          final jobs = controller.fetchJobs;
          for (var pass = 0; pass < 2; pass++) {
            await tester.runAsync(jobs.refresh);
            for (final job in jobs.jobs) {
              if (known.contains(job.id)) continue;
              await tester.runAsync(
                () =>
                    job.isFinished ? jobs.remove(job.id) : jobs.cancel(job.id),
              );
            }
            await tester.pump(const Duration(seconds: 3));
          }
          await tester.runAsync(jobs.refresh);
          record('rows left by this run', {
            'count': jobs.jobs.where((j) => !known.contains(j.id)).length,
          });
        }
      } on Object catch (error) {
        record('row cleanup incomplete', {'error': '$error'});
      }
      try {
        for (final path in placed) {
          controller.command('delete', path);
        }
        if (placed.isNotEmpty) {
          await wait(
            () => placed.every(
              (path) =>
                  !File('${controller.root}/$path').existsSync() &&
                  !controller.entries.any(
                    (entry) => entry['path'] == path && visibleInLibrary(entry),
                  ),
            ),
            'the files to be deleted everywhere',
            seconds: 180,
          );
          record('files deleted from the account', {'files': placed.toList()});
        }
      } on Object catch (error) {
        record('file cleanup incomplete', {'error': '$error'});
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.stop();
        if (fingerprint != null) {
          final devices = await operator(['devices']) as List;
          for (final device in devices.cast<Map>()) {
            if (device['fingerprint'] == fingerprint &&
                device['state'] != 'revoked') {
              await operator(['revoke', device['id'] as String]);
              record('device revoked', {'device': device['id']});
            }
          }
        }
      });
      controller.dispose();
      fixture.deleteSync(recursive: true);
      tester.view.reset();
    }
  });
}
