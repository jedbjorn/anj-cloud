// Spec #28 A5, decision #127: "Apps with access" approves an app for a
// folder, guides the add-folder step, shows live status and revokes per app
// and folder (widget tests on the VM host, phone size).
import 'package:anj_cloud/core/ports/documents.dart';
import 'package:anj_cloud/ui/apps_access_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAccess extends ChangeNotifier implements AppAccess {
  final rows = <AppApproval>[];
  @override
  List<AccessRequest> requests = [];
  final opened = <String>[];
  final revoked = <(String, String)>[];
  @override
  List<AppApproval> get approvals => rows;
  @override
  List<String> get folders => const ['', 'Music', 'Music/Album', 'Videos'];
  @override
  Future<List<InstalledApp>> installedApps() async => const [
    InstalledApp('org.resonus', 'Resonus'),
    InstalledApp('is.xyz.mpv', 'mpv'),
  ];
  @override
  Future<Map<String, InstalledApp>> describe(Iterable<String> packages) async =>
      {
        for (final p in packages)
          p: InstalledApp(p, p == 'org.resonus' ? 'Resonus' : p),
      };
  @override
  Future<void> approve(String package, String folder, AccessMode mode) async {
    rows.removeWhere((r) => r.package == package && r.folder == folder);
    rows.add(
      AppApproval(
        package: package,
        folder: folder,
        mode: mode,
        status: ApprovalStatus.approved,
        approvedAt: DateTime(2026, 11, 4),
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> revoke(String package, String folder) async {
    revoked.add((package, folder));
    final i = rows.indexWhere(
      (r) => r.package == package && r.folder == folder,
    );
    final r = rows[i];
    rows[i] = AppApproval(
      package: r.package,
      folder: r.folder,
      mode: r.mode,
      status: ApprovalStatus.revoked,
      approvedAt: r.approvedAt,
      openFiles: 1,
    );
    notifyListeners();
  }

  @override
  Future<void> forget(String package, String folder) async {
    rows.removeWhere((r) => r.package == package && r.folder == folder);
    requests.removeWhere((r) => r.package == package && r.folder == folder);
    notifyListeners();
  }

  @override
  Future<bool> openApp(String package) async {
    opened.add(package);
    return true;
  }

  List<FileGrant> files = [];
  final revokedFiles = <String>[];
  @override
  Future<List<FileGrant>> fileGrants() async => files;
  @override
  Future<void> revokeFile(String documentId) async {
    revokedFiles.add(documentId);
    files = [
      for (final f in files)
        if (f.documentId != documentId) f,
    ];
    notifyListeners();
  }
}

void main() {
  Future<void> pump(WidgetTester tester, FakeAccess access) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AppsAccessPage(access: access)));
    await tester.pumpAndSettle();
  }

  testWidgets('default: no app has access', (tester) async {
    await pump(tester, FakeAccess());
    expect(find.text('No app has access.'), findsOneWidget);
  });

  testWidgets('single files an app kept are listed and revoked (review M2)', (
    tester,
  ) async {
    final access = FakeAccess()
      ..files = [
        const FileGrant(
          documentId: 'n:7',
          name: 'Music/loose.flac',
          holders: 2,
          write: false,
          packages: ['org.resonus'],
        ),
        const FileGrant(
          documentId: 'n:8',
          name: 'Documents/notes.md',
          holders: 1,
          write: true,
        ),
      ];
    await pump(tester, access);
    expect(find.text('No app has access.'), findsOneWidget);
    expect(find.text('Single files'), findsOneWidget);
    final first = find.byKey(const ValueKey('file-grant-n:7'));
    await tester.scrollUntilVisible(first, 100);
    expect(
      find.descendant(
        of: first,
        matching: find.text('Read only · Kept by Resonus and another app'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Read and write · Kept by an app'),
      findsOneWidget,
      reason: 'a grant no app has used yet is still listed',
    );
    await tester.tap(find.byKey(const ValueKey('revoke-file-n:7')));
    await tester.pumpAndSettle();
    expect(find.text('Revoke access to Music/loose.flac?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-revoke-file')));
    await tester.pumpAndSettle();
    expect(access.revokedFiles, ['n:7']);
    expect(find.byKey(const ValueKey('file-grant-n:7')), findsNothing);
    expect(find.byKey(const ValueKey('file-grant-n:8')), findsOneWidget);
  });

  testWidgets('no kept files: no Single files section', (tester) async {
    await pump(tester, FakeAccess());
    expect(find.text('Single files'), findsNothing);
  });

  testWidgets('approve an app for a folder, then add it in the app', (
    tester,
  ) async {
    final access = FakeAccess();
    await pump(tester, access);
    await tester.tap(find.byKey(const ValueKey('approve-app')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('approve-confirm')))
          .onPressed,
      isNull,
      reason: 'nothing chosen yet',
    );
    await tester.tap(find.byKey(const ValueKey('app-org.resonus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-Music')));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mode-write')),
      100,
    );
    await tester.tap(find.byKey(const ValueKey('mode-write')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approve-confirm')));
    await tester.pumpAndSettle();
    expect(access.rows.single.package, 'org.resonus');
    expect(access.rows.single.folder, 'Music');
    expect(access.rows.single.mode, AccessMode.write);
    // The add-folder guidance names the app and the folder.
    expect(
      find.textContaining('In Resonus, choose its add-folder option'),
      findsOneWidget,
    );
    expect(find.textContaining('open Music'), findsOneWidget);
    await tester.tap(find.text('Open Resonus'));
    await tester.pumpAndSettle();
    expect(access.opened, ['org.resonus']);
    expect(
      find.textContaining('Approved: add the folder in the app'),
      findsOneWidget,
    );
    expect(find.textContaining('Music · Read and write'), findsOneWidget);
  });

  testWidgets(
    'revoke names the app and folder, then shows revoked and open files',
    (tester) async {
      final access = FakeAccess();
      await access.approve('org.resonus', 'Music', AccessMode.read);
      await access.approve('is.xyz.mpv', 'Videos', AccessMode.read);
      await pump(tester, access);
      await tester.tap(find.byKey(const ValueKey('revoke-org.resonus-Music')));
      await tester.pumpAndSettle();
      expect(find.text('Revoke Resonus?'), findsOneWidget);
      expect(
        find.textContaining('Other apps keep their access'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('confirm-revoke')));
      await tester.pumpAndSettle();
      expect(access.revoked, [('org.resonus', 'Music')]);
      expect(
        find.textContaining('Revoked · 1 file still open'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('revoke-is.xyz.mpv-Videos')),
        findsOneWidget,
      );
      expect(find.text('Approve again'), findsOneWidget);
      // The revoke button is announced with its app and folder.
      final semantics = tester.ensureSemantics();
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Revoke is.xyz.mpv for Videos'),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets('an app that asked can be approved from its request', (
    tester,
  ) async {
    final access = FakeAccess()
      ..requests = [
        AccessRequest('org.resonus', 'Music', DateTime(2026, 11, 4)),
      ];
    await pump(tester, access);
    expect(find.text('Tried to open Music'), findsOneWidget);
    await tester.tap(find.text('Approve').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approve-confirm')));
    await tester.pumpAndSettle();
    expect(access.rows.single.folder, 'Music');
    expect(access.rows.single.mode, AccessMode.read);
  });
}
