---
title: Linux client development
tags: [linux, flutter, sync]
date: 2026-11-01
project: anj-cloud
purpose: Run and qualify the Linux client
---

# Linux client development

## Status

This is the first client implementation increment for Feature #9, spec #3.
It supplies a functional Flutter Linux UI, a serialized sync worker, SQLite
manifest/operation journal, descriptor-relative filesystem boundary, device
identity/pairing code and a DAV adapter. Fixture, local TLS and real VM host gateway integration tests cover the behavior described below.
The laptop and other platforms require separate acceptance.

The client connects to an AnJ Cloud gateway built on Nextcloud. Nextcloud provides server-side file storage and
sharing; the gateway adds pairing, per-device access control and client updates. Clients do not connect directly
to Nextcloud.

Cloud space release uses journaled artifact ownership, a conditional remote hash
proof and a supported sole-open Linux write lease through quarantine and final
unlink. Busy files, unknown hardlinks, working copies and legacy/uncertain staging
remain pending. The native guard and real process-restart tests use synthetic
The VM host files. A real two-profile gateway run also measured 4 MiB of owned
allocated bytes dropping to zero with the remote SHA-256 unchanged.
Collection deletion uses the gateway’s serialized mutation lock and concrete
ETag guard; stale collection deletion and changed descendants were checked
against the real gateway. The Linux worker enables this qualified contract.

## Installation

Per-user verified local-archive installation, explicit updates and the native
profile lifetime guard are described in [Linux installation](LINUX_INSTALL.md).
Installed-client acceptance is separate from source tests and bundle rendering.

## Code layout

Shared Dart lives in `lib/core/`, `lib/ui/` and `lib/design/`; Linux adapters
live in `lib/platform/linux/` and `native/posix/` (shared POSIX native code) behind the interfaces in
`lib/core/ports/`. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Build and check

