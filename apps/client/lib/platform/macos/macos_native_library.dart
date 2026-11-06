import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the macOS app loads libanj_rootfs.dylib: `Contents/Frameworks/`
/// of its own bundle, where the Runner's Xcode build phase put it before
/// signing (tool/macos/build_native.sh).
///
/// Unlike Linux, no environment variable redirects it: the app runs with
/// the hardened runtime so that same-user code insertion is refused, and a
/// Dart-level override would reopen that. Tests pass the path explicitly.
String macosNativeLibraryPath({String? executable}) => p.join(
  p.dirname(p.dirname(executable ?? Platform.resolvedExecutable)),
  'Frameworks',
  'libanj_rootfs.dylib',
);

DynamicLibrary openMacosNativeLibrary([String? library]) =>
    DynamicLibrary.open(library ?? macosNativeLibraryPath());
