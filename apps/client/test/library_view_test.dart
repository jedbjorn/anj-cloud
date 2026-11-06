import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/ui/library_view.dart';

Map<String, dynamic> entry(
  String path, {
  String kind = 'file',
  String status = 'current local',
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': kind,
  'status': status,
  'effectiveRetention': 'local',
  ...extra,
};

void main() {
  test('badges prioritize conflict, attention, editing, pending, policy', () {
    final cloud = entry('a', extra: {'effectiveRetention': 'cloud'});
    expect(fileBadge(cloud), 'Cloud');
    expect(fileBadge(entry('a')), 'Local');
    expect(fileBadge({...cloud, 'status': 'uploading'}), 'Queued');
    expect(
      fileBadge({...cloud, 'status': 'queued', 'conflict': 'both changed'}),
      'Conflict',
    );
    final editing = {
      ...cloud,
      'status':
          'Cloud pending: editor working copies stay pinned in this prototype.',
      'workingCopies': [
        {'id': 'session'},
      ],
    };
    expect(fileBadge(editing), 'Editing');
    expect(needsAttention(editing), false);
    expect(fileBadge({...editing, 'syncPending': true}), 'Editing');
    expect(fileBadge({...editing, 'finishPending': true}), 'Editing');
  });
  test('attention distinguishes normal progress from decisions and errors', () {
    for (final status in [
      'queued',
      'uploading',
      'downloading',
      'current local',
      'cloud-only',
      'Cloud pending: pending work is retained.',
    ]) {
      expect(needsAttention(entry('a', status: status)), false, reason: status);
    }
    for (final status in [
      'pending: HTTP 403',
      'Working edit pending: changed',
      'Finish pending: file busy',
      'Cloud pending: original account/profile binding is unavailable.',
      'folder delete awaiting server proof',
    ]) {
      expect(needsAttention(entry('a', status: status)), true, reason: status);
    }
    for (final extra in [
      {'conflict': 'changed'},
      {'finishPending': true},
      {'hasRecovery': true},
      {
        'preservedCopies': ['retained'],
      },
      {
        'localArtifacts': {'uncertain': true},
      },
    ]) {
      expect(needsAttention(entry('a', extra: extra)), true);
    }
    expect(needsAttention(entry('a', kind: 'unsupported')), true);
  });
  test(
    'collapsed folders retain full-data attention with segment boundaries',
    () {
      final entries = [
        entry('a/b/c.txt', extra: {'conflict': 'changed'}),
        entry('ab/ok.txt'),
      ];
      final rows = libraryRows(entries, LibraryTab.home, {'a', 'ab'});
      expect(rows.map((r) => r.path), ['a', 'ab']);
      expect(rows.first.attention, true);
      expect(rows.last.attention, false);
      final refreshed = libraryRows(
        [entry('a/b/c.txt'), entry('ab/ok.txt')],
        LibraryTab.home,
        {'a', 'ab'},
      );
      expect(refreshed.every((r) => !r.attention), true);
    },
  );
  test(
    'filtered tabs preserve sparse ancestry, exact matching and pending finish',
    () {
      final entries = [
        entry(
          'a/b/edit.txt',
          extra: {
            'workingCopies': [
              {'id': 's'},
            ],
          },
        ),
        entry('a/b/partial.txt', extra: {'finishPending': true}),
        entry('a/conflict.txt', extra: {'conflict': 'changed'}),
        entry('ab/ordinary.txt'),
      ];
      final editing = libraryRows(entries, LibraryTab.editing, {});
      expect(editing.map((r) => r.path), [
        'a',
        'a/b',
        'a/b/edit.txt',
        'a/b/partial.txt',
      ]);
      expect(editing.take(2).every((r) => r.contextOnly), true);
      final conflicts = libraryRows(entries, LibraryTab.conflict, {});
      expect(conflicts.map((r) => r.path), ['a', 'a/conflict.txt']);
      expect(
        libraryRows(entries, LibraryTab.editing, {'a/b'}).map((r) => r.path),
        ['a', 'a/b'],
      );
    },
  );
  test('search bypasses the chip and reveals stored collapsed paths', () {
    final entries = [
      entry('Documents', kind: 'directory'),
      entry('Documents/deep', kind: 'directory'),
      entry('Documents/deep/Cloud.txt', extra: {'effectiveRetention': 'cloud'}),
      entry('Documents/deep/local.txt'),
      entry(
        'Documents/deep/pending.txt',
        status: 'queued',
        extra: {'effectiveRetention': 'cloud'},
      ),
      entry('Elsewhere/Cloud.txt'),
    ];
    final collapsed = {'Documents', 'Documents/deep'};
    final rows = libraryRows(
      entries,
      LibraryTab.home,
      collapsed,
      policy: LibraryPolicy.cloud,
      search: 'DOCUMENTS/DEEP',
    );
    // Search bypasses every chip (decision #56): the Local file matches too.
    expect(rows.map((r) => r.path), [
      'Documents/deep/Cloud.txt',
      'Documents/deep/local.txt',
      'Documents/deep/pending.txt',
    ]);
    expect(rows.every((r) => !r.contextOnly && !r.directory), true);
    expect(fileBadge(rows.last.entry), 'Queued');
    expect(collapsed, {'Documents', 'Documents/deep'});
    expect(
      libraryRows(entries, LibraryTab.home, collapsed).map((r) => r.path),
      ['Documents', 'Elsewhere', 'Elsewhere/Cloud.txt'],
    );
    expect(
      libraryRows(
        entries,
        LibraryTab.home,
        {},
        search: 'CLOUD.TXT',
      ).where((r) => !r.contextOnly).map((r) => r.path),
      ['Documents/deep/Cloud.txt', 'Elsewhere/Cloud.txt'],
    );
  });
  test('search under a chip returns every matching file', () {
    final entries = [
      entry(
        'Cloud folder',
        kind: 'directory',
        extra: {'effectiveRetention': 'cloud'},
      ),
      entry('Cloud folder/cloud.txt', extra: {'effectiveRetention': 'cloud'}),
      entry('Cloud folder/local.txt'),
    ];
    final rows = libraryRows(
      entries,
      LibraryTab.home,
      {'Cloud folder'},
      policy: LibraryPolicy.cloud,
      search: 'cloud FOLDER',
    );
    expect(rows.map((r) => r.path), [
      'Cloud folder/cloud.txt',
      'Cloud folder/local.txt',
    ]);
    expect(rows.every((r) => !r.contextOnly), true);
  });
  test('policy intersects Editing and Conflict independently of badge', () {
    final entries = [
      entry(
        'folder/queued-cloud',
        status: 'queued',
        extra: {'effectiveRetention': 'cloud', 'finishPending': true},
      ),
      entry('folder/conflict-local', extra: {'conflict': 'changed'}),
      entry(
        'folder/conflict-cloud',
        extra: {'effectiveRetention': 'cloud', 'conflict': 'changed'},
      ),
    ];
    expect(
      libraryRows(entries, LibraryTab.editing, {
        'folder',
      }, policy: LibraryPolicy.cloud).map((r) => r.path),
      ['folder', 'folder/queued-cloud'],
    );
    expect(
      libraryRows(
        entries,
        LibraryTab.conflict,
        {'folder'},
        policy: LibraryPolicy.cloud,
        search: 'conflict',
      ).map((r) => r.path),
      // The tab still applies to search; the chip does not.
      ['folder/conflict-cloud', 'folder/conflict-local'],
    );
    expect(
      libraryRows(
        entries,
        LibraryTab.conflict,
        {},
        policy: LibraryPolicy.local,
        search: 'no match',
      ),
      isEmpty,
    );
  });
  test('text search excludes directory-only matches and unsupported rows', () {
    final entries = [
      entry('empty-match', kind: 'directory'),
      entry('match-folder', kind: 'directory'),
      entry('match-folder/same.txt'),
      entry('other/same.txt'),
      entry('match-link', kind: 'unsupported'),
    ];
    expect(
      libraryRows(entries, LibraryTab.home, {}, search: ' empty-match '),
      isEmpty,
    );
    expect(
      libraryRows(entries, LibraryTab.home, {
        'match-folder',
      }, search: ' MATCH ').map((row) => row.path),
      ['match-folder/same.txt'],
    );
    expect(
      libraryRows(
        entries,
        LibraryTab.home,
        {},
        search: 'same.txt',
      ).map((row) => row.path),
      ['match-folder/same.txt', 'other/same.txt'],
    );
    expect(
      libraryRows(entries, LibraryTab.home, {
        'match-folder',
      }, search: '   ').map((row) => row.path),
      ['empty-match', 'match-folder', 'other', 'other/same.txt', 'match-link'],
    );
  });
  test('type-conflicted ancestor never hides matching descendants', () {
    final entries = [
      entry('a', extra: {'conflict': 'file versus directory'}),
      entry('a/b/edit.txt', extra: {'finishPending': true}),
    ];
    expect(libraryRows(entries, LibraryTab.editing, {}).map((r) => r.path), [
      'a',
      'a/b',
      'a/b/edit.txt',
    ]);
  });
  test(
    'completed tombstones disappear while pending and recoverable rows remain',
    () {
      final entries = [
        entry('deleted.txt', status: 'deleted'),
        entry('remote.txt', status: 'deleted remotely'),
        entry(
          'queued.txt',
          status: 'delete queued',
          extra: {'syncPending': true},
        ),
        entry('recovery.txt', status: 'deleted', extra: {'hasRecovery': true}),
        entry('edit.txt', status: 'deleted', extra: {'finishPending': true}),
      ];
      expect(libraryRows(entries, LibraryTab.home, {}).map((r) => r.path), [
        'edit.txt',
        'queued.txt',
        'recovery.txt',
      ]);
    },
  );
  test('terminal deletions are never Queued; retained copies read Recovery copy', () {
    for (final status in ['deleted', 'deleted remotely', 'removed locally']) {
      final done = entry('a/$status.txt', status: status);
      expect(hasQueuedWork(done), isFalse, reason: status);
      expect(fileBadge(done), 'Local', reason: status);
      expect(visibleInLibrary(done), isFalse, reason: status);
      final kept = entry(
        'a/$status.txt',
        status: status,
        extra: {
          'hasRecovery': true,
          'preservedCopies': ['/private/preserved-1'],
        },
      );
      expect(fileBadge(kept), 'Recovery copy', reason: status);
      expect(hasQueuedWork(kept), isFalse, reason: status);
      // A retained copy is content that now exists only on this device.
      expect(fileBadge({...kept, 'conflict': 'late edit'}), 'Recovery copy');
      final rows = libraryRows([kept], LibraryTab.home, {});
      expect(rows.map((r) => r.path), ['a', 'a/$status.txt']);
      expect(rows.every((r) => r.attention), isTrue);
      // A deletion still being dispatched is not yet terminal, but its
      // retained copy keeps the amber bar, and the badge agrees.
      expect(fileBadge({...kept, 'syncPending': true}), 'Needs attention');
    }
    expect(fileBadge(entry('q', status: 'delete queued')), 'Queued');
  });
  test('artifact summary lists kinds and states deduplicated bytes', () {
    expect(artifactSummary(entry('none')), isNull);
    expect(
      artifactSummary(
        entry(
          'x',
          extra: {
            'localArtifacts': {
              'count': 4,
              'bytes': 90,
              'kinds': {'download': 2, 'recovery': 1, 'check': 1},
            },
          },
        ),
      ),
      'Local staging files: recovery 1, download 2, check 1 (90 bytes)',
    );
    expect(
      librarySummary(
        entry(
          'y',
          status: 'deleted',
          extra: {
            'localArtifacts': {
              'count': 1,
              'bytes': 40,
              'uncertain': true,
              'kinds': {'upload': 1},
            },
          },
        ),
      ),
      'deleted\nLocal staging files: upload 1 (40 bytes, some uncertain)',
    );
  });
}
