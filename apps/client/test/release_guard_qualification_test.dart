// Cloud release under the platform's release guard, end to end through the
// engine (spec #31 acceptance row 7, unit M4; decision #126).
//
// Shared: on the VM host it runs over the Linux lease (libanj_rootfs.so), on
// mac-test over the busy-and-unchanged guard (the Darwin dylib named by
// ANJ_MACOS_ROOTFS_LIBRARY or ANJ_ROOTFS_LIBRARY; tool/macos/check_m4.sh).
// The same holders refuse a release on both: a descriptor in this process,
// a shared mapping whose descriptor is closed, and a descriptor held only by
// a child process. A write between the hash and the unlink fails the release
// and keeps the written bytes recoverable. A clean release frees the bytes
// and leaves the remote copy unchanged.
//
// Where the guards differ, each test states what its strength promises:
// only busyAndUnchanged lets an open that starts inside the window succeed
// (it is caught by the busy check, or not at all when it closes in time),
// which is why that guard is the weaker one (decision #42).
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/release_guard.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import '../tool/eviction_fixture.dart' show ownedAllocated;
import 'fakes.dart';

// Inside a folder of Documents: the top folders themselves never go
// Cloud-only (spec #34 P7).
const _path = 'Documents/Guard/blob.bin';

RootFilesystem _rootFilesystem() {
  if (!Platform.isMacOS) return NativeRootFs();
  final library =
      Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'] ??
      Platform.environment['ANJ_ROOTFS_LIBRARY'];
  if (library == null) {
    throw StateError('Set ANJ_MACOS_ROOTFS_LIBRARY to the Darwin dylib');
  }
  return const MacosPlatformAdapters().rootFilesystem(library);
}

/// A read-only shared mapping of a file whose descriptor is already closed.
class _Mapping {
  _Mapping(String path) {
    final name = path.toNativeUtf8();
    try {
      final fd = _open(name, 0); // O_RDONLY
      if (fd < 0) throw StateError('open failed');
      length = File(path).lengthSync();
      // PROT_READ = 1, MAP_SHARED = 1 on Linux and Darwin.
      address = _mmap(nullptr, length, 1, 1, fd, 0);
      _close(fd);
      if (address.address == -1) throw StateError('mmap failed');
      expect(address.cast<Uint8>()[0], isNonNegative); // touch a page
    } finally {
      calloc.free(name);
    }
  }
  late final int length;
  late final Pointer<Void> address;
  void release() => expect(_munmap(address, length), 0);

