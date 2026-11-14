# Phone folders: AC0 shared-storage findings (spec #52, task #44)

Seat **E** only: the Halo emulator, AVD `anj-a0-36`, Android 16 (API 36) x86_64,
`sdk_phone64_x86_64 BE2A.250530.026.D1 userdebug`, QA build `cloud.anj.anj_cloud.qa`
with `MANAGE_EXTERNAL_STORAGE` granted by `appops`. The **P** (Pixel) part of AC0 is
pending: it belongs to the verification run with the FnB present.

Every check runs **inside the app process** (untrusted_app, its seccomp filter, the
real `libanj_rootfs.so` through `AndroidRootFs`), because `run-as` cannot reach shared
storage at all (EACCES on `/storage/emulated/0/Music` even with the appop allowed), so
it is no stand-in for the app.

- Probe: `integration_test/android_phone_folders_ac0_test.dart`
- Driver: `tool/android/ac0/emu_ac0_app.sh` (payload of `anj-emu-run`)
- Evidence: `~/.local/share/anj-cloud/qualification/f27-ac0-e-20261114/final/`
  (`ac0.txt`, `media.txt`, `reboot.txt`, logcats); earlier runs under `earlier/`.

Reproduce:

```sh
ANJ_TAG=<lane> tool/android/build_apk.sh <n> -t integration_test/android_phone_folders_ac0_test.dart
cp build/app/outputs/flutter-apk/app-debug.apk /tmp/ac0.apk
ANJ_APK=/tmp/ac0.apk OUT=<dir> anj-emu-run <lane> <n> tool/android/ac0/emu_ac0_app.sh
```

Shared storage on E is MediaProvider's FUSE mount (`/dev/fuse` on `/storage/emulated`,
statfs magic `0x65735546`); no fuse-bpf or passthrough properties are set.

## Findings, primitive by primitive

