import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/local/root_tree.dart';
import '../../core/ports/desktop_launcher.dart';
import '../native/native_root_fs.dart';

typedef UriLauncher = Future<bool> Function(Uri uri);

class PlatformDesktopLauncher implements DesktopLauncher {
  PlatformDesktopLauncher({
    UriLauncher? launch,
    bool? directorySupported,
    this.nativeLibrary,
    this.errnoLabel = 'Linux errno',
  }) : _launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _directorySupported = directorySupported ?? Platform.isLinux;
  final UriLauncher _launch;
  final bool _directorySupported;
  final String? nativeLibrary;

  /// The platform's errno label in refusals ('macOS errno' on macOS).
  final String errnoLabel;

  @override
  Future<bool> openFile(String path) => _launch(Uri.file(path));

  /// The working copy's path goes to the OS: its opens are not tracked.
  @override
  bool get handsOutThroughProvider => false;

  @override
  Future<bool> openDirectory(
    String root,
    String relative,
    String rootIdentity,
  ) async {
    if (!_directorySupported) {
      throw UnsupportedError(
        'Folder opening is currently qualified on Linux only.',
      );
    }
    validateRelative(relative);
    final fs = NativeRootFs(nativeLibrary, errnoLabel);
    final rootFd = fs.openRoot(root);
    final path = p.join(root, relative);
    try {
      if (fs.identity(rootFd) != rootIdentity) {
        throw const FileSystemException('Root identity changed.');
      }
      final directoryFd = fs.openRoot(path); // No symlinks in any component.
      try {
        fs.checkRoot(rootFd, root);
      } finally {
        fs.closeFd(directoryFd);
      }
    } finally {
      fs.closeFd(rootFd);
    }
    // No materialization or retention command. The OS owns later navigation.
    return _launch(Uri.directory(path));
  }
}