Use the pinned Flutter 3.47.9 / Dart 3.13.7 SDK. The tracked lockfile fixes
resolved package versions. Linux requires the normal Flutter desktop toolchain,
GTK3 and libsecret. Device key, CSR and certificate operations run in process
(`core/gateway/device_crypto.dart`, pointycastle; spec #28 U1); OpenSSL is
needed only by the tests that compare against it and by the Linux installer's
unchanged prerequisite check. The native
adapter uses Linux `openat2` and `renameat2`, not a Python runtime.

```bash
cd apps/client
export FLUTTER_SDK=~/.local/share/anj-cloud/toolchains/flutter-3.47.9
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
"$FLUTTER_SDK/bin/flutter" --suppress-analytics pub get
./tool/check.sh
"$FLUTTER_SDK/bin/flutter" --suppress-analytics build linux --release
```

`tool/check.sh` compiles the bounded native library, runs analysis and runs
fixture/widget tests. It can receive another `FLUTTER_SDK` path. Release bundles
include the native library and SQLite native assets under `lib/`.

## Run a disposable profile

Create a private state directory and a separate empty parent directory. Start
the built binary using only that state directory:

```bash
fixture=$(mktemp -d /tmp/anj-client-demo.XXXXXX)
mkdir "$fixture/state" "$fixture/home"
HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" XDG_DESKTOP_DIR= \
  build/linux/x64/release/bundle/anj_cloud --profile-dir "$fixture/state"
```

A new profile creates its root without a picker (spec #34 P1) in the home
folder, and an **AnJ Cloud** link on the desktop that `HOME`,
`XDG_CONFIG_HOME` and `XDG_DESKTOP_DIR` name (spec #34 P2). So a disposable
run points the first two at the fixture and empties the third: `--default-root` alone moves only the root, and the link would
land on the real desktop, dangle after cleanup and keep the real profile from
getting its own. The synced folder is `$fixture/home/anj-cloud/`; the fixture
home has no desktop folder, so no link is made. The permanently enrolled root always
uses **Local and cloud**. Select **Cloud-only / free up space** or **Local and
cloud** on folder menus, and **Cloud-only / free up space** or **Keep on this
device** on file menus (spec #45); Select mode applies either to files, folders
or a mix, without confirmation. A file uses its own choice when it has one,
otherwise its nearest containing folder's ("(as folder)" in its menu); files
directly in the root follow the root, which stays Local. Choosing a folder's
storage clears the own choices of the files that follow it (for Documents,
Music and Videos: their loose files); explicit nested folder choices survive
changes to their parent. Cloud-only remains synchronized and guarded release
follows verified upload: a file that is open, not yet uploaded or in conflict
stays on the device, its row says **Frees space when closed**, **Frees space
after upload** or **Frees space once the conflict is resolved**, and a later
pass releases it. A file's own choice ends with the file: a new file that later
takes a deleted file's path follows its folder. File-manager deletion still deletes synchronized content.
The app creates `anj-cloud/Music`, `Videos` and `Documents`, and keeps them
(spec #34 P7, decision #150): the three are always Local (Cloud-only and Delete
everywhere are not offered and are refused; a Cloud-only choice an earlier
version stored on one moves to the folders directly inside it), and every pass
first checks that each is a real folder. One that is gone (deleted, renamed
away, or deleted and created again, also while the app was stopped or during a
pass) is created again and its synchronized items come back from the cloud,
Cloud-only folders inside it staying Cloud-only; a missing item of it is marked
restoring in its row and is never inferred as a deletion until it is back. A
file or symbolic link holding the name is moved aside to `<name> (conflict
copy)` (then `... 2`), never deleted. The status line says so once. Transfers
never re-create a missing top folder themselves. Files and folders inside the
three are deleted as anywhere else, after a short hold: a recursive delete of a
top folder removes its contents first, so a deletion found inside one is sent
only once no new loss there has been seen for the watcher's longest delay plus
its quiet period (about 12 s), and only if a fresh check finds the top folder
still the same folder; when the folder then goes, every unsent deletion inside
it is taken back and its items restored. A case-only rename of a top folder is
renamed back, here and (made by the web UI or an older client) in the cloud. A
name held by something that cannot be moved aside (a FIFO, a Windows junction)
pauses synchronization with a message saying to move or remove it. Moving a
stored Cloud-only choice off a top folder is announced once, with the size of
the files directly in it that now download. Private staging is
`<profile>/staging/` when the profile is on the root's filesystem (same volume
key, so the same btrfs subvolume, and a rename reaches the root); otherwise the
dot-named `.anj-cloud-staging-<first 8 of profileId>/` beside the root. A profile
from before this staged in `.anj-cloud-<profileId>/`; at worker start that folder
moves there once it holds no pending work (only an empty folder is removed).
This is Linux only in this delivery: macOS and Windows keep staging in
`.anj-cloud-<profileId>/` beside the root and never move it.
A new root also gets a desktop link **AnJ Cloud** (`xdg-user-dir DESKTOP`, else
`~/Desktop`; none: skipped), created once per profile and never over an existing
entry. Do not use valuable files or an existing synchronizer root for
qualification. Supply known other sync roots to the overlap check. The active profile/state
directory is always excluded, including when loading a persisted root.

Use **+ Folder** to create a folder in the root or an existing supported local
folder. Enter one name component and choose **Local** (the default) or **Cloud**.
The worker checks the destination and reports success or an actionable error;
existing files/folders are never overwritten. Cloud folders keep a local scaffold
so ordinary applications can save into them. Their new files inherit Cloud,
upload when connected and are released only after the existing remote-content
and local-ownership checks. Creation works offline and remains queued for sync.
Interrupted or uncertain publication stays pending instead of adopting an
unrelated directory or applying its storage choice.

Only the app's worker reconciles, while the app runs (with a system tray the
window can be closed and sync continues; see LINUX_INSTALL.md, "Tray, closing
and quitting"). Each pass records local changes and is followed by a short idle
interval; the server is listed about every 30 s while idle, at once when the
window is shown, and with backoff while unreachable. **Pause sync** persists in
the profile and stops all file-sync server traffic and sync changes to the
folder; only device certificate pickup (`GET /v1/device/certificate`) continues,
and it moves no file data or metadata. There
is no fixed latency promise for an arbitrarily large library. Root unavailability/replacement or an incomplete
scan pauses work rather than inferring deletion.

Stop only this app process. After confirming the fixture path contains only
synthetic data, remove that fixture directory to discard its local test data.
This does not remove gateway devices/accounts or their cloud content. Device
revocation and cloud fixture cleanup belong to the gateway's operator tooling.

## Phone folders on Android

Spec #52 (decisions #201, #202). On Android the cloud's **Music**, **Videos** and
**Documents** are the phone's own folders in internal shared storage, one copy synced
both ways: Music is `/storage/emulated/0/Music`, Videos is `/storage/emulated/0/Movies`
and Documents is `/storage/emulated/0/Documents`. The app shows the cloud names;
everything else (root-level files, `Shared/`, other top-level folders) stays app-private
in `<files>/anj-cloud` behind the documents provider and "Apps with access".

- **Engine paths stay cloud-shaped.** The engine still sees `Music/…`, `Videos/…` and
  `Documents/…`; `MappedRootFs` (`lib/platform/native/mapped_root_fs.dart`, the Android
  adapter `AndroidPhoneRootFs`) resolves those three top folders beneath one descriptor of
  shared storage (`Videos` becomes `Movies` there) and passes every other path to the
  private root. Nothing outside the three phone folders is listed or touched.
- **Staging on the same volume.** Bytes for a phone folder are staged in
  `<shared storage>/Android/media/<package>/anj-staging` (with `.nomedia`, removed with the
  app); their staging names carry the `phone-` tag (`RootTree.stageName`), so every
  install is an atomic no-replace rename on the phone folders' volume (AC0: renames from
  app-private storage fail with EXDEV). Bytes staged privately before the folders were
  mapped (an open working copy, a recovery copy) are copied durably into shared staging
  and renamed into place from there, never replacing a file.
- **Names.** Shared storage refuses `" * : < > ? |` and controls in file names and
  compares names case-insensitively, so inside the three folders the per-device name rule
  applies R3 step 1 (fullwidth lookalikes, Control Pictures) and the case-clash step
  (`NameOs.phone`): `Where Is My Mind?.mp3` is `Where Is My Mind？.mp3` on the phone and
  keeps its cloud name. Android's `.pending-…` and `.trashed-…` names are not files (a
  move to the Files app's trash syncs as a deletion); `.nomedia` and `.thumbnails` sync
  only when the cloud already has them.
- **A top folder renamed in case only** (`Music` to `music` in the Files app) is still the
  top folder: before any listing its name is restored. Only the three folders' own names are
  looked up (casefolded storage reports the stored spelling); the volume is never listed.
  The folder is parked in the staging folder (`anj-staging/.anj-top-<name>`) and renamed back
  from there, each step a no-replace rename; one left parked by a crash is finished first.
- **Media library.** Writes by path stay invisible to other apps until scanned (AC0), so
  after each install, rename or removal in a phone folder the app asks the media scanner
  for exactly those paths (`mediaScan` worker event, `MediaScannerConnection.scanFile`).
- **Open files.** Shared storage refuses every lease, so the release guard there is the
  #108 Q15 fallback: the app's own open-file tracking plus an unchanged size and
  modification time from guard open to release (weaker than the lease: a reader that
  opens and closes inside the window is not seen).
- **All files access.** The folders need `MANAGE_EXTERNAL_STORAGE`, explained once at
  pairing or after the update ("Allow" opens the system page). Without it, or while shared
  storage is unavailable, the three folders are **paused**: absent from every listing,
  nothing under them uploaded, downloaded, deleted or inferred deleted, and the home screen
  says "Music, Videos and Documents are paused: allow All files access". Only the explicit
  `isExternalStorageManager()` check decides (checked before the worker starts, on every
  app open and before a background run): without access Android still lists the folders,
  with other apps' files hidden. Revoking access makes Android stop the app; the next start
  checks again. Granting it does not stop the app: the worker resumes the folders between
  passes (a pass keeps the state it began with, so nothing its paused scan did not list is
  read as missing) and runs one full verification.
- **Moving an existing install.** The first start with access moves the private `Music`,
  `Videos` and `Documents` into the phone folders before anything syncs
  (`PhoneFolderMove`): each file is copied through shared staging, verified by hash,
  renamed into place without replacing anything, and only then removed privately; a crash
  or kill resumes. Each item's place and the name it had are journaled once: names follow
  the phone rule above, and every item keeps the name it had as its cloud name (a file the
  cloud never had too: `new?.mp3` is `new？.mp3` on the phone and `new?.mp3` in the cloud). A
  conflict copy's name is journaled before it is written. The move also runs when access is
  granted while the app runs. A phone file already at that path with the same bytes links; different
  bytes are both kept (the cloud's conflict rule decides on the next pass). Unsynced edits
  upload afterwards; nothing is downloaded again. The status line says once "Music, Videos
  and Documents are now in your phone's folders."
- **Large files.** Above the gateway's upload limit a phone file stays on the phone and its
  row says "Too large to upload yet".
- **Settings.** The menu's **Phone folders** page shows each folder's place; **Apps with
  access** starts with "Music, Videos and Documents are in your phone's own folders. Apps
  with media or file access can use them. The approvals below cover your other folders."
  Approvals for folders inside the three are removed, and their provider document ids
  resolve to nothing.

Proof: `test/phone_folders_test.dart` (H, also run against the Android boundary build by
`tool/android_variant_suites.sh`), `tool/android/ac0/` and
`integration_test/android_phone_folders_ac0_test.dart` (AC0), and
`tool/android/emu_phone_folders.py` (AC2 to AC6 on the emulator).

## Pairing and open files

Code-only pairing (decision #151, spec #35): the pair dialog asks for the
server, prefilled with the household origin the app was built with
(`--dart-define=ANJ_HOUSEHOLD_ORIGIN=https://…`, default
`https://gateway.example.com`), and the pairing code (case-insensitive,
optional spaces/hyphens). The code carries the first 10 bytes (80 bits) of the
household CA's SHA-256: the app fetches `GET /v1/ca` without trust, accepts the CA only if
it matches ("This code is not for this server" otherwise, with nothing stored),
stores it in the profile as `household-ca.crt` once the device is paired, and
uses it as the trust anchor from then on. A profile that is already paired
refuses a code whose pin does not match its stored CA before fetching
anything, so its anchor is never replaced by another server's. The server approves the device when it redeems the code; the app
waits for that (asking `/v1/enroll/status` every 8 s, at most 3 minutes) with no
fingerprint step. A code issued before this release (32 characters) still needs
the trust anchor of an earlier pairing and the admin's fingerprint approval;
press Pair again once approved. Device keys are
persisted in the desktop keyring before reservation; retries reuse the signed
CSR. The returned certificate must match the key. No insecure TLS option exists.
Certificates are valid until the operator issuer's expiry. While connected, the
sync worker fetches the device's current certificate from `GET /v1/device/certificate`
over its existing mutual-TLS identity at start, then daily (hourly within 30 days of
expiry). A reissued certificate is adopted only if it matches the stored private key,
chains to the pinned issuer as a client certificate and carries the same device
identity; certificate and expiry are replaced in one manifest transaction and the
worker switches to it without a restart. A failed pickup keeps the working
certificate. The status shows a warning only when expiry is within 14 days and
pickups keep failing. An expired or revoked device still needs a new invitation.
Re-pairing retains the existing key and signed CSR. Actual revocation/new-invitation checks
verify that a new leaf resumes access while the revoked old leaf remains denied.
An established profile pins the authoritative account UID and server origin.
Pairing it to another account/server is refused; use a new profile/root.
No account migration is supported in this delivery. If the device key is missing,
the app generates a matching replacement CSR, invalidates the old local certificate
and requires a new invitation, while retaining these account/server pins.

Double-click a file or folder icon/name to open it; the folder chevron only
expands/collapses its children. Keyboard users can focus the name and press
Enter or Space. File opening creates a private working copy outside the root
and launches its file URL. Folder opening uses the existing local directory;
it does not download cloud-only descendants.
The selected Local/Cloud policy stays unchanged. Stable saved edits upload
automatically while the external editor remains open, including subsequent
saves. Rapid saves between scans may coalesce; unsaved editor memory and every
transient version are not captured. Separate working copies retain independent
baselines and conflicting versions remain recoverable.

The toolbar combines **All**, **Cloud** or **Local** with a case-insensitive
relative-path search and the current Home/Editing/Conflict tab. Storage filters
use effective policy even when a badge says Queued or Conflict. A nonempty
text search returns only matching files, with full relative paths to distinguish
identical names; a folder name still matches files beneath it. Each result meets
the selected policy and tab. With no text query, policy filters retain parent
rows for context and reveal matches through collapsed folders; clearing filters
restores the saved expansion.

**Show in folder** clears the query, switches to Home, expands the file's
ancestors and briefly highlights the exact file in the app. It retains a matching
storage filter or clears one that hides the file. Cloud-only and root-level files
work without downloading content, changing storage or opening an OS application.
The action is hidden during selection, when the whole card toggles selection.
Press Ctrl+F to focus search and Escape to clear it. Filters and creation remain
keyboard accessible and the toolbar wraps on narrow windows.

The **AnJ Cloud** header uses the selected Cloud Seal in the Harbor palette;
the existing Harbor theme seed remains unchanged. The tracked icon SVG and PNGs
in `assets/branding/harbor/` are copied from the project's original
`shared/branding/C-cloud-seal/harbor` design, without a runtime dependency on
that exploration directory. Technical IDs, executable names and profile paths
remain unchanged.

Compact library cards show Local/Cloud/Queued/Conflict badges, with actions on
the right (wrapping below on narrow windows). Routine policy/status lines are
omitted; warnings and retained-copy information remain visible. Hover a badge
for its device-specific storage policy. Right-click an icon/name, or press
Shift+F10 while focused, to choose an icon colour or reset it. Colours are
saved per relative path in the private profile's `icon-colors.json`; they do
not sync, follow renames or propagate to children.

After saving and closing the listed editors, choose **Finish editing**. Its
confirmation shows the current file locations, sizes and saved times, and
confirms those exact displayed files are your completed edit results. A later
Open is a separate session. Desktop launch success, idle time, a save or an
available file lease never automatically means the editor finished.

Finish conditionally verifies final remote content, then reclaims eligible
private files under descriptor-bound ownership, exact link accounting, native
write leases and a durable quarantine/unlink journal. Normal atomic-save editor
replacement requires an explicit ownership transition for the exact previewed
regular, user-owned, single-link file in the existing private editing slot.
Changes after preview need another confirmation. This is user authorization of
the completed result, not an inference about which program created an inode.

New immutable upload buffers record their session binding, conditional-upload
base and accepted ETags, hashes, identities and successor chain. Finish may
release older transfer buffers only when that authenticated same-session chain
ends at the final remotely verified edit. Each old buffer is checked against
its own immutable bytes. Lost acknowledgements, broken/unbound/legacy lineage,
other editor sessions, differing preserved versions and uncertain ownership
never acquire this disposal authority.

Cloud keeps its root copy absent or safely releases it; Local keeps a current
required root copy. Busy, offline, conflicting, replaced or interrupted work
remains pending and recoverable. Details lists retained editor/recovery paths
and current sizes. Older legacy recovery files can remain after completion;
that residual is shown separately and is not a claim of complete space release.
Reclamation evidence counts actual owned allocation on the tested filesystem;
it does not promise removal of independent reflinks or snapshots.

## Local index and passes

A pass starts 2 s after the previous one finishes, never back to back, or
earlier (at least 250 ms after it) when watched local work falls due. Local
changes are found as described under "Local change detection" below; without
inotify every pass stat-scans the root. A file's stored hash (with its stamp
`dev:ino:size:mtime_ns:ctime_ns`) is reused only while the stamp is unchanged,
the file's ctime is more than 2 s older than that hash, its filesystem is
ext2/3/4, btrfs, xfs, f2fs or bcachefs, and periodic writeback is enabled
(`vm.dirty_writeback_centisecs` > 0 and `vm.laptop_mode` = 0, re-read every
pass). A hash is final only when read at least
M = max(60 s, 2 × (`dirty_expire_centisecs` + `dirty_writeback_centisecs`))
after the last ctime and at least M (monotonic clock) after this process first
saw that stamp; otherwise the file is read exactly once more after M (a write
through a shared mapping to an already dirty page does not move ctime). M is
recomputed every pass, so a later larger M applies to hashes not yet final.
On tmpfs, other filesystems, with writeback disabled, in laptop mode or when
the settings cannot be read, every pass hashes and no stamp is stored. Upload snapshots, the check before a download
replaces a local file, eviction proof and guard, staging release, working
copies, Finish editing and conflict decisions always read the bytes. A pass
reconciles only paths whose local stamp/content or remote version changed,
paths with pending operations, unsettled or blocked paths and their
ancestors; every path is reconciled at startup and every 5 minutes. Commands
are serviced between paths. The UI receives state only when it changed or a
command was handled.

Set `ANJ_CLIENT_METRICS=/path/file.jsonl` before launch to append one JSON
line per pass (files and bytes hashed by purpose, rows written, transactions,
candidates, paths visited, duration, `localScan` full/partial, paths stat-ed
and the running count of full stat scans). It is off by default.

### Local change detection

The worker watches the root with inotify (`native/posix/watch_inotify.inc`). Each directory
is opened beneath the root descriptor (`O_PATH|O_DIRECTORY`, no symlinks) and
watched through `/proc/self/fd/N`; no user path string is resolved. A watcher
isolate blocks in `poll()` on the inotify descriptor and an eventfd (used for
shutdown) and posts event batches; the sync worker never blocks on inotify.

- **Startup** walks top-down, adding each directory's watch before reading
  it, so a concurrent change appears as an event or in the listing.
- **Queue**: changed paths are keyed by path, settle after 1.5 s of quiet (at
  most 10 s), and are re-stat-ed (and hashed only under the index rules
  above). A full queue collapses to one subtree audit of the common ancestor.
  A new or moved-in directory is watched, then scanned; renames are delete
  plus create.
- **Own operations**: after an install, mkdir, rmdir, preservation move or
  eviction the engine records the resulting stamp, so the event it causes
  finds an unchanged stamp and reads nothing. This applies only where the
  filesystem gives a later change a distinct ctime (Linux multigrain
  timestamps, probed once in private staging); with coarse ctimes the
  racy-timestamp rule applies and the installed file is read once. The
  confirmation hash after M still runs: it is scheduled from the index on
  the monotonic clock, not triggered by events. Paths the engine changed in
  a pass are re-stat-ed on the next pass.
- **Audits**: a full stat-only audit (unchanged stamps are not hashed) runs
  at startup, every 5 minutes (decision #51: it finds writes inotify cannot
  report, such as a shared-mmap write to an already confirmed file), after an
  inotify queue overflow, after a suspend (`CLOCK_BOOTTIME` vs
  `CLOCK_MONOTONIC`), after a root move/delete event (the root check then
  pauses as before) and when the watcher isolate dies.
- **Mounts**: `/proc/self/mountinfo` is polled in the same `poll()` set; a
  mount appearing or disappearing beneath the root audits that subtree.
- **Backpressure**: the watcher isolate keeps at most 4 batches the worker has
  not processed; behind that it merges events per (directory, name) and,
  past 20,000 names, replaces them with one full audit.
- **Fallbacks**: a directory whose watch cannot be added (e.g. the
  `fs.inotify.max_user_watches` limit) or that lives on a network/FUSE mount is
  audited every 60 s, and the status line says some folders are checked
  periodically. When inotify is unavailable, the root itself is a network/FUSE
  filesystem, or the watcher isolate stops (restarted at most 3 times, 30 s
  after each failure), every pass stat-scans the root and the status line
  says so. Files whose stamps are not trusted are still read every pass.

### Cloud listing

A pass that lists the cloud starts at the root with one Depth:1 PROPFIND. A
child folder whose ETag and file ID equal those the last complete listing
recorded for it reuses that listing's subtree without a request: Nextcloud
changes a folder's ETag whenever anything beneath it changes. A quiet library
costs one PROPFIND per check; a change six folders down costs the root plus
the six folders on its path (spec #33 I4, flag SC-057). The stored listing
lives only in the client's memory and is replaced only by a listing that
completes, so the next listing walks every folder at worker start, after any
listing error or failed request (a reconnect), after the incoming shares
changed, and at least every 6 hours (`listingFullWalkInterval`), on the
monotonic clock or forward on the wall clock (suspend stops the first; a
wall clock stepped back is ignored). A forget while a listing runs keeps that
listing from being stored. Incoming
shares are pruned like any folder: on the review stack (Nextcloud 33.0.10) an
owner's edit, create and delete six folders inside a share changed the
recipient's `Shared`, mount and inner folder ETags at once
(`deploy/incremental_listing_fixture.py`); `DavCloud(pruneShares: false)`
lists every folder holding a share on every check instead.

Sharing changes no ETag (`deploy/share_metadata_probe.py`), so share types and
permissions in a reused subtree are refreshed another way: a share created,
changed or removed in this client re-lists the folders from the root down to
the shared folder's parent; an incoming share's permission change alters the
gateway's incoming list, which forces a full walk. An outgoing share created
or removed in the web interface shows (or stops showing) as shared here only
after the next full walk, at most 6 hours later.

A row that only records the cloud (nothing on disk, nothing in flight, such
as a new Cloud-only file) shares its manifest commit with up to 255 others
and the pass end; a crash before that commit only means the next listing
records it again. `tool/bench/first_pass_bench.dart` times a first pass over
new Cloud-only files with and without `--enable-asserts`.

## Per-device file names

Spec #49 (decisions #193, #195, #198, #199): a name is never blocked and the
user is never asked to rename. `NameRule` (`lib/core/sync/name_rule.dart`)
gives every cloud item a local name on this OS, once per listing:

- R1/R2, everywhere: a leading or trailing space is trimmed, `\`, C0 controls
  and DEL become lookalikes, names are cut at 250 bytes, and a folder ending
  in `.part`/`.filepart` gets `_` appended. These change the cloud name too:
  the local item is renamed in place (same identity, a folder carries its
  subtree) and only then uploaded, so nothing is sent twice. A `.part` or
  `.filepart` file is a local temporary: never uploaded, no row.
- R3, this OS only: on Windows, `CON.txt` shows as `CON_.txt`, `a:b?.txt` as
  `a：b？.txt`, `x.` as `x`, and of `Report.pdf` and `report.pdf` the older
  item keeps the name and the other is `report (2).pdf`; on macOS only case
  and normalization clashes are suffixed; Linux holds every name verbatim.
  Android's phone folders (spec #52) take Windows' characters step and the
  case clash ([Phone folders on Android](#phone-folders-on-android)).
  The cloud name never changes.

The manifest is keyed by local path; each entry records the cloud name it
stands for (`Entry.cloudName`), rebuilt from every listing, and `NamedCloud`
(`lib/core/sync/cloud_names.dart`) translates each path per segment at the
cloud boundary. A local name the rule did not give (a new file, a rename) is
taken literally. When a sibling appears or disappears and an item's local
name changes (`report (2).pdf` becomes `report.pdf` once `Report.pdf` is
gone), the item is renamed in place through the same file ID pairing as a
cloud rename, with no transfer. Rows and details show the cloud name.
What the rule cannot resolve (today a file or folder named `.htaccess`)
stays on this device with one row, "Can't sync this name: <reason>", and a
Rename action; Rename refuses only an empty name, `/`, and a name the rule
still cannot resolve. Rows left by the #120 client ("Name not allowed on
other devices") resolve on the first pass after upgrade.
`tool/name_policy_fixture.dart`, driven by `deploy/name_fixture.py`, proves
this with two Linux devices against a review stack.

A rename of a synchronized item that changes only case or normalization
(`Photos` to `photos`) is the same item, not a clash (SC-054,
`lib/core/sync/case_moves.dart`). When the old spelling is gone and exactly
one new item has the new spelling in the same folder, the engine records a
`move` operation instead of a deletion and sends one conditional `MOVE`
(`Overwrite: F`); a folder moves with its whole subtree and keeps every
version, so nothing is uploaded again. A lost acknowledgement is recognised
from the listing; a rename undone, superseded or overtaken by a new sibling
falls back to ordinary reconciliation. The other way round, a cloud rename
of that kind (the same file ID, else the same version, at the new spelling)
renames the local item in place once, which on a case-insensitive volume is
the only safe way (a download to the new spelling would land on the old
item). A cloud rename onto a name a different local item still holds waits
("rename pending", not Needs attention) until that item moves. A
child renamed together with its folder (`Photos/Top.txt` and `Photos` to
`photos/top.txt`) is paired again under the moved folder and moves too.
The pairing goes by name, not content: deleting `Report.txt` and creating an
unrelated `report.txt` in the same pass becomes a MOVE plus an upload, so the
old content survives as an earlier version of the new file rather than in
the cloud trash.
Names that differ only by Unicode normalization are one name in the cloud
(decision #138): Nextcloud stores NFC (a `MOVE` to an NFD spelling answers
412, and a two-step move via a temporary name still ends as NFC), so every
request names its path in NFC (`DavCloud.uri`), and each listed path takes
the local spelling of the same item (an NFD name from macOS stays NFD on
disk, with no clash, row or re-upload; where several local spellings share
one cloud name, the synchronized item wins, then the exact spelling on disk,
component by component). A normalization-only rename is
therefore a no-op in the cloud: its rows take the new spelling. Two local
siblings that differ only by normalization: the newer is renamed here with a
` (n)` suffix.
`tool/case_move_fixture.dart`, driven by
`deploy/case_move_fixture.py`, proves this against a review stack.

## Trash

Spec #44. Delete is one step: the rows leave the library at once (a delete
queued here hides its row and, for a folder, every row below it) and a
snackbar says "Moved to Trash" with **Undo** and **View** for about 8 seconds.
The only confirmations left are Delete now and Empty Trash in the Trash view
(app menu, **Trash**), which lists, one entry per deletion and newest first,
the account's server trash below `anj-cloud/` (the gateway's `/trash/`
routes, [access protocol](../../services/access/README.md#trash)) and this
device's own trash.

- **Device trash** (`lib/core/sync/device_trash.dart`). The copy a completed
  deletion produced (the bytes it preserved, or the snapshot of a file removed
  before it ever uploaded) becomes a `trash` record instead of a Recovery row
  when the server cannot be shown to hold it: original path, when it entered
  the trash, size and every staging name of the file. Spec #12's release rules
  are unchanged where the server has a trash: a copy whose bytes equal the
  deleted version is still released. Until a pass has seen the gateway's trash
  routes (an older gateway, or not yet known), every deleted file keeps its
  copy here, so Undo and Restore work from it. Every other copy of the row (a
  replacement, eviction or conflict copy, a leftover snapshot) keeps Recover
  and Dismiss. Rows left by earlier versions convert the same way on the first
  pass (their clock starts then). The same bytes for the same path and
  deletion are one entry. A pass learns `trash_days` about once a day; a copy
  is purged at the first pass more than `trash_days` after it entered the
  trash (7 while unknown), and released early when the live file at its path
  holds the same bytes again.
- **Edited, then deleted.** When the local bytes differ from the version last
  synced, the delete trashes the server's older version; the device copy is
  marked as the latest, and Undo and Restore use it (the server's item is left
  to expire).
- **Restore** of an entry restores the server item; the menu's "Restore this
  device's copy" (and Restore of a device-only or edited entry) uses spec
  #25's crash-safe write: original path, else `name (restored).ext`, missing
  folders created again, never replacing anything.
- **Undo** cancels a delete not yet sent (the local item never left);
  otherwise it restores the server's trash items for its paths deleted since
  the delete was made (an hour of clock difference allowed) with one batch
  request (`POST /trash/restore`), else the device copy. A name taken
  meanwhile gets `(restored)`; an item that cannot come back stays in Trash
  and the snackbar says so.
- While paused or offline only this device's trash is shown, with "Can't
  reach the server: showing only this device's trash".

`tool/trash_fixture.dart`, driven by `deploy/trash_client_fixture.py`,
proves one-step delete, both trashes and Undo against a review stack;
`tool/android/emu_trash.py` does the same through the phone UI.

## Temporary file exclusions

The sync boundary excludes exactly these case-sensitive basenames at any depth:
`.<nonempty-name>.kate.swp` and `.<nonempty-name>.kate-swp` (including
`..env.kate-swp`), `.DS_Store`, `Thumbs.db`, and `desktop.ini`; the macOS
names `._<nonempty-name>` (AppleDouble), `Icon\r` (Icon followed by a
carriage return), `.localized`, `.TemporaryItems`, `.Trashes`, `.fseventsd`,
`.Spotlight-V100` and `.DocumentRevisions-V100`; and Microsoft Office owner
files `~$<nonempty-name>` (spec #31 M4, shared by every client, Linux
included). At the top of the root only, the app's own staging probe
`.anj-cloud-probe-<32 hex>` is also excluded (spec #34 P3: an empty folder
renamed in and straight back out at setup; one left by a crash is removed at
the next start).
An excluded directory name also excludes its descendants. Ordinary dotfiles and
other dotdirectories, including `.env`, `.gitignore` and `.git/`, still sync;
`.tmp`, backup-looking names, case variants and either Kate suffix without an underlying
name are not broadly excluded. Policy uses decoded logical relative names.

Excluded files are omitted from discovery/content hashing, transfers and the
normal catalogue. Existing local recovery files stay on disk for their editor;
previously uploaded copies remain in the cloud. Policy adoption archives old
tracking and preserves private ownership/recovery paths in one transaction.
Definitely undispatched intents stop. Legacy `prepared` rows may already have
unknown outcomes: their complete history survives, with read-only remote
version/content observation where possible, and their ignored mutations are
never replayed. An observed matching body does not establish who created it.

Full remote metadata remains available for directory safety. A new directory
delete intent freezes previously observed excluded descendant versions along
with the ordinary baselines. Guarded deletion requires the fresh full subtree
to match that intent; new/changed descendants or a legacy missing baseline
leave deletion pending/conflicted. The policy itself never initiates cleanup.
Ignored local children are never recursively erased; a remotely removed folder
retains those local bytes and a deletion tombstone rather than repeatedly
recreating the cloud folder. Unreadable or replaced roots still pause safely.

## Dev transfer limit

The development gateway accepts PUT bodies up to 64 MiB (67,108,864 bytes)
with a 128 MiB staging budget by default. An oversized upload stays pending;
the client displays the actual and maximum byte counts and asks for a smaller
file. Source bytes and upload intent are preserved. Chunked uploads and larger
configured limits remain unqualified. HTTP 507 is a retryable storage/staging
failure and never confirms synchronization or permits local release.

## User-owned runtime bundle

From a clean committed checkout, this command rebuilds the pinned release and
creates an archive, per-file receipt and SHA-256 checksum in an absent directory.
Packaging requires Docker, Python 3.11+ and host `readelf` in addition to the
pinned SDK. It builds in a dedicated Debian 12 container; the host compiler,
startup objects, libraries and existing build/package caches are excluded:

```bash
python3 apps/client/tool/package_linux.py /absolute/absent/anj-client-artifact
```

The builder base image is digest-pinned. Debian 12 package revisions are resolved
when its image is first built; the receipt records the exact resulting image ID,
installed package versions, compiler and startup-object notes. Each build starts
from `git archive HEAD`, a writable copy of the pinned SDK and a fresh pub cache.
Generic x86-64 compiler flags apply to compiled native code. The pinned Flutter
engine and package native assets remain upstream precompiled components.

Packaging inspects every shipped ELF, including nested native assets. It refuses
higher x86 ISA requirement notes, symbol requirements beyond Debian 12 (glibc
2.36, GLIBCXX 3.4.30, CXXABI 1.3.13), private glibc ABI, unexpected runtime
search paths and unresolved dependencies on the Debian runtime. The archive
includes the ELF audit, resolved dependency paths and build toolchain inventory.
GTK3, libsecret and other system dependencies are resolved from the destination
system; they are not bundled. An unlocked desktop keyring is still a runtime
prerequisite, and the installer still checks for OpenSSL 3 (the client itself no
longer runs it). CPU notes do not establish that every instruction in
precompiled Flutter/SQLite code is baseline-compatible; actual CPU startup and
laptop checks are separate evidence.

Run the packaging regression checks with
`python3 apps/client/tool/test_inspect_linux.py`. They compile small real ELF
fixtures without the host startup objects and check higher-ISA, newer-ABI,
absolute library path, missing-binary and nested-asset refusal.

The archive includes the binary, native libraries and assets together. Keep them
in the same extracted directory. It contains no profile, device key or operator
CA. On a Linux x86_64 test seat with GTK3, libsecret, OpenSSL and a functioning
unlocked desktop keyring, first verify the supplied archive checksum, then
extract it into a new user-owned directory:

```bash
cd /path/to/downloaded/artifact
sha256sum -c anj-cloud-linux-x86_64-<head>.tar.gz.sha256
mkdir /absolute/absent/runtime-test
tar -xzf anj-cloud-linux-x86_64-<head>.tar.gz -C /absolute/absent/runtime-test
fixture=$(mktemp -d /tmp/anj-client-runtime.XXXXXX)
mkdir "$fixture/home"
HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" XDG_DESKTOP_DIR= \
  /absolute/absent/runtime-test/anj-cloud-linux-x86_64-<head>/anj_cloud \
  --profile-dir "$fixture/profile"
```

Replace `<head>` with the delivered 12-character source head. The app creates
`$fixture/home/anj-cloud/` itself and no desktop link (the fixture home has no
desktop folder; see the disposable profile above); the root uses Local and cloud. Provision the trusted
CA and gateway address through the operator channel before pairing; the Dev canonical origin is `https://127.0.0.1:8834`. On a laptop this
requires a separately authorized loopback forward to the VM host that preserves the
exact origin, or a coordinated gateway canonical-origin/certificate change.
Merely replacing the hostname does not qualify: DAV hrefs are origin-pinned.
Forward availability remains an operator preflight; keep hostname verification enabled. Test only synthetic files and stop only this app process.
Revoke its test device and remove its remote test folder through the operator
before discarding its local fixture. These are test instructions, not a claim
that the laptop has passed. No SDK or system installation is required to run
the extracted bundle.

## Evidence boundaries

Transport tests use a disposable loopback TLS server to check concrete conditional
headers, complete DAV traversal, URL boundaries, TLS hostname validation, client
certificate presentation, account-binding refusal and activation rollback. This
server is a protocol fixture; it is not the real Nextcloud gateway.

Core tests use two isolated local profiles and an in-process conditional cloud
fixture. They cover nested uploads, changes, offline deletion/restart,
delete/edit conflicts, remote deletion with unsynced edits, symlink refusal,
no-overwrite installation, interrupted preservation, working edits, guarded
reclamation and pending collection gates. Eviction tests measure lower owned
allocated blocks and unchanged remote hashes, refuse existing readers/writers,
unknown links and bad proofs, and exercise new writers at quarantine/unlink
barriers. Real child processes exit after rename and after final unlink, then
restart against the durable journal without inferring remote deletion.
These checks do not promise filesystem-wide reclamation through independent
reflinks/snapshots or control over arbitrary forced lease removal. An injected upload failure proves that failure path;
it is not a real disk-full filesystem test.

`integration_test/linux_app_test.dart` uses the actual Linux app and libsecret
plugin. Before running it, check the existing Secret Service collection's
`Locked` property without reading entries. If locked, leave the test pending;
do not unlock it or click prompts. The test writes, reads and deletes only a
unique `anj-cloud:qualification:` synthetic key. It never enumerates or deletes
unrelated keyring entries.

```bash
"$FLUTTER_SDK/bin/flutter" --suppress-analytics test integration_test/linux_app_test.dart -d linux
```

`integration_test/gateway_test.dart` is an opt-in real Linux app fixture. It
requires exclusive lifecycle ownership of the existing `anj-cloud-dev` stack,
an unlocked existing keyring and a private JSON configuration file. It creates
only synthetic profile roots, separate device keys/invitations and a unique
remote folder. Configuration keys are `runtime` (the handed-off foundation
checkout), `origin` (`https://127.0.0.1:8834`), `fixture` (an absent user-owned
path), `uid` (`anj-fixture-alice`), and optional source-head receipt fields
`client_head` and `gateway_head`. It never prints invitation codes/private keys.

```bash
ANJ_LIVE_GATEWAY_CONFIG=/private/path/config.json GDK_BACKEND=x11 \
  "$FLUTTER_SDK/bin/flutter" --suppress-analytics test integration_test/gateway_test.dart -d linux
```

`integration_test/downloader_flow_test.dart` is the opt-in Downloader fixture
(spec #42): the real app, worker and gateway on a throwaway review stack that
runs the fetch worker and its fixture site. `ANJ_LIVE_FETCH_CONFIG` names a
private JSON file (keys in the test's header). It pairs one device for a
fixture account, submits links through the tab, waits for the rows and for
the files in the synced folder, writes screenshots to `evidence`, then
removes its rows and files and revokes its device. It needs a display; a
headless nested compositor is enough.

The receipt distinguishes actual controller/libsecret pairing, real mTLS DAV
and two-profile reconciliation, and the paired app worker/window. Cases include
nested space/Unicode and punctuation/literal-percent names, updates, conflict
preservation, external file/folder deletion, an injected offline restart, Local/
Cloud allocation, guarded collection preconditions and retained-key re-pairing.
Remote deletion with a new unsynced child keeps the local subtree in conflict
without recreating the remote folder. Empty-directory removal proceeds bottom-up,
checks the observed identity, refuses symlink parents and never recursively
removes unknown local content. Successful fixture cleanup deletes only its
remote prefix, revokes its devices and removes only its profile keyring entries.

The VM host evidence does not establish native Wayland, OS-power-loss recovery,
distribution packaging, the laptop or Android. Actual independent review and
laptop acceptance are separate delivery gates.

## Resource baseline harness

`tool/bench/` measures what the current worker costs. It does not change product
behavior and sets no budgets (Feature #14, decision #31). `sync_bench.dart`
drives the real `SyncEngine`, `RootTree`, `Manifest` and entry projection
against a synthetic root of N nested files. Sizes are 80% 1–16 KiB, 18%
16–256 KiB and 2% 256 KiB–2 MiB, about 54 KiB on average. The remote side is an
in-memory listing that already matches the seeded, synchronized manifest.
Instrumentation lives in benchmark subclasses only.

For each N it reports:

- warm and page-cache-evicted local scan+hash;
- one manifest rewrite and one projection/emit;
- steady in-sync passes: wall time, CPU seconds, `/proc/self/io`, SQLite rows
  written (`total_changes()`), context switches, peak RSS and manifest
  rewrites;
- a replica of the worker's 2 s idle loop, with write-to-notice and
  write-to-upload-dispatch probes;
- the unmodified `syncWorker` isolate while unpaired (`DisconnectedCloud`, so it
  stops after the local pass).

CPU and context switches come from `getrusage`, so threads that exited are
still counted. Each run records the `git` HEAD, the dirty state of the checkout
under test, and the `--work` filesystem.

`--tick-budget-seconds` ends a pass that runs too long. It only fires at a
`Manifest.save()` boundary, and every firing is counted: such a pass is marked
`completed: false`. Its CPU, rchar, rows and bytes are then lower bounds plus a
linear extrapolation, labelled as such. That extrapolation assumes the
per-file-save design of b35f858.

```bash
cd apps/client
./tool/build_rootfs.sh
export ANJ_ROOTFS_LIBRARY="$PWD/.dart_tool/libanj_rootfs.so"
"$FLUTTER_SDK/bin/dart" run tool/bench/sync_bench.dart --files 1000 \
  --work /path/on/disk/scratch --out /path/to/evidence/bench/sync_bench_1000.json \
  --online-ticks 3 --tick-budget-seconds 600 --idle-seconds 120 \
  --offline-seconds 120 --probes 3
# Spec #15: add --watched-seconds 150 --save-probes 10 for the real WorkerLoop
# with inotify (idle window spanning M, then fresh-file save-to-upload latency).
# Or a serial set with external /proc sampling, then the summary table:
tool/bench/run_baseline.sh /path/to/evidence 1000 10000 50000
python3 tool/bench/summarize.py /path/to/evidence
```

### Comparing before and after

When comparing two builds (for example a 10x reduction gate):

- **Compare per-pass and per-state figures:**
  - `online_ticks` (real `SyncEngine.tick`): CPU seconds, `rchar` bytes and
    rows written per pass;
  - `offline_worker_idle` (the real `syncWorker`): CPU seconds and `rchar` per
    emitted state.

  CPU % and per-second rates saturate for any busy pass, so they cannot show a
  per-pass reduction.
- **Do not gate on the replicas.** `online_idle` and the benchmark's `emit()`
  are copies of `worker.dart` at b35f858 (Timer.periodic 2 s + tick + full
  projection). They will not follow later scheduling or emit-on-change work.
  Treat them as baseline context only.
- **Use `rchar`, not `read_bytes`.** Steady-state scans hit the page cache, so
  `read_bytes` is about 0.
- **Keep the setup identical.** Use the same `--work` filesystem before and
  after, on a disk and not tmpfs; the run warns on tmpfs. Use the same N,
  machine and governor.
- **Run at least 3 online ticks and compare the last.** The first pass after a
  storage or format change can include one-time migration work, such as
  re-hashing to establish stamps.
- **Check the source records.** `summarize.py` puts each run's recorded source
  in `summary.json` and warns when the runs disagree.

The fixture directory is deleted at the end unless `--keep` is given. It is
also deleted on an exception or on SIGINT/SIGTERM, but not on SIGKILL. Check
free space first: 50k files is about 2.7 GiB. Run one benchmark at a time, and
not alongside `tool/check.sh`. The benchmark runs under `dart run` (JIT), not
the AOT release build. It has no UI isolate, no rendering and no real DAV/TLS
transport.

`sample_process.py` passively samples a running client from `/proc` and `ss`:

- CPU, RSS and PSS;
- I/O;
- context switches, accumulated per thread (a lower bound if threads exit);
- threads;
- byte counters for its gateway socket.

It only reads. It never signals or attaches to the process:

```bash
python3 tool/bench/sample_process.py --pid PID --duration 600 --interval 1 \
  --remote-port 8834 --out-dir /path/to/evidence --label installed_idle
```