| Primitive | Result on E | Consequence |
|---|---|---|
| No-follow walk of `/storage/emulated/0/Music` | **Works.** `anj_open_root` (the component-by-component `O_NOFOLLOW` walk) opens it; `anj_scan` lists it | The boundary works on shared storage unchanged |
| Symbolic links | **Cannot be created** in shared storage (`symlinkat`: EACCES) | Nothing to follow; the walk's refusal stays as defence |
| Exclusive create | **Works.** `O_CREAT\|O_EXCL` and `anj_create_file` both give EEXIST the second time | As on app storage |
| Atomic rename from staging, same volume | **Works** from a staging folder in shared storage (`Android/media/<pkg>/anj-staging` and `/storage/emulated/0/.anj-cloud-staging` both): `renameat2(RENAME_NOREPLACE)` of a 1 MiB file and of a folder; onto an existing name it fails with EEXIST and the existing file is untouched; `anj_install` (copy, then no-replace rename) and `anj_quarantine` (phone file into staging) work. Music to Documents renames keep the inode | Downloads can appear only whole, never replacing a phone file. Staging **must** be in shared storage: from app-private storage every rename fails with **EXDEV** |
| Staging folder ownership | Every file and folder in shared storage shows owner **10127 (MediaProvider)**, group 1023 (media_rw), modes 0770/0660; `chmod 0700` has no effect | The native guard's owned-staging check (`owned_directory`: owner uid and mode 0700) refuses a shared-storage staging folder (`anj_restore_owned` fails EINVAL). Implementation work: a shared-storage form of that check. Not a spec change |
| inotify for another uid's changes | **Works.** With `adb shell` (uid shell) as the other app: create, modify, close-write, rename pair, delete and mkdir all arrive | The shared inotify watcher applies. Changes over **USB/MTP** are not testable on E (Pixel part) |
| Lease (`F_SETLEASE`) | **Fails, EACCES**, on files the app wrote and on files another uid wrote (the caller never owns a shared-storage file) | **#108 Q15 fallback**, as the spec allows: the app's own open-file tracking (`OpenDocuments`) plus an unchanged-stamp check before release, documented as weaker. Android exposes no view of other apps' open descriptors, so a reader that opens and closes inside the window is not seen; a write changes the stamp and fails the release |
| Case sensitivity | **Case-insensitive.** `case.txt` opens `Case.txt`; creating `CASE.txt` beside it fails EEXIST. `RootFilesystem.caseInsensitive()` answers false on Android today | The spec's case-clash rule applies as written; the mapped folders must report case-insensitive |
| Media library after a path write | **Not visible to other apps until a scan request.** A WAV the app writes by path gets a MediaProvider row that other apps' queries do not return (still not after 4 s; the row is pending). After a MediaStore `scan_file` request for exactly that path (what `MediaScannerConnection.scanFile` sends) the audio row is visible. A WAV renamed in from the `.nomedia` staging folder is likewise visible at its new path only after a scan request for that path. A staged file under `.nomedia` never appears as audio | The **spec's fallback**: after every install, rename and delete in a mapped folder the client asks the media scanner for exactly the changed paths |
| Folder identity across a reboot | FUSE has no on-disk fsid: `rootInfo` reports volume `82` (st_dev) and `stable=false`. st_dev and the inodes of `Music`, `Movies` and `Documents` (the lower ext4 inodes) were **unchanged across a reboot** | Usable for the #150 / #163 identity checks on E; the Pixel (fuse-bpf on recent Pixels) must confirm |
| Without All files access | The phone folder **still opens and lists**: folders are visible, files other apps made are **not** (0 of 2 in the probe), and the app may still create folders | A scan without access looks like local deletions. The paused state must come from an **explicit permission check** (`Environment.isExternalStorageManager()`) before any pass touches the three folders, never from a filesystem error |
| Revocation while running | Android **kills the app** (`ActivityManager: Killing … MANAGE_EXTERNAL_STORAGE changed`) | A pass cannot continue with a partial view; the next start sees the permission missing and pauses |
| `fsync` of a folder | Works | No-replace publication keeps its directory sync |
| Names | Non-Latin, NFD accents, emoji, a leading or trailing space, a trailing dot, `.hidden`, `#%&` and a 254-byte name all work. **File** names containing `: " * ? < > \|` (and `\`, tab, DEL) are **refused with EPERM**. Folder names with `:` and `?` are accepted | See below: this breaks a rule in spec #52 |

## Finding that breaks a spec rule: names the phone folders cannot hold

MediaProvider's FUSE layer refuses to create a **file** whose name contains any of
`" * : < > ? |` (EPERM), the FAT character set. `\` and C0 controls are also refused,
but the cloud name rule (spec #49 R2) never lets those reach a cloud name, so the
cloud-reachable set is the seven characters `" * : < > ? |`. Folders with them are
accepted, so the refusal is per file.

Spec #52 says the phone folders use only "the **case-clash part** of the local-name
rule (as macOS does)", and that "ordinary non-Latin and special-character names" sync
"as they are". A cloud file named, for example, `Where Is My Mind?.mp3` or
`Live: 1999.flac`, ordinary in a music library made on Linux, cannot be created in
`/storage/emulated/0/Music` under its name. As specified, it would fail to download
there, which also breaks "never refuse ordinary real-world names".

Options put to the Planner (decision #202 chose option 1, for files and folders alike):

1. **Apply the Windows character step of the local-name rule (spec #49 R3 step 1) to
   the three phone folders**, beside the case-clash step: on the phone the seven
   characters become their fullwidth lookalikes (`?` → `？`, `:` → `：`, …), so the
   file above is `Where Is My Mind？.mp3` on the phone and keeps its cloud name. The
   mechanism exists and is shared with Windows. To decide: files only (where FUSE
   refuses) or files and folders (one rule, as on Windows); and Windows' other steps
   (trailing dots and spaces, device names) are **not** needed on Android.
2. **Keep such files out of the phone folder** (recorded Cloud-only, a row saying the
   phone cannot hold the name, with Rename). Names stay exact, but the file is not
   on the phone, which the spec's "never refuse" posture rules out.
3. **Rename in the cloud** with the cloud cleanup rule. Changes the name on every
   device; contradicts "the cloud names are unchanged".

## What the engine work built on these facts

Tasks #45 to #47 build on the facts above: staging in
`Android/media/<pkg>/anj-staging` with `.nomedia` (removed with the app), a
shared-storage form of the owned-staging check, the stamp-only guard for the mapped
folders (#108 Q15), case-insensitive name handling there, scan requests after every
change, and the paused state driven by the permission check. The Pixel part of AC0
reruns the probe with an arm64 build through the toolchain adb shim, adding a USB/MTP copy
for the inotify row (`ANJ_AC0_MTP=1`; the reboot check runs only on an emulator unless
`ANJ_AC0_REBOOT=1`):

```sh
ANJ_APK_PLATFORM=android-arm64 ANJ_TAG=<lane> tool/android/build_apk.sh <n> \
  -t integration_test/android_phone_folders_ac0_test.dart
cp build/app/outputs/flutter-apk/app-debug.apk /tmp/ac0-arm64.apk
ADB=~/.local/share/anj-cloud/toolchains/android/bin/adb ANJ_AC0_MTP=1 \
  ANJ_APK=/tmp/ac0-arm64.apk OUT=<dir> tool/android/ac0/emu_ac0_app.sh
```

When the script prints the work folder, copy any file named `mtp-<anything>` from the PC
into it over USB file transfer. The probe installs and finally uninstalls the QA build, and
removes its work folders.
