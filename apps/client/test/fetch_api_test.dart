// Spec #42 F2/F4: the client half of the media fetch job routes. The four
// routes against a local gateway stand-in (plain HTTP on loopback: the
// routes' behaviour, not TLS, is under test; DavCloud hands them its mTLS
// client), the job row parser, and the worker boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('job rows', () {
    test('parse known fields, tolerate unknown ones and states', () {
      final rows = parseFetchJobs({
        'jobs': [
          {
            'id': 'a1',
            'state': 'downloading',
            'kind': 'video',
            'title': 'Clip',
            'url': 'https://media.example/v/1',
            'percent': 42.5,
            'height': 720,
            'message': '',
            'submitted': 1793639049.5,
            'future_field': {'nested': true},
          },
          {
            'id': 'b2',
            'state': 'archived-later',
            'kind': 'podcast',
            'percent': 140,
            'path': 'Music/Song.m4a',
            'message': 'Saved.',
            'submitted': 1793613600,
            'finished': 1793613900,
          },
          {'state': 'done'},
          {'id': 7, 'state': 'done'},
          {'id': '../escape', 'state': 'done'},
          'not a row',
        ],
      });
      expect(rows.map((row) => row.id), ['a1', 'b2']);
      final first = rows[0];
      expect(first.state, FetchState.downloading);
      expect(first.kind, FetchKind.video);
      expect(
        (first.title, first.url, first.percent),
        ('Clip', 'https://media.example/v/1', 42.5),
      );
      expect(first.height, 720);
      expect(first.message, isNull);
      expect(
        first.submitted,
        DateTime.fromMillisecondsSinceEpoch(1793639049500, isUtc: true),
      );
      expect(first.isFinished, isFalse);
      final second = rows[1];
      expect(second.state, FetchState.unknown);
      expect(second.rawState, 'archived-later');
      expect(second.kind, isNull);
      expect(second.percent, 100);
      expect(second.path, 'Music/Song.m4a');
      expect(
        second.finished,
        DateTime.fromMillisecondsSinceEpoch(1793613900000, isUtc: true),
      );
      // An unknown state with a finish time is finished; without, it is not.
      expect(second.isFinished, isTrue);
      expect(fetchJob('x', FetchState.unknown).isFinished, isFalse);
      // The body is {"jobs": [...]} and nothing else.
      expect(parseFetchJobs({'jobs': []}), isEmpty);
      for (final body in [
        [],
        {'rows': []},
        {'jobs': 'none'},
        null,
        'jobs',
      ]) {
        expect(
          () => parseFetchJobs(body),
          throwsA(
            isA<FetchFailure>().having(
              (f) => f.error,
              'error',
              FetchError.unexpected,
            ),
          ),
          reason: '$body',
        );
      }
    });

    test('only the contract\'s field names and Unix seconds are read', () {
      final row = parseFetchJobs({
        'jobs': [
          {
            'id': 'a',
            'state': 'done',
            'link': 'https://media.example/v/1',
            'destination': 'Music/A.m4a',
            'submitted_at': 1793613600,
            'finished_at': 1793613900,
            'submitted': '2026-11-12T10:00:00Z',
            'finished': '2026-11-12T10:05:00Z',
          },
        ],
      }).single;
      expect(
        (row.url, row.path, row.submitted, row.finished),
        (null, null, null, null),
      );
    });

    test('a time no date can hold is dropped; the list still loads', () {
      final rows = parseFetchJobs({
        'jobs': [
          {'id': 'a', 'state': 'waiting', 'submitted': 1e20},
          {'id': 'b', 'state': 'done', 'finished': 8640000000001},
          {'id': 'c', 'state': 'done', 'finished': -5, 'submitted': 12},
          {'id': 'd', 'state': 'done', 'finished': 8640000000000},
          {'id': 'e', 'state': 'done', 'finished': double.infinity},
        ],
      });
      expect(rows.map((row) => row.id), ['a', 'b', 'c', 'd', 'e']);
      expect(rows[0].submitted, isNull);
      expect(rows[1].finished, isNull);
      expect(rows[2].finished, isNull);
      expect(
        rows[2].submitted,
        DateTime.fromMillisecondsSinceEpoch(12000, isUtc: true),
      );
      expect(rows[3].finished, isNotNull);
      expect(rows[4].finished, isNull);
      // A done row without a readable finish time is still finished.
      expect(rows[1].isFinished, isTrue);
    });

    test('survive the worker boundary unchanged, unknown state included', () {
      final rows = parseFetchJobs({
        'jobs': [
          {
            'id': 'a',
            'state': 'brand-new',
            'kind': 'audio',
            'title': 'T',
            'url': 'https://media.example/t',
            'percent': 3,
            'path': 'Music/T.m4a',
            'message': 'm',
            'height': 720,
            'submitted': 0,
            'finished': 1793613900.25,
          },
        ],
      });
      final again = parseFetchJobs(
        jsonDecode(
          jsonEncode({
            'jobs': [for (final row in rows) row.toJson()],
          }),
        ),
      );
      expect(again.single.finished, rows.single.finished);
      expect(
        again.single.finished,
        DateTime.fromMillisecondsSinceEpoch(1793613900250, isUtc: true),
      );
      expect(again.single.submitted, rows.single.submitted);
      expect(
        jsonEncode(again.single.toJson()),
        jsonEncode(rows.single.toJson()),
      );
      expect(again.single.rawState, 'brand-new');
      expect(again.single.state, FetchState.unknown);
    });

    test('every error has a plain sentence without codes', () {
      for (final error in FetchError.values) {
        expect(error.message, isNotEmpty);
        expect(error.message, isNot(matches(RegExp(r'[0-9]{3}'))));
        expect(FetchError.parse(error.name), error);
      }
      expect(FetchError.parse('from-a-newer-worker'), FetchError.unexpected);
      expect(FetchState.parse(null), FetchState.unknown);
    });
  });

  group('gateway routes', () {
    late HttpServer server;
    late HttpClient client;
    late HttpFetchTransport api;
    late Future<void> Function(HttpRequest request, String body) handler;
    final seen = <(String, String, String)>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        seen.add((request.method, request.uri.path, body));
        await handler(request, body);
      });
      client = HttpClient();
      api = HttpFetchTransport(
        client,
        Uri.parse('http://127.0.0.1:${server.port}'),
      );
    });
    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    Future<void> reply(HttpRequest request, int status, [Object? body]) async {
      request.response.statusCode = status;
      request.response.headers.set('cache-control', 'no-store');
      if (body != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
      }
      await request.response.close();
    }

    Matcher failsWith(FetchError error) =>
        throwsA(isA<FetchFailure>().having((f) => f.error, 'error', error));

    test('list: rows newest first; 404 means the feature is absent', () async {
      handler = (request, _) => reply(request, 200, {
        'jobs': [
          {'id': 'b', 'state': 'waiting', 'kind': 'audio'},
          {'id': 'a', 'state': 'done', 'kind': 'audio', 'path': 'Music/A.m4a'},
        ],
      });
      final rows = (await api.listFetchJobs())!;
      expect(rows.map((row) => (row.id, row.state)), [
        ('b', FetchState.waiting),
        ('a', FetchState.done),
      ]);
      expect(seen.single.$1, 'GET');
      expect(seen.single.$2, '/v1/fetch/jobs');
      handler = (request, _) => reply(request, 404, {'error': 'not_found'});
      expect(await api.listFetchJobs(), isNull);
      handler = (request, _) async {
        request.response.write('<html>proxy error</html>');
        await request.response.close();
      };
      await expectLater(api.listFetchJobs(), failsWith(FetchError.unexpected));
      handler = (request, _) => reply(request, 401);
      await expectLater(
        api.listFetchJobs(),
        failsWith(FetchError.deviceRefused),
      );
      handler = (request, _) => reply(request, 503, {'error': 'Worker down'});
      await expectLater(api.listFetchJobs(), failsWith(FetchError.busy));
    });

    test('submit: the body, and video alone carries a height', () async {
      handler = (request, _) => reply(request, 202, {
        'jobs': [
          {'id': 'n1', 'state': 'waiting', 'kind': 'video'},
        ],
      });
      final rows = await api.submitFetchJobs(
        ['https://media.example/v/1', 'http://media.example/v/2'],
        FetchKind.video,
        resolution: FetchResolution.p720,
      );
      expect(rows.single.id, 'n1');
      expect((seen.last.$1, seen.last.$2), ('POST', '/v1/fetch/jobs'));
      expect(jsonDecode(seen.last.$3), {
        'urls': ['https://media.example/v/1', 'http://media.example/v/2'],
        'kind': 'video',
        'height': 720,
      });
      await api.submitFetchJobs(
        ['https://media.example/a'],
        FetchKind.audio,
        resolution: FetchResolution.p720,
      );
      expect(jsonDecode(seen.last.$3), {
        'urls': ['https://media.example/a'],
        'kind': 'audio',
      });
      await api.submitFetchJobs(['https://media.example/v'], FetchKind.video);
      expect((jsonDecode(seen.last.$3) as Map)['height'], 1080);
    });

    test('submit refusals become typed errors, never server text', () async {
      for (final (status, error) in [
        (400, FetchError.badLink),
        (401, FetchError.deviceRefused),
        (403, FetchError.readOnly),
        (404, FetchError.absent),
        (429, FetchError.tooMany),
        (503, FetchError.busy),
        (507, FetchError.storageFull),
        (500, FetchError.unexpected),
        (302, FetchError.unexpected),
      ]) {
        handler = (request, _) =>
            reply(request, status, {'error': 'raw server detail $status'});
        await expectLater(
          api.submitFetchJobs(['https://media.example/x'], FetchKind.audio),
          failsWith(error),
          reason: '$status',
        );
      }
    });

    test('delete one row, clear finished; a gone row is notFound', () async {
      handler = (request, _) => reply(request, 204);
      await api.deleteFetchJob('job-1');
      expect((seen.last.$1, seen.last.$2), ('DELETE', '/v1/fetch/jobs/job-1'));
      await api.clearFetchJobs();
      expect((seen.last.$1, seen.last.$2), ('POST', '/v1/fetch/jobs/clear'));
      handler = (request, _) => reply(request, 404, {'error': 'no such job'});
      await expectLater(
        api.deleteFetchJob('job-2'),
        failsWith(FetchError.notFound),
      );
      handler = (request, _) => reply(request, 403);
      await expectLater(
        api.deleteFetchJob('job-2'),
        failsWith(FetchError.readOnly),
      );
      await expectLater(api.clearFetchJobs(), failsWith(FetchError.readOnly));
      // An id that is not URL-safe is never put in a path.
      final count = seen.length;
      await expectLater(
        api.deleteFetchJob('../x'),
        failsWith(FetchError.notFound),
      );
      expect(seen.length, count);
    });

    test('no server: a network error', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final offline = HttpFetchTransport(
        client,
        Uri.parse('http://127.0.0.1:$port'),
      );
      await expectLater(offline.listFetchJobs(), failsWith(FetchError.network));
      await expectLater(
        offline.submitFetchJobs(['https://media.example/x'], FetchKind.audio),
        failsWith(FetchError.network),
      );
    });
  });

  group('worker boundary', () {
    /// The app's transport over the worker's handler, through JSON as an
    /// isolate message would carry it.
    MessageFetchTransport through(FetchTransport? worker) =>
        MessageFetchTransport((command) {
          final reply = Completer<Map>();
          unawaited(
            answerFetchCommand(
              worker,
              jsonDecode(jsonEncode({...command, 'request': 'r1'})) as Map,
              (event) => reply.complete(jsonDecode(jsonEncode(event)) as Map),
            ),
          );
          return reply.future;
        });

    test('every route round-trips, errors as their type', () async {
      final fake = FakeFetch()
        ..rows = [fetchJob('a', FetchState.placing)]
        ..submitted = [fetchJob('n', FetchState.waiting)];
      final app = through(fake);
      expect((await app.listFetchJobs())!.single.state, FetchState.placing);
      expect(
        (await app.submitFetchJobs(
          ['https://x.example/1'],
          FetchKind.video,
          resolution: FetchResolution.p720,
        )).single.id,
        'n',
      );
      expect(fake.lastSubmit!.resolution, FetchResolution.p720);
      expect(fake.lastSubmit!.kind, FetchKind.video);
      await app.deleteFetchJob('a');
      await app.clearFetchJobs();
      expect(fake.calls, ['list', 'submit', 'delete a', 'clear']);
      fake.rows = null;
      expect(await app.listFetchJobs(), isNull);
      fake.actionError = FetchError.storageFull;
      await expectLater(
        app.submitFetchJobs(['https://x.example/1'], FetchKind.audio),
        throwsA(
          isA<FetchFailure>().having(
            (f) => f.error,
            'error',
            FetchError.storageFull,
          ),
        ),
      );
      await expectLater(
        through(null).listFetchJobs(),
        throwsA(
          isA<FetchFailure>().having(
            (f) => f.error,
            'error',
            FetchError.notConnected,
          ),
        ),
      );
    });
  });

  group('sync worker', () {
    test('answers fetch beside its queue and sends no library state', () async {
      final fixture = Directory.systemTemp.createTempSync('anj-fetch-worker-');
      final parent = Directory('${fixture.path}/files')..createSync();
      final tree = RootTree.setup(parent.path, 'fetch', NativeRootFs());
      final store = Manifest(Directory('${fixture.path}/profile'))
        ..setSetting('retention', 'local');
      final engine = SyncEngine(store, tree, FakeCloud());
      final fake = FakeFetch()..rows = [fetchJob('a', FetchState.downloading)];
      final events = <Map>[];
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        engine,
        (event) => events.add(event as Map),
        // No timed pass during the test: only the start-up pass emits.
        interval: const Duration(minutes: 5),
        fetch: fake,
      );
      final done = loop.run(input.stream);
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 500 && !condition(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(condition(), isTrue);
      }

      Map? answer(String request) => events
          .where((e) => e['event'] == 'fetchResult' && e['request'] == request)
          .firstOrNull;
      try {
        await until(() => loop.emitted > 0);
        final emitted = loop.emitted;
        input.add({'action': 'fetch', 'op': 'list', 'request': 'q1'});
        await until(() => answer('q1') != null);
        expect(answer('q1')!['ok'], isTrue);
        expect(
          parseFetchJobs(answer('q1')!['data']).single.state,
          FetchState.downloading,
        );
        fake.actionError = FetchError.tooMany;
        input.add({
          'action': 'fetch',
          'op': 'submit',
          'request': 'q2',
          'urls': ['https://x.example/1'],
          'kind': 'audio',
        });
        await until(() => answer('q2') != null);
        expect(
          (answer('q2')!['ok'], answer('q2')!['error']),
          (false, 'tooMany'),
        );
        expect(loop.emitted, emitted, reason: 'no state event per fetch');
      } finally {
        input.add({'action': 'stop'});
        await done;
        await input.close();
        fixture.deleteSync(recursive: true);
      }
    });
  });
}
