// Spec #42 F4: the controller's side of the Downloader, with a scripted
// worker isolate in place of the sync worker: each answer reaches the
// request that asked (by request id), a request without an answer times out,
// requests still waiting fail when the worker stops, crashes or is
// restarted, and the availability probe runs when the worker reports ready
// or state (an unpaired device probes nothing).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/fetch_jobs.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Stands in for the sync worker. A submit's link says what to do with it:
/// `.../hold/<id>` is answered only when `.../release/<id>` arrives (which
/// is answered first, then the held ones, newest first), `.../silent/<id>`
/// never, and `.../crash/<id>` ends the isolate. Deleting `state` sends a
/// state event first, deleting `later` sends one a moment after answering.
/// Every list answers one row, `list<n>`.
Future<void> scriptedWorker(Map<String, Object?> initial) async {
  final output = initial['output'] as SendPort;
  final input = ReceivePort();
  final held = <Map>[];
  var lists = 0;
  void answer(Map command, [String? id]) => output.send({
    'event': 'fetchResult',
    'request': command['request'],
    'ok': true,
    'data': id == null
        ? null
        : {
            'jobs': [
              {'id': id, 'state': 'waiting'},
            ],
          },
  });
  String tag(Map command) =>
      Uri.parse((command['urls'] as List).single as String).pathSegments.last;
  input.listen((message) {
    final command = message as Map;
    if (command['action'] == 'stop') {
      output.send({'event': 'stopped'});
      input.close();
      return;
    }
    if (command['action'] != 'fetch') return;
    switch (command['op']) {
      case 'list':
        answer(command, 'list${++lists}');
      case 'submit':
        final mode = Uri.parse((command['urls'] as List).single as String)
            .pathSegments
            .first;
        switch (mode) {
          case 'hold':
            held.add(command);
          case 'release':
            answer(command, tag(command));
            for (final waiting in held.reversed) {
              answer(waiting, tag(waiting));
            }
            held.clear();
          case 'crash':
            Isolate.exit();
          case 'silent':
            break;
        }
      case 'delete':
        void state() => output.send({
          'event': 'state',
          'storageReady': true,
          'entries': const <Map>[],
          'message': 'Up to date',
          'paused': false,
          'finishing': false,
          'networkPolicy': null,
          'transfersHeld': false,
          'status': 'upToDate',
        });
        if (command['id'] == 'state') state();
        if (command['id'] == 'later') {
          Timer(const Duration(milliseconds: 150), state);
        }
        answer(command);
    }
  });
  output.send({'event': 'ready', 'input': input.sendPort});
}

Future<void> until(bool Function() condition, String what) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: what);
}

Matcher failsWith(FetchError error) =>
    throwsA(isA<FetchFailure>().having((f) => f.error, 'error', error));

void main() {
  late Directory fixture;
  late ClientController controller;

  /// Starts the scripted worker (choosing the root starts sync).
  Future<void> startWorker() async {
    final parent = Directory('${fixture.path}/files')..createSync();
    await controller.configureRoot(parent.path);
  }

  void pair() => controller
    ..server = 'https://gateway.example.com'
    ..pairingState = 'paired';

  Future<List<FetchJob>> submit(String path) => controller.fetchJobs.transport
      .submitFetchJobs(['https://media.example.com/$path'], FetchKind.audio);

  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('anj-fetch-controller-');
    controller = ClientController(
      Directory('${fixture.path}/profile'),
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
      workerEntry: scriptedWorker,
      fetchTimeout: const Duration(milliseconds: 400),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.stop();
    controller.dispose();
    fixture.deleteSync(recursive: true);
  });

  test('each answer reaches the request that asked for it', () async {
    await startWorker();
    pair();
    final first = submit('hold/h1');
    final second = submit('hold/h2');
    final third = submit('release/r');
    // Answered in the order r, h2, h1.
    expect((await third).single.id, 'r');
    expect((await first).single.id, 'h1');
    expect((await second).single.id, 'h2');
  });

  test(
    'a request the worker never answers times out; the next works',
    () async {
      await startWorker();
      pair();
      final watch = Stopwatch()..start();
      await expectLater(submit('silent/s'), failsWith(FetchError.network));
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 350)),
      );
      expect((await submit('release/r')).single.id, 'r');
    },
  );

  test('nothing is sent while unpaired or without a worker', () async {
    pair();
    await expectLater(submit('release/r'), failsWith(FetchError.notConnected));
    await startWorker();
    controller.pairingState = 'unpaired';
    await expectLater(submit('release/r'), failsWith(FetchError.notConnected));
    pair();
    expect((await submit('release/r')).single.id, 'r');
  });

  test('requests still waiting fail when the worker stops, and work again '
      'after a restart', () async {
    await startWorker();
    pair();
    final waiting = [submit('hold/h1'), submit('hold/h2')];
    final failed = [
      for (final request in waiting)
        expectLater(request, failsWith(FetchError.network)),
    ];
    await controller.stop();
    await Future.wait(failed);
    await expectLater(submit('release/r'), failsWith(FetchError.notConnected));
    await controller.start();
    // The new worker knows nothing of the old requests.
    expect((await submit('release/r')).single.id, 'r');
  });

  test('requests still waiting fail when the worker crashes', () async {
    await startWorker();
    pair();
    final waiting = [submit('hold/h1'), submit('crash/c')];
    await Future.wait([
      for (final request in waiting)
        expectLater(request, failsWith(FetchError.network)),
    ]);
    await expectLater(submit('release/r'), failsWith(FetchError.notConnected));
  });

  test('the worker reporting ready probes a paired server once', () async {
    pair();
    final jobs = controller.fetchJobs;
    expect(jobs.availability, FetchAvailability.unknown);
    await startWorker();
    await until(
      () => jobs.availability == FetchAvailability.available,
      'probed at ready',
    );
    expect(jobs.jobs.single.id, 'list1');
    // A state report probes nothing more once the server has answered.
    await jobs.transport.deleteFetchJob('state');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs.jobs.single.id, 'list1');
  });

  test(
    'a state report probes; an unpaired device forgets the answer',
    () async {
      final jobs = controller.fetchJobs;
      await startWorker();
      // Ready while unpaired: nothing asked.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(jobs.availability, FetchAvailability.unknown);
      expect(jobs.loaded, isFalse);
      pair();
      await jobs.transport.deleteFetchJob('state');
      await until(
        () => jobs.availability == FetchAvailability.available,
        'probed at state',
      );
      expect(jobs.jobs.single.id, 'list1');
      // Unpaired: the next report clears what was known.
      await jobs.transport.deleteFetchJob('later');
      controller.pairingState = 'unpaired';
      await until(
        () => jobs.availability == FetchAvailability.unknown,
        'forgotten when unpaired',
      );
      expect(jobs.jobs, isEmpty);
      expect(jobs.loaded, isFalse);
    },
  );
}
