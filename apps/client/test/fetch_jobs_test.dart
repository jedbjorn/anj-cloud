// Spec #42 F4: the Downloader's state in the shared client core: the
// availability probe, polling only while visible (on a fake timer and
// clock, so nothing sleeps), the sync pass when a row turns done, submit
// and row actions, the remembered choice and the link parser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/fetch_jobs.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// A timer the test fires by hand: nothing sleeps.
class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

/// Lets queued microtasks and completed futures run.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('Downloader state', () {
    late FakeFetch fake;
    late List<_FakeTimer> timers;
    late Duration now;
    late int syncs;
    late FetchJobs jobs;

    FetchJobs make({FetchPreferences? preferences}) => FetchJobs(
      fake,
      requestSync: () => syncs++,
      preferences: preferences,
      timer: (delay, callback) {
        final timer = _FakeTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
      clock: () => now,
    );

    List<_FakeTimer> active() => timers.where((t) => t.isActive).toList();

    setUp(() {
      fake = FakeFetch();
      timers = [];
      now = Duration.zero;
      syncs = 0;
      jobs = make();
    });
    tearDown(() => jobs.dispose());

    test(
      'probe: once per session and server; 404 hides, no answer retries',
      () async {
        fake.listError = FetchError.network;
        await jobs.probe('https://a.example');
        expect(jobs.availability, FetchAvailability.unknown);
        expect(jobs.listError, FetchError.network);
        // No answer: asked again only after the retry interval.
        await jobs.probe('https://a.example');
        expect(fake.calls, ['list']);
        now += const Duration(seconds: 30);
        fake.listError = null;
        fake.rows = [fetchJob('a', FetchState.done)];
        await jobs.probe('https://a.example');
        expect(jobs.availability, FetchAvailability.available);
        expect(jobs.loaded, isTrue);
        expect(jobs.jobs.single.id, 'a');
        now += const Duration(hours: 1);
        await jobs.probe('https://a.example');
        expect(fake.calls, ['list', 'list']);
        // Another server (re-paired): state resets and it is asked.
        fake.rows = null;
        await jobs.probe('https://b.example');
        expect(jobs.availability, FetchAvailability.absent);
        expect(jobs.jobs, isEmpty);
        await jobs.probe('https://b.example');
        expect(fake.calls.length, 3);
        // Unpaired: unknown, nothing asked.
        await jobs.probe(null);
        expect(jobs.availability, FetchAvailability.unknown);
        expect(fake.calls.length, 3);
        // Nothing was polled: the tab was never visible.
        expect(timers, isEmpty);
      },
    );

    test('polls every 2 s only while visible with unfinished rows', () async {
      fake.rows = [fetchJob('a', FetchState.downloading)];
      await jobs.probe('https://a.example');
      expect(timers, isEmpty, reason: 'no polling before the tab is shown');
      jobs.setTabVisible(true);
      await settle();
      expect(fake.calls, ['list', 'list'], reason: 'once when the tab opens');
      expect(active().single.delay, const Duration(seconds: 2));
      active().single.fire();
      await settle();
      expect(fake.calls.length, 3);
      expect(active().length, 1);
      // The app goes to the background (Android) or the window hides.
      jobs.setAppVisible(false);
      expect(active(), isEmpty);
      await settle();
      expect(fake.calls.length, 3);
      jobs.setAppVisible(true);
      await settle();
      expect(fake.calls.length, 4);
      // Everything finished: no further polls.
      fake.rows = [fetchJob('a', FetchState.failed)];
      active().single.fire();
      await settle();
      expect(fake.calls.length, 5);
      expect(active(), isEmpty);
      // Refresh still lists once, and schedules nothing.
      await jobs.refresh();
      expect(fake.calls.length, 6);
      expect(active(), isEmpty);
      // Another tab chosen: nothing more.
      jobs.setTabVisible(false);
      fake.rows = [fetchJob('b', FetchState.waiting)];
      await jobs.refresh();
      expect(active(), isEmpty);
    });

    test(
      'a failing poll keeps the rows and keeps polling while unfinished',
      () async {
        fake.rows = [fetchJob('a', FetchState.waiting)];
        await jobs.probe('https://a.example');
        jobs.setTabVisible(true);
        await settle();
        fake.listError = FetchError.network;
        active().single.fire();
        await settle();
        expect(jobs.listError, FetchError.network);
        expect(jobs.jobs.single.id, 'a');
        expect(active().length, 1);
        fake.listError = null;
        active().single.fire();
        await settle();
        expect(jobs.listError, isNull);
      },
    );

    test('a row turning done asks for one sync pass, once per row', () async {
      fake.rows = [
        fetchJob('a', FetchState.downloading),
        fetchJob('b', FetchState.placing),
        fetchJob('old', FetchState.done),
      ];
      await jobs.probe('https://a.example');
      jobs.setTabVisible(true);
      await settle();
      expect(syncs, 0, reason: 'a row first seen done is not a transition');
      fake.rows = [
        fetchJob('a', FetchState.done),
        fetchJob('b', FetchState.placing),
        fetchJob('old', FetchState.done),
      ];
      active().single.fire();
      await settle();
      expect(syncs, 1);
      active().single.fire();
      await settle();
      expect(syncs, 1, reason: 'not again on the next poll');
      fake.rows = [
        fetchJob('a', FetchState.done),
        fetchJob('b', FetchState.done),
        fetchJob('old', FetchState.done),
      ];
      active().single.fire();
      await settle();
      expect(syncs, 2);
      await jobs.refresh();
      expect(syncs, 2);
      // A failure is not done: no pass.
      fake.rows = [fetchJob('c', FetchState.failed), ...fake.rows!];
      await jobs.refresh();
      expect(syncs, 2);
    });

    test(
      'submit uses the remembered choice and shows new rows at once',
      () async {
        fake.rows = const [];
        await jobs.probe('https://a.example');
        jobs.setTabVisible(true);
        await settle();
        expect(active(), isEmpty);
        fake.submitted = [fetchJob('n', FetchState.waiting)];
        expect(jobs.kind, FetchKind.audio);
        expect(await jobs.submit(['https://x.example/1']), isNull);
        expect(fake.lastSubmit!.kind, FetchKind.audio);
        expect(fake.lastSubmit!.resolution, isNull);
        expect(jobs.jobs.single.id, 'n');
        expect(active().single.delay, const Duration(seconds: 2));
        jobs
          ..setKind(FetchKind.video)
          ..setResolution(FetchResolution.p720);
        await jobs.submit(['https://x.example/2']);
        expect(fake.lastSubmit!.kind, FetchKind.video);
        expect(fake.lastSubmit!.resolution, FetchResolution.p720);
        for (final error in [
          FetchError.badLink,
          FetchError.readOnly,
          FetchError.tooMany,
          FetchError.storageFull,
          FetchError.busy,
          FetchError.network,
        ]) {
          fake.actionError = error;
          expect(await jobs.submit(['https://x.example/3']), error);
          expect(jobs.submitting, isFalse);
        }
        fake.actionError = FetchError.absent;
        expect(await jobs.submit(['https://x.example/3']), FetchError.absent);
        expect(jobs.availability, FetchAvailability.absent);
        expect(await jobs.submit(const []), FetchError.badLink);
      },
    );

    test('cancel, remove and clear change rows, then list again', () async {
      fake.rows = [
        fetchJob('run', FetchState.downloading),
        fetchJob('fin', FetchState.done),
        fetchJob('bad', FetchState.rejected),
      ];
      await jobs.probe('https://a.example');
      jobs.setTabVisible(true);
      await settle();
      final lists = fake.calls.where((c) => c == 'list').length;
      expect(await jobs.cancel('run'), isNull);
      await settle();
      expect(fake.calls, contains('delete run'));
      expect(fake.calls.where((c) => c == 'list').length, lists + 1);
      // The server's rows after each change (the list that follows it).
      fake.rows = [
        fetchJob('run', FetchState.cancelled),
        fetchJob('bad', FetchState.rejected),
      ];
      expect(await jobs.remove('fin'), isNull);
      expect(jobs.jobs.map((j) => j.id), isNot(contains('fin')));
      expect(fake.calls, contains('delete fin'));
      await settle();
      expect(jobs.jobs.map((j) => j.id), ['run', 'bad']);
      fake.rows = const [];
      expect(await jobs.clearFinished(), isNull);
      expect(jobs.jobs, isEmpty);
      await settle();
      expect(fake.calls.last, 'list');
      expect(jobs.jobs, isEmpty);
      // A row already gone on the server is simply removed.
      fake.rows = [fetchJob('x', FetchState.done)];
      await jobs.refresh();
      fake.actionError = FetchError.notFound;
      expect(await jobs.remove('x'), isNull);
      fake.actionError = FetchError.busy;
      expect(await jobs.clearFinished(), FetchError.busy);
    });

    test('a list asked before a submit never replaces the new rows', () async {
      final old = fetchJob('old', FetchState.done);
      final fresh = fetchJob('new', FetchState.waiting);
      fake.rows = [old];
      await jobs.probe('https://a.example');
      jobs.setTabVisible(true);
      await settle();
      expect(active(), isEmpty, reason: 'nothing unfinished: no poll');
      // A list is under way; the server answered it before the submit.
      fake.listGate = Completer<void>();
      fake.listAnswers.add([old]);
      final list = jobs.refresh();
      await settle();
      fake.submitted = [fresh];
      expect(await jobs.submit(['https://x.example/1']), isNull);
      expect(jobs.jobs.map((job) => job.id), ['new', 'old']);
      // What the server lists from now on.
      fake.rows = [fresh, old];
      final lists = fake.calls.where((c) => c == 'list').length;
      final shown = <List<String>>[];
      jobs.addListener(() => shown.add([for (final j in jobs.jobs) j.id]));
      fake.listGate!.complete();
      fake.listGate = null;
      await list;
      await settle();
      expect(shown, everyElement(['new', 'old']));
      expect(jobs.jobs.map((job) => job.id), ['new', 'old']);
      expect(
        fake.calls.where((c) => c == 'list').length,
        lists + 1,
        reason: 'one more list follows the one that was dropped',
      );
      expect(active().single.delay, const Duration(seconds: 2));
    });

    test(
      'a list asked before a cancel, remove or clear never undoes it',
      () async {
        final run = fetchJob('run', FetchState.downloading);
        final fin = fetchJob('fin', FetchState.done);
        final bad = fetchJob('bad', FetchState.failed);
        fake.rows = [run, fin, bad];
        await jobs.probe('https://a.example');
        final shown = <List<String>>[];
        jobs.addListener(() => shown.add([for (final j in jobs.jobs) j.id]));
        Future<void> during(
          List<FetchJob> after,
          Future<FetchError?> Function() change,
        ) async {
          fake.listGate = Completer<void>();
          fake.listAnswers.add(fake.rows);
          final list = jobs.refresh();
          await settle();
          fake.rows = after;
          expect(await change(), isNull);
          shown.clear();
          fake.listGate!.complete();
          fake.listGate = null;
          await list;
          await settle();
        }

        await during([run, bad], () => jobs.remove('fin'));
        expect(shown, everyElement(['run', 'bad']));
        await during([run], jobs.clearFinished);
        expect(shown, everyElement(['run']));
        // Cancel keeps the row; the list after it shows it cancelled.
        await during([
          fetchJob('run', FetchState.cancelled),
        ], () => jobs.cancel('run'));
        expect(jobs.jobs.single.state, FetchState.cancelled);
        // A row already gone on the server stays gone.
        fake.actionError = FetchError.notFound;
        await during(const [], () => jobs.remove('run'));
        expect(shown, everyElement(isEmpty));
      },
    );

    test('a submit asked during a submit sends nothing and says so', () async {
      await jobs.probe('https://a.example');
      fake.submitGate = Completer<void>();
      fake.submitted = [fetchJob('n', FetchState.waiting)];
      final first = jobs.submit(['https://x.example/1']);
      await settle();
      expect(jobs.submitting, isTrue);
      final second = await jobs.submit(['https://x.example/2']);
      expect(second, isNotNull, reason: 'never mistaken for success');
      expect(second!.name, 'inProgress');
      expect(second.message, isNot(contains(RegExp(r'\d'))));
      expect(fake.calls.where((c) => c == 'submit').length, 1);
      fake.submitGate!.complete();
      expect(await first, isNull);
      expect(fake.lastSubmit!.urls, ['https://x.example/1']);
      expect(jobs.submitting, isFalse);
    });

    test('a refresh asked during a list lists once more after it', () async {
      fake.rows = [fetchJob('a', FetchState.done)];
      await jobs.probe('https://a.example');
      fake.listGate = Completer<void>();
      final first = jobs.refresh();
      final second = jobs.refresh();
      expect(jobs.refreshing, isTrue);
      fake.listGate!.complete();
      fake.listGate = null;
      await Future.wait([first, second]);
      expect(fake.calls.where((c) => c == 'list').length, 3);
      expect(jobs.refreshing, isFalse);
    });

    test('nothing is requested after dispose', () async {
      fake.rows = [fetchJob('a', FetchState.waiting)];
      await jobs.probe('https://a.example');
      jobs.setTabVisible(true);
      await settle();
      final timer = active().single;
      final other = make();
      jobs.dispose();
      jobs = other;
      timer.fire();
      await settle();
      expect(fake.calls.length, 2);
    });
  });

  group('remembered choice', () {
    late Directory profile;
    setUp(
      () => profile = Directory.systemTemp.createTempSync('anj-fetch-prefs-'),
    );
    tearDown(() => profile.deleteSync(recursive: true));

    test('kind and resolution persist beside the profile', () {
      final first = FetchPreferences(profile);
      expect(
        (first.kind, first.resolution),
        (FetchKind.audio, FetchResolution.p1080),
      );
      first.save(kind: FetchKind.video);
      first.save(resolution: FetchResolution.p720);
      final again = FetchPreferences(profile);
      expect(
        (again.kind, again.resolution),
        (FetchKind.video, FetchResolution.p720),
      );
      expect(
        jsonDecode(File('${profile.path}/downloader.json').readAsStringSync()),
        {'kind': 'video', 'height': 720},
      );
    });

    test('an unreadable or foreign file gives the defaults', () {
      final file = File('${profile.path}/downloader.json');
      for (final text in [
        'not json',
        '[]',
        '{"kind":"podcast","height":4320}',
      ]) {
        file.writeAsStringSync(text);
        final prefs = FetchPreferences(profile);
        expect(
          (prefs.kind, prefs.resolution),
          (FetchKind.audio, FetchResolution.p1080),
        );
      }
      FetchPreferences(profile).save(kind: FetchKind.video);
      expect(FetchPreferences(profile).kind, FetchKind.video);
    });

    test('the controller keeps them in its profile', () async {
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      try {
        controller.fetchJobs.setKind(FetchKind.video);
        expect(FetchPreferences(profile).kind, FetchKind.video);
        // No worker runs: nothing is sent, and the Downloader says why.
        expect(
          await controller.fetchJobs.submit(['https://x.example/1']),
          FetchError.notConnected,
        );
        await settle();
        expect(controller.fetchJobs.availability, FetchAvailability.unknown);
      } finally {
        controller.dispose();
      }
    });
  });

  group('link parser', () {
    test('lines are trimmed, blanks and duplicates dropped, http(s) only', () {
      final result = parseFetchLinks(
        '  https://media.example/v/1  \n'
        '\n'
        'http://media.example/v/2\r\n'
        'https://media.example/v/1\n'
        'ftp://media.example/file\n'
        'javascript:alert(1)\n'
        'media.example/no-scheme\n'
        'https://\n'
        'https://media.example/a b\n'
        '   \n'
        'HTTPS://Media.Example/v/3?list=x#t=1\n',
      );
      expect(result, isA<FetchLinksReady>());
      final ready = result as FetchLinksReady;
      expect(ready.links, [
        'https://media.example/v/1',
        'http://media.example/v/2',
        'HTTPS://Media.Example/v/3?list=x#t=1',
      ]);
      expect(ready.ignored, [
        'ftp://media.example/file',
        'javascript:alert(1)',
        'media.example/no-scheme',
        'https://',
        'https://media.example/a b',
      ]);
      final empty = parseFetchLinks(' \n\n') as FetchLinksReady;
      expect(empty.links, isEmpty);
      expect(empty.ignored, isEmpty);
    });

    test('at most 50 distinct links', () {
      String links(int n) =>
          [for (var i = 0; i < n; i++) 'https://media.example/$i'].join('\n');
      expect((parseFetchLinks(links(50)) as FetchLinksReady).links.length, 50);
      // Duplicates do not count towards the limit.
      expect(
        parseFetchLinks('${links(50)}\n${links(50)}'),
        isA<FetchLinksReady>(),
      );
      final tooMany = parseFetchLinks(links(51));
      expect(tooMany, isA<FetchLinksTooMany>());
      expect((tooMany as FetchLinksTooMany).count, 51);
      expect(tooMany.message, contains('50'));
    });
  });
}