  static final _libc = DynamicLibrary.process();
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _mmap = _libc
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          IntPtr,
          Int32,
          Int32,
          Int32,
          Int64,
        ),
        Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
      >('mmap');
  static final _munmap = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>, IntPtr),
        int Function(Pointer<Void>, int)
      >('munmap');
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  late List<int> original;

  setUp(() {
    // Canonical: macOS's temporary directory sits under a symlink.
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-guard-q-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'guard-q', _rootFilesystem());
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local() => File('${tree.root.path}/$_path');
  String remoteHash() => sha256.convert(cloud.files[_path]!).toString();
  Entry entry() => store.entries[_path]!;

  /// A synced Local file, then its folder set to Cloud: the next pass
  /// releases it.
  Future<String> baseline() async {
    final random = Random(126);
    original = List.generate(256 * 1024, (_) => random.nextInt(256));
    local().parent.createSync(recursive: true);
    local().writeAsBytesSync(original, flush: true);
    await engine.tick();
    expect(cloud.files[_path], original);
    engine.setRetention('Documents/Guard', Retention.cloud);
    return remoteHash();
  }

  /// The release completed: no local bytes left, remote copy unchanged.
  void expectReleased(String hash) {
    expect(local().existsSync(), isFalse);
    expect(entry().status, 'cloud-only');
    expect(ownedAllocated(tree), 0);
    expect(remoteHash(), hash);
    expect(cloud.deletes, 0);
    expect(store.operations.values.where((o) => o.kind == 'evict'), isEmpty);
  }

  /// The release was refused: the bytes are still at their path.
  void expectRefusedInPlace(String hash) {
    expect(local().readAsBytesSync(), original);
    expect(entry().status, contains('pending'));
    expect(remoteHash(), hash);
    expect(cloud.deletes, 0);
  }

  test('the guard reports its strength (decision #126)', () {
    expect(
      tree.native.releaseGuard().strength,
      Platform.isMacOS
          ? ReleaseGuardStrength.busyAndUnchanged
          : ReleaseGuardStrength.lease,
    );
  });

  test(
    'a clean release frees the bytes and leaves the remote hash unchanged',
    () async {
      final hash = await baseline();
      expect(ownedAllocated(tree), greaterThan(0));
      await engine.tick();
      expectReleased(hash);
      await engine.tick();
      expectReleased(hash);
    },
  );

  test(
    'a descriptor in this process refuses the release until closed',
    () async {
      final hash = await baseline();
      final held = local().openSync();
      try {
        await engine.tick();
        expectRefusedInPlace(hash);
        await engine.tick();
        expectRefusedInPlace(hash);
      } finally {
        held.closeSync();
      }
      await engine.tick();
      expectReleased(hash);
    },
  );

  test(
    'a shared mapping refuses the release after its descriptor closed',
    () async {
      final hash = await baseline();
      final mapping = _Mapping(local().path);
      try {
        await engine.tick();
        expectRefusedInPlace(hash);
      } finally {
        mapping.release();
      }
      await engine.tick();
      expectReleased(hash);
    },
  );

  test(
    'a descriptor held only by a child process refuses the release',
    () async {
      final hash = await baseline();
      final child = await Process.start('/bin/sh', [
        '-c',
        r'exec 3<"$1"; echo ready; exec sleep 120',
        'sh',
        local().path,
      ]);
      final lines = child.stdout.transform(const SystemEncoding().decoder);
      try {
        expect(
          (await lines.first.timeout(const Duration(seconds: 10))).trim(),
          'ready',
        );
        await engine.tick();
        expectRefusedInPlace(hash);
      } finally {
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 10));
      }
      await engine.tick();
      expectReleased(hash);
    },
  );

  test('a write between the hash and the unlink fails the release and keeps the written bytes', () async {
    final hash = await baseline();
    final trigger = File('${fixture.path}/trigger');
    // Waits for the trigger, then truncates and writes the named file
    // (under the Linux lease the open waits for the lease break).
    final child = await Process.start('/bin/sh', [
      '-c',
      r'while [ ! -s "$1" ]; do sleep 0.01; done; printf "raced writer bytes" > "$(cat "$1")"',
      'sh',
      trigger.path,
    ]);
    var broken = false;
    engine.evictions.barrier = (point, op, fd) {
      if (point != 'before-final-unlink') return;
      trigger.writeAsStringSync(op.staged!);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        try {
          engine.artifacts.native.valid(fd);
        } on FileSystemException {
          broken = true;
          break;
        }
        sleep(const Duration(milliseconds: 1));
      }
      if (!broken) throw StateError('The write did not invalidate the guard.');
    };
    await engine.tick();
    engine.evictions.barrier = null;
    expect(broken, isTrue);
    expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0);
    await engine.tick();
    expect(entry().conflict, isNotNull);
    expect(
      entry().preservedCopies.map((path) => File(path).readAsStringSync()),
      contains('raced writer bytes'),
    );
    expect(await engine.canRecoverLocalVariants(_path), isTrue);
    expect(remoteHash(), hash);
    expect(cloud.deletes, 0);
  });

  group('opens that start inside the window', () {
    final strongGuard = !Platform.isMacOS; // the Linux lease
    const why =
        'Under the Linux lease an open inside the window waits for the lease '
        'break (eviction_test covers that race with a child writer).';

    test('a descriptor opened before the quarantine refuses it; the file stays in place', () async {
      final hash = await baseline();
      RandomAccessFile? late;
      engine.evictions.barrier = (point, op, fd) {
        if (point == 'before-quarantine') late ??= local().openSync();
      };
      try {
        await engine.tick();
        expect(late, isNotNull);
        expectRefusedInPlace(hash);
      } finally {
        engine.evictions.barrier = null;
        late?.closeSync();
      }
      await engine.tick();
      expectReleased(hash);
    }, skip: strongGuard ? why : false);

    test('a descriptor opened after the quarantine fails the unlink; the bytes wait in staging', () async {
      final hash = await baseline();
      RandomAccessFile? late;
      String? staged;
      engine.evictions.barrier = (point, op, fd) {
        if (point != 'before-final-unlink') return;
        staged = op.staged;
        late ??= File(op.staged!).openSync();
      };
      try {
        await engine.tick();
        expect(late, isNotNull);
        // Refused by AT_NODELETEBUSY. The engine keeps the quarantined
        // bytes (remote-verified) and retries; it does not move them back.
        expect(entry().status, contains('pending'));
        expect(local().existsSync(), isFalse);
        expect(File(staged!).readAsBytesSync(), original);
        await engine.tick();
        expect(entry().status, contains('pending'));
        expect(File(staged!).readAsBytesSync(), original);
      } finally {
        engine.evictions.barrier = null;
        late?.closeSync();
      }
      await engine.tick();
      expectReleased(hash);
    }, skip: strongGuard ? why : false);

    test(
      'WEAKER: an open, read and close inside the window is not seen',
      () async {
        final hash = await baseline();
        var read = false;
        engine.evictions.barrier = (point, op, fd) {
          if (point != 'before-final-unlink') return;
          expect(File(op.staged!).readAsBytesSync(), original);
          read = true;
        };
        await engine.tick();
        engine.evictions.barrier = null;
        expect(read, isTrue);
        // The reader saw verified bytes; the release went through.
        expectReleased(hash);
      },
      skip: strongGuard ? why : false,
    );
  });
}
