// Shared fixtures for the layout tests (spec #28 A6): one paired admin
// controller with a library that exercises every row kind, the first-sync
// listing, and real Roboto for readable previews when ANJ_UI_FONT_DIR is set.
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/pairing_inputs.dart';
import 'package:anj_cloud/core/gateway/admin_api.dart';
import 'package:anj_cloud/core/sync/first_sync.dart';
import 'package:flutter/services.dart';

import 'fakes.dart';

class LayoutController extends ClientController {
  LayoutController({super.pairingOptions})
    : super(Directory('/unused-layout'), secrets: MemorySecrets());
  final commands = <String>[];

  /// Admin requests go here (a FakeAdmin), never to a worker.
  AdminCall? adminCall;

  @override
  Future<AdminResponse> admin(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = await adminCall!(method, path, body: body);
    if (response.status == 403 && response.map['error'] == 'not-admin') {
      adminRoleRemoved();
    }
    return response;
  }

  @override
  bool get canCreateFolder => true;

  /// Icon colours chosen in the UI (the real store needs a profile).
  final colours = <String, int?>{};

  @override
  void setIconColor(String path, int? color) => colours[path] = color;

  @override
  void command(
    String action,
    String path, {
    String? value,
    List<Map<String, dynamic>>? sessions,
  }) => commands.add('$action:$path');

  @override
  Future<FirstSyncListing> firstSyncListing() async => const FirstSyncListing(
    choices: [
      FirstSyncChoice(
        path: 'Documents/Tax returns',
        size: 3 * 1024 * 1024 * 1024,
        top: 'Documents',
      ),
      FirstSyncChoice(
        path: 'Documents',
        size: 4096,
        top: 'Documents',
        files: 2,
      ),
      FirstSyncChoice(
        path: 'Music/Albums from the long summer holiday',
        size: 48 * 1024 * 1024 * 1024,
        top: 'Music',
      ),
      FirstSyncChoice(path: 'Photos', size: 12 * 1024 * 1024),
      FirstSyncChoice(path: 'Shared', size: null),
    ],
    tops: ['Documents', 'Music', 'Videos'],
    rootFiles: 2,
    rootFilesSize: 4096,
  );

  @override
  Future<void> confirmFirstSync(
    Iterable<String> folders,
    Set<String> keepLocal,
  ) async {}
}

Map<String, dynamic> _row(
  String path, {
  String kind = 'file',
  String policy = 'local',
  String status = 'current local',
  Map<String, dynamic> extra = const {},
}) => {
  'path': path,
  'kind': kind,
  'effectiveRetention': policy,
  'status': status,
  'selectionVersion': '1',
  ...extra,
};

/// A paired admin with folders, a shared folder, a syncing file, an editor
/// session and a conflict.
LayoutController layoutController({
  bool admin = true,
  PairingOptions pairingOptions = PairingOptions.desktop,
}) {
  final controller = LayoutController(pairingOptions: pairingOptions)
    ..root = '/home/demo/anj-cloud'
    ..pairingState = 'paired'
    ..accountRights = 'write'
    ..isAdmin = admin
    ..message = 'Up to date · last checked 10:42'
    ..entries = [
      _row('Documents', kind: 'directory'),
      _row('Documents/Tax return 2026 final version.pdf'),
      _row(
        'Music',
        kind: 'directory',
        policy: 'cloud',
        extra: {
          'sharedOut': true,
          'sharedWith': ['Alex'],
        },
      ),
      _row('Music/Album/track01.flac', policy: 'cloud'),
      _row('Photos', kind: 'directory'),
      _row('Photos/beach.jpg', status: 'uploading'),
      _row(
        'notes.txt',
        status: 'working copy synchronized',
        extra: {
          'workingCopies': [
            {'id': 'session-1', 'path': '/tmp/notes.txt', 'size': 120},
          ],
        },
      ),
      _row(
        'budget.ods',
        status: 'conflict',
        extra: {
          'conflict': 'Changed here and in the cloud; both versions are kept.',
          'canRecoverLocalVariants': true,
          'expectedPresent': true,
        },
      ),
    ];
  controller.syncing = {'Photos/beach.jpg'};
  return controller;
}

/// Loads Roboto and the Material icons from ANJ_UI_FONT_DIR (the pinned SDK's
/// material_fonts) so rendered previews are readable; a no-op without it.
Future<void> loadPreviewFonts() async {
  final fonts = Platform.environment['ANJ_UI_FONT_DIR'];
  if (fonts == null) return;
  for (final font in {
    'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  }.entries) {
    final loader = FontLoader(font.key);
    for (final file in font.value) {
      final path = File('$fonts/$file');
      if (!path.existsSync()) continue;
      loader.addFont(
        path.readAsBytes().then((bytes) => bytes.buffer.asByteData()),
      );
    }
    await loader.load();
  }
}
