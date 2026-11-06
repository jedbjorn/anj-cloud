/// Logical decoded relative names, before any future wire-name transformation.
/// An excluded directory also excludes its descendants; other dotdirectories
/// remain normal synchronized content. This is deliberately not a glob system.
const _kateRecoverySuffixes = ['.kate.swp', '.kate-swp'];

bool _isKateRecovery(String name) =>
    name.startsWith('.') &&
    _kateRecoverySuffixes.any(
      (suffix) => name.endsWith(suffix) && name.length > suffix.length + 1,
    );

/// Exact, case-sensitive names the operating systems create (decision #21;
/// the macOS names from spec #31 "Root and Storage").
const _metadataNames = {
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
  // macOS: Finder's custom folder icon ("Icon" + carriage return), localized
  // folder names, per-volume temporary items, trash, FSEvents log, Spotlight
  // index and document versions.
  'Icon\r',
  '.localized',
  '.TemporaryItems',
  '.Trashes',
  '.fseventsd',
  '.Spotlight-V100',
  '.DocumentRevisions-V100',
};

/// Prefixes followed by at least one character: AppleDouble companions
/// (`._<name>`, extended attributes and resource forks written by macOS on
/// volumes without native support) and Microsoft Office owner files
/// (`~$<name>`, the lock file beside an open document).
const _metadataPrefixes = ['._', r'~$'];

bool _isMetadataPrefixed(String name) => _metadataPrefixes.any(
  (prefix) => name.startsWith(prefix) && name.length > prefix.length,
);

/// The empty folder the app moves into the root for an instant to learn
/// whether staging reaches it by rename (spec #34 P3, `RootTree.stagingFor`).
/// Only at the top of the root, and only this exact shape; never synced, so
/// one left behind by a crash is not uploaded (and setup removes it).
final stagingProbeName = RegExp(r'^\.anj-cloud-probe-[0-9a-f]{32}$');

bool isSyncExcluded(String relative) =>
    stagingProbeName.hasMatch(relative.split('/').first) ||
    relative
        .split('/')
        .any(
          (name) =>
              _metadataNames.contains(name) ||
              _isMetadataPrefixed(name) ||
              _isKateRecovery(name),
        );
