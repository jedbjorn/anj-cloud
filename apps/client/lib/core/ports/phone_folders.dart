/// Port: phone folders (spec #52, decisions #201 and #202). On Android the
/// cloud top folders Music, Videos and Documents live in the phone's own
/// `Music`, `Movies` and `Documents` folders in shared storage, while the
/// rest of the root stays app-private.
///
/// The engine keeps one root: its paths still start with `Music`, `Videos`
/// and `Documents`. A [RootFilesystem] that implements [PhoneFolderRouting]
/// resolves those three top folders in shared storage instead of the private
/// root, and keeps a second staging folder there, so a download still
/// appears by an atomic same-volume rename. Staging names carry
/// [sharedStagingTag] when their bytes belong to a phone folder. No other
/// platform implements this port; shared code checks for it.
library;

/// The fixed mapping, computed rather than stored (spec #52 Folder Mapping):
/// engine top folder -> folder name in shared storage.
const phoneFolderNames = {
  'Music': 'Music',
  'Videos': 'Movies',
  'Documents': 'Documents',
};

/// Staging names whose bytes live in the shared-storage staging folder.
const sharedStagingTag = 'phone-';

/// Where the phone folders are: [base] is the shared storage volume
/// (`/storage/emulated/0`), [staging] the shared-storage staging folder
/// (`<base>/Android/media/<package>/anj-staging`, removed with the app).
/// [paused]: All files access is missing or shared storage is unavailable;
/// the three folders are then neither listed nor touched (spec #52
/// Permission and Paused States).
class PhoneFolderLayout {
  const PhoneFolderLayout({
    required this.base,
    required this.staging,
    required this.paused,
  });

  final String base;
  final String staging;
  final bool paused;

  /// The layout this isolate's root filesystem maps: the sync worker sets it
  /// from its start message before it opens the root, and the Android
  /// adapter then returns a [PhoneFolderRouting] filesystem. Null elsewhere
  /// (every other platform, the UI isolate, tests that do not map).
  static PhoneFolderLayout? active;

  /// The absolute phone path of the engine top folder [top].
  String folder(String top) => '$base/${phoneFolderNames[top]}';

  Map<String, Object?> toJson() => {
    'base': base,
    'staging': staging,
    'paused': paused,
  };

  static PhoneFolderLayout? fromJson(Object? value) {
    if (value is! Map) return null;
    final base = value['base'], staging = value['staging'];
    if (base is! String || staging is! String) return null;
    return PhoneFolderLayout(
      base: base,
      staging: staging,
      paused: value['paused'] != false,
    );
  }
}

/// A [RootFilesystem] that maps the three top folders into shared storage.
abstract interface class PhoneFolderRouting {
  PhoneFolderLayout get layout;

  /// Whether the three folders are paused now (no access, or shared storage
  /// unavailable): they are absent from every listing and every operation
  /// on them is refused.
  bool get paused;

  /// Binds the open private root [rootFd] and private staging [stageFd]:
  /// from now on paths beneath them that start with a top folder resolve
  /// in shared storage. Opens the shared side unless paused.
  void attach(int rootFd, int stageFd);

  /// Pauses or resumes the three folders (access lost or granted).
  void setPaused(bool paused);

  /// The absolute path of the engine path [relative] on disk, or null when
  /// it is not in a phone folder.
  String? absolutePath(String relative);

  /// A directory path through which Dart file I/O reaches the shared
  /// staging folder (as [RootFilesystem.stagePath] for private staging);
  /// null while paused.
  String? get sharedStagePath;

  /// Phone paths changed by this boundary since the last call (installs,
  /// renames, removals): the media library is asked to scan exactly these
  /// (spec #52 Media library, AC0).
  List<String> drainMediaScans();
}

/// Whether the engine path [path] is in (or is) one of the phone folders.
bool inPhoneFolder(String path) {
  final slash = path.indexOf('/');
  return phoneFolderNames.containsKey(
    slash < 0 ? path : path.substring(0, slash),
  );
}

/// Port (UI isolate): the platform's side of the phone folders, Android
/// only (`AndroidPhoneFolders` over `cloud.anj/phone_folders`).
abstract interface class PhoneFolderAccess {
  /// The layout as it is now: [PhoneFolderLayout.paused] when All files
  /// access is missing or shared storage is unavailable. Asked before the
  /// sync worker starts and again whenever the app comes to the front.
  Future<PhoneFolderLayout> check();

  /// Opens the system's All files access page for this app.
  Future<void> openSettings();

  /// Asks the media library to index exactly [paths] (removed paths drop
  /// their rows).
  Future<void> scan(List<String> paths);
}
