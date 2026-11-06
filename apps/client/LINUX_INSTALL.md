---
title: Linux installation
tags: [linux, installation, updates]
date: 2026-11-02
project: anj-cloud
purpose: Install verified user releases
---

## Release scope

This installer accepts reviewed **local Linux x86_64 archives with profile
lifetime protocol 1**. Older prototype archives have no lifetime guard and are
rejected. The initial installer itself is trusted code: obtain `tool/linux_install.py`
from the reviewed source handoff. Checking an archive with an untrusted checker
does not establish trust. Obtain the expected SHA-256 independently through the
reviewed release handoff, rather than trusting a checksum beside an unknown file.

Distribution from this private repository needs authenticated access. The
installed client needs no repository credentials. Updates include the reviewed
manager code inside the authenticated payload; the installed command updates
both manager and client from that one archive, either explicitly (below) or
from the app's **Update now** ([In-app update](#in-app-update)), which takes a
release signed with the household key from the household server. There is no
unattended update, system service or installer network request.
Start at login is **on by default** for managed installs (see
[Start at login](#start-at-login)); it is a per-user desktop entry, not a service. The generic Debian build pipeline and ELF/dependency audit remain the
release gates; x86_64 glibc is the qualified architecture/runtime, not every Linux
architecture or libc.

## Prerequisites

Use a normal per-user Linux desktop session. The manager needs Python 3.11 or
newer, glibc `ldd`, OpenSSL 3+ at `/usr/bin/openssl`, and GLib's `gdbus` at graphical launch. The runtime
requires GTK3, GLib/GIO, libsecret, the audited graphics/font/C++ libraries, Linux
`openat2` support (kernel 5.6+) and an available Secret Service desktop keyring.
Some app operations additionally require the already-qualified filesystem's
write leases and descriptor-relative operations. Installation checks each
bundled ELF's dynamic dependencies; launch checks the graphical session and
Secret Service connection without reading secrets. An available service does
not establish that its collection is unlocked: unlock your ordinary desktop
keyring if the app requests it. The installer never installs OS packages or
changes keyring/desktop permissions.

A terminal install is not proof of a working graphical launch. A sandbox's
read-only home and a host permission error are different prerequisites; neither
is repaired by chmod/chown. Run the trusted installer from the intended user's
normal writable seat.

## First installation

Close the known prototype app normally and observe that **that process has
exited** before adopting an existing paired profile. An incomplete sandbox
process list is not sufficient. Old binaries do not implement the new lock;
reopening one can still bypass it. Retire old launch shortcuts deliberately.

From the trusted source checkout, replace the example paths and digest with the
reviewed handoff values:

```bash
python3 apps/client/tool/linux_install.py install '/path/to/reviewed.tar.gz' \
  --sha256 REVIEWED_64_HEX_DIGEST \
  --profile-dir '/absolute/existing/profile' --legacy-app-closed
"$HOME/.local/bin/anj-cloud" status
"$HOME/.local/bin/anj-cloud" run
```

`--legacy-app-closed` is the operator's explicit confirmation of the observed
exit, not an automatic process scan. The selected profile is canonicalized and
stored **by reference**. Profile, keyring identity, sync root and private recovery
files are neither moved nor copied. Launch always passes the recorded profile
as one literal argument.

For an unpaired new installation, omit `--profile-dir`; the stable new profile
is `$XDG_DATA_HOME/anj-cloud/profiles/default`. If a conventional raw-bundle
profile already exists, installation asks you to select it explicitly rather
than silently opening a fresh unpaired profile. Direct raw-bundle no-argument
launch preserves the existing `path_provider` application-support resolution,
then `anj-cloud/default`; it does not switch to the manager's new default.
Use `--profile-dir` explicitly when mixing direct and managed launch. Symlink
aliases of an explicit profile resolve to the same canonical lifetime lock.

## Paths and launch

| Purpose | Default path | XDG override |
| --- | --- | --- |
| Verified releases and managers | `~/.local/share/anj-cloud/releases`, `managers` | `XDG_DATA_HOME` |
| Atomic release/manager/profile selection | `~/.config/anj-cloud/active.json` | `XDG_CONFIG_HOME` |
| Logs | `~/.local/state/anj-cloud` | `XDG_STATE_HOME` |
| Stable command | `~/.local/bin/anj-cloud` | Uses the intended user's home |
| Menu launcher | `~/.local/share/applications/anj-cloud.desktop` | `XDG_DATA_HOME` |
| Harbor menu icon | `~/.local/share/anj-cloud/icons/harbor-cloud-seal-512.png` | `XDG_DATA_HOME` |
| Login start entry | `~/.config/autostart/anj-cloud.desktop` | `XDG_CONFIG_HOME` |
| Login start settings | `~/.config/anj-cloud/autostart.json` | `XDG_CONFIG_HOME` |

Set absolute XDG paths before first installation. The generated launcher embeds
the installation's config location, so later desktop launches use that selection
even when their environment differs. Use `--installation /absolute/config/anj-cloud`
before the command when invoking the trusted manager directly for a custom
installation. Existing unrelated launchers, unexpected symlinks and nonprivate
state directories cause refusal; they are not replaced or repaired. Existing
`qualification` and `toolchains` directories are not used as release storage.

Spaces, quotes, backslashes, dollar/backtick characters and percent signs in
installation/profile paths are literal. Desktop launch invokes Python with the
launcher as a quoted argument, avoiding GLib's executable-position percent
lookup issue. The Python interpreter executable itself must not contain `%` or
`=`; use the distribution's ordinary Python executable. Control characters in
paths and relative XDG overrides are unsupported.

Choose **AnJ Cloud** in the desktop menu or run `~/.local/bin/anj-cloud run`.
The menu and native window use the selected Cloud Seal / Harbor icon, copied
from the tracked Flutter asset into each verified bundle. The menu references
an app-owned stable icon outside the release directories; no shared icon theme
is changed. The window loads the bundled icon relative to its own executable,
so direct bundle launches also carry the icon. Desktop support determines how
the window icon is displayed; the application ID, executable, command and
profile paths keep their existing identifiers.

The command prints the exact child PID, source, profile and diagnostic log,
then waits for its own child (`run --background` returns at once instead; see
below). GTK and application stdout/stderr go to `client.log`; manager
transactions go to `manager.jsonl`. A second same-profile launch starts no
additional process: it asks the running app to show its window over the session
bus (a per-profile name, `cloud.anj.AnjCloud.p…`, method `Activate`), prints
`"already_running": true, "activated": true` and exits 0. If the running app
cannot be reached (an older client, no session bus) it exits 1 and says so.
Different profiles may be launched directly with explicit `--profile-dir`.

## Tray, closing and quitting

Sync runs independently of the window. AnJ Cloud shows a system tray item
(StatusNotifierItem) with its status (Up to date, Syncing, Paused, Offline,
Needs attention), **Open**, **Pause sync / Resume sync** and **Quit**. The same
actions are in the window's menu.

| You do | With a system tray | Without a system tray |
| --- | --- | --- |
| Close the window | The window hides; sync continues | AnJ Cloud quits cleanly after a notice that sync stops (asked until confirmed once) |
| Choose Quit | Sync stops at a safe point, then the app exits | Same |
| Tray disappears while the window is hidden | The window is shown again | — |

KDE Plasma provides a tray host. GNOME needs an AppIndicator/KStatusNotifierItem
extension; without one there is no tray and closing the window quits. The tray
is implemented over D-Bus in the app itself and adds no library dependency.

Quit waits for the worker to finish or safely abandon its current step (never
mid-commit), keeps queued work durable for the next start and closes the local
database, then exits. A transfer still running after 5 seconds is abandoned and
retried on the next start. Normally Quit completes within 20 seconds with the
database closed. If the worker cannot reach a safe point within that bound (for
example while hashing one very large file) it is stopped and the app exits a
few seconds later (about 25 seconds worst case); this is equivalent to a crash
and is recovered on the next start, as before. Logging out (SIGTERM) quits the
same way; a session manager that kills sooner has the same crash-equivalent
outcome.

**Pause** persists in the profile across restarts. Pause stops file sync, not
credential upkeep. While paused no file data or file metadata is sent to or read
from the server (no listing, upload, download, deletion, folder creation, move
or polling), no file in the folder is changed by sync, and local changes are
still noticed (the window shows how many) and sync after **Resume**. The one
request that continues is the device certificate check
(`GET /v1/device/certificate`), so a device paused across a certificate
reissue keeps its enrollment instead of having to pair again.
Creating a folder and keeping both versions of a conflict are refused while
paused (resume first); storage choices, deletions and finished edits chosen
while paused are recorded and carried out after you resume.

While running, the app lists the server about every 30 seconds when idle, at
once when the window is shown or sync is resumed, more often for a short while
after its own changes, and with increasing delays while the server is
unreachable. Local edits still sync within seconds.

## Start at login

Managed installs start AnJ Cloud when you log in, hidden in the tray. This is
**on by default** for new installs and for existing installs updated to this
release. Turn it off in the window menu (**Start at login**, shown only for
manager-launched apps) or from a terminal:

```bash
"$HOME/.local/bin/anj-cloud" autostart disable
"$HOME/.local/bin/anj-cloud" autostart enable
"$HOME/.local/bin/anj-cloud" autostart status
```

The manager is the only writer of `~/.config/autostart/anj-cloud.desktop`. It
writes exactly its own owner-marked entry (`Exec=… anj-cloud run --background`)
and removes exactly that file on disable. A different file at that path, or the
entry changed outside AnJ Cloud (for example hidden by desktop settings), is
left untouched and reported; enable and disable then refuse until you remove or
restore it. Once you turn it off, updates and runs never turn it back on; the
setting lives in `~/.config/anj-cloud/autostart.json`. A future uninstall must
remove this entry as one of its exact owned files; until then, opt out with
`autostart disable`.

If a release with an older manager (one without `autostart`) becomes selected
again, that manager neither knows nor removes the entry, and the entry's
`run --background` fails harmlessly at login with that manager. To remove it by
hand, first check that it is AnJ Cloud's own entry, then delete exactly that
file:

```bash
entry="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/anj-cloud.desktop"
grep -qx 'X-Anj-Cloud-Owner=anj-cloud-linux-install-v1' "$entry" && rm -- "$entry"
```

Keep `~/.config/anj-cloud/autostart.json`: a later manager with login start
then reports the entry as removed and does not turn it on again (deleting the
settings file would make it apply the default once more).

At login, `run --background` waits up to two minutes for the session bus and
the Secret Service keyring, then starts the app hidden and returns (no resident
manager process). The app waits up to 30 seconds for a tray; without one it
opens its window with a note. If the keyring never answers, the app opens
visibly so it can report the locked keyring. Without a session bus nothing is
started and `manager.jsonl` records why.

## In-app update

Spec #37 U-linux, decision #159. A release built from a commit whose
`assets/release/household-release-key.pub` holds the household release key,
and started by the installed manager, updates itself from the household
server:

1. At start (once the device is paired and the server answers) and every 6
   hours, the app asks `GET /v1/client/releases/linux-x86_64` over its device
   certificate. A release that is not newer than the running one (its
   receipt's `version_code`) is ignored.
2. Before downloading, it verifies the manifest's Ed25519 signature against
   the public key **built into the running app**, the key id, the target and
   the version code. It then downloads the package in the background into the
   profile's private `updates/` folder (size and SHA-256 checked while it
   streams) and has the installed manager check the exact files
   (`anj-cloud apply-update … --check`).
3. One notice: **Update available (version X) — Update now / Later**. Later
   hides it until the next 6-hourly check. When the server's manifest has a
   `min_client_version_code` above this version, the notice and status say
   **Update required**; sync keeps working.
4. **Update now** waits while files are syncing or a Finish editing is still
   pending (the notice says what it waits for; Cancel goes back), then starts
   `anj-cloud apply-update <archive> --manifest <json> --result <json>`
   detached and quits AnJ Cloud cleanly. The manager verifies everything again
   against the key in the **installed** release (never one from the download),
   checks the archive's receipt against the signed version, waits up to 2
   minutes for the app to exit, installs through the same transaction as
   `update`, deletes the download, writes its outcome and starts the app again
   with its window shown (`anj-cloud run --detach`, through the stable command,
   so the new manager launches the new release). The app shows **Updated to
   version X** once.

Any failed check discards the download, installs nothing and shows only
**Update could not be verified** in the status (the reason is its tooltip and
in `manager.jsonl`). Once the app has quit for an update, `apply-update` always
answers and restarts it, whatever goes wrong (a refusal, a missing download, a
full disk, an unreadable installation):

- it writes its outcome to the profile's `updates/result.json` whenever the
  paths it was given are that folder's, and deletes the download;
- it installs only if the app exits within **2 minutes**; otherwise the
  previous release stays active;
- it starts the app again once it has exited, if that happens within **7
  minutes** (the 2 minutes plus 5); an app still running after that is left
  alone and its next start shows the outcome;
- when the installation itself cannot be read, it waits for the app's process
  (`--app-pid`) instead of its profile lock.

The app then shows **Updated to version X** or **Update could not be installed**
(the reason as tooltip). A second `apply-update` started while one runs changes
nothing and writes nothing. Update now waits only until nothing is syncing (a
transfer still finishing after Pause counts); a transfer that starts in the
moment between that check and the quit is stopped by Quit as usual and resumes
after the restart. A release made before the household key existed, a
development build and a directly launched bundle show no updates. The first
release with this updater is installed with the explicit update below; every
later one can come from the app. The `apply-update` command accepts files only
in the selected profile's `updates/` folder.

## Explicit update

For the first Harbor-branded release, invoke the **new reviewed manager** once
instead of the previously installed command. The previous manager can select
the new client and manager, but cannot publish the new desktop branding during
that same update. Verify both the archive digest and the new manager's digest
through the independent reviewed handoff before invoking it:

```bash
python3 /path/to/reviewed/apps/client/tool/linux_install.py \
  --installation /absolute/existing/config/anj-cloud \
  update '/path/to/reviewed-harbor.tar.gz' --sha256 REVIEWED_64_HEX_DIGEST
```

Use the existing installation config; this update retains its selected profile
by reference. Only the exact desktop entry generated by the older manager is
upgraded. Edited or unrelated entries and different files at the reserved icon
path cause refusal. A failed activation can leave the valid stable icon and
upgraded presentation in place while the prior release/profile remains active.
New branded bundles include the required, receipted icon without changing
profile lifetime protocol 1. There is no launch-time desktop modification.

After that one-time update, use the stable installed command for later releases.
Quit the installed app (tray or app menu **Quit**; closing the window only hides
it when a tray exists), then run:

```bash
"$HOME/.local/bin/anj-cloud" update '/path/to/next-reviewed.tar.gz' \
  --sha256 NEXT_REVIEWED_64_HEX_DIGEST
"$HOME/.local/bin/anj-cloud" status
"$HOME/.local/bin/anj-cloud" run
```

An update cannot select a different profile. It acquires the installation lock
before the profile lock and refuses while the profile is active (the app is
still running in the tray: quit it first). A launch cannot
cross that transaction. The child inherits the actual locked open description;
the native runner marks it close-on-exec before GTK/plugins start, and the native
profile gate validates canonical ownership, inode and exclusive kernel lock
before the app opens its database/keyring. The separate Manifest lock is not a
lifetime lock. Kernel closure releases the guard after a crash; stale PID text
is never treated as authority. Never unlink `.instance.lock` to bypass a busy
profile, and do not pass `--profile-lock-fd` manually.

The manager snapshots and hashes the supplied archive privately, then validates
bounded tar members, exact receipt/payload hashes and runtime prerequisites.
Complete read-only payloads are published by rename. One atomic activation
record selects both the trusted manager and the release only after validation.
Failure or interruption before that commit retains the prior activation/profile.
A crash can leave an inactive verified release or an app-owned `.stage-*`
directory; neither is selected implicitly. On restart, `status` reports the
committed record and an explicit retry uses a new stage.

Prior payloads are retained, but there is **no automatic binary downgrade,
database restore, cleanup/prune or uninstall command**. An older binary may not
understand a newer database/journal. Retaining it is diagnostic and permits only
a separately qualified recovery procedure. Program removal must be handled by
a later exact-owned-files procedure; never remove profile/root/recovery/keyring
or cloud data as part of program cleanup.

### Updating to the tray and login-start release

No bootstrap step is needed. The installed command (manager
`a2ba2380…`) verifies and activates this release and its new manager exactly as
for any update. That older manager cannot know about login start, so the update
itself writes no autostart entry. The first `anj-cloud run` afterwards (menu or
terminal) runs the new manager, which turns Start at login on once (default-on
for existing installs), records it in `autostart.json`, and the app announces it
once in its window. A foreign file at the autostart path is reported, never
replaced. Earlier managers keep reading this installation: `installation.json`
gains no keys.

## Switching to a new profile (production pairing)

Production pairing is a one-time re-pairing onto a new, unpaired profile (spec #23, decisions #61, #82). The home folder is the root, so the files land in `~/anj-cloud/`. Quit AnJ Cloud first; both commands refuse while the app holds the current profile.

```bash
anj-cloud select-profile --new ~/.local/share/anj-cloud/profiles/production
```

`--root` defaults to the home folder (spec #34 P1); give it only for another parent folder.

The rules:

- The root may already hold other files. Its `anj-cloud/` folder, which the app creates and syncs, must not exist yet.
- That folder must also not be, contain or lie inside another known profile's synced folder, staging or profile directory, or a folder reserved for another profile. These are read from each profile's manifest, and the dev profile is always known.
- The profile directory must not exist yet, or be an empty private directory.
- Dev or synthetic data is never adopted. The root's mode is never changed.
- Only `active.json` and the separate `profiles.json` record change. The previous profile is never modified.
- The stable command, desktop entry and login start follow `active.json`.

Start the app. A new profile creates `anj-cloud/` in that root by itself (the manager passes the reserved root as `--default-root` until the profile records its root), with private staging inside the profile directory when it is on the same filesystem, and an **AnJ Cloud** link to it on the desktop once. If the folder already exists or overlaps, the app shows why and offers **Use another folder** (the folder picker; paste the printed `known_roots` into its overlap check). Then enter the production invitation.

Switch back to an existing profile (rollback while the dev stack exists) under
the same adoption guard as installation:

```bash
anj-cloud select-profile ~/.local/share/anj-cloud/profiles/default --legacy-app-closed
```

## Moving the synced folder (move-root)

A profile paired with the folder picker before spec #34 keeps its folder where
it was chosen, for example `~/AnJ Cloud/anj-cloud/` with the staging folder
`~/AnJ Cloud/.anj-cloud-<profileId>/` beside it. `move-root` puts it where a new
install has it, `~/anj-cloud/`, with the **AnJ Cloud** desktop link. It renames
the folder; nothing is copied, uploaded, downloaded or deleted, and the next
start continues syncing it as the same folder. Linux only.

Quit AnJ Cloud first (tray or app menu **Quit**; closing the window only hides
it), then run it from a terminal in your desktop session:

```bash
"$HOME/.local/bin/anj-cloud" move-root
```

`--to /absolute/path/anj-cloud` chooses another place; the folder must be named
`anj-cloud`. The installed release must include move-root (update first). The
command prints what it moved as JSON, for example `"from"`, `"to"`, the new
`"staging"` and the old `"stagingFrom"`, the folders it `"removed"` and the
`"desktopShortcut"` outcome.
Then start AnJ Cloud.

What it does:

- Renames the folder with `rename(2)` (`RENAME_NOREPLACE`), so it keeps its
  inode and birth time and the profile's recorded folder identity still
  matches. A target on another filesystem or btrfs subvolume is refused;
  move-root never copies.
- Staging ends where a new profile has it: inside the profile when renames
  reach the new folder from there, otherwise `.anj-cloud-staging-<id>` beside
  the new folder. It moves first, as a whole and by rename, with the copies it
  keeps (downloads stay there as second names of the synced files; upload and
  kept copies too), and the profile's record of it and of every file in it
  switches in one step. Nothing in it is copied or deleted.
- The old parent folder (`~/AnJ Cloud`) is removed only when it is empty, and
  never when it is the home folder or one of the desktop's user directories.
- The **AnJ Cloud** link is made in the desktop directory (as
  `xdg-user-dir DESKTOP` names it) if this profile never made one. A link this
  profile made to the old place is pointed at the new one (`updated:`); if it
  cannot be replaced it is reported `stale:` and the printed `next` says so.
  Any other entry named **AnJ Cloud** is left alone.
- Nested case: when the target is the folder's own parent (`~/anj-cloud/anj-cloud`
  becomes `~/anj-cloud`), the parent may hold only the folder and this
  profile's staging folder (which moves out first). The folder is renamed aside to
  `.anj-cloud-move-<profileId>`, the emptied parent removed and the folder
  renamed into its place. Anything else there is listed and refused.

It refuses, changing nothing, when:

- AnJ Cloud is running for this profile (the profile lifetime lock);
- the target already exists (other than the nested case);
- the staging folder holds unfinished work (an upload, deletion, edit or
  other operation still in progress; finished copies do not count): open AnJ
  Cloud, let it finish syncing (and **Finish editing** a file open for
  editing), quit, and run move-root again;
- the staging place in the profile already holds files;
- the folder is not the one the profile recorded (its identity check fails):
  start AnJ Cloud once so it checks and records the folder, quit, retry;
- the target is inside the current folder, or overlaps another known
  profile's folder, staging or profile directory, or this profile's own
  directory;
- there is no desktop session (the app runs without a window, but GTK still
  needs the session).

Interruption: the move is recorded in the profile before the first rename. If
the command is interrupted (power loss, a killed process), run it again with
the same target: it finishes the move. Starting AnJ Cloud instead also
finishes it once the synced folder has been renamed, or forgets it when the
synced folder was not renamed yet (a staging move already begun is finished
first; staging in the profile with the folder in its old place is a valid
state). If the app can do neither, it shows why and does not sync until
move-root is run again. If the folder can be found at none of the recorded places, the
record stays and the app and the command say where it was expected.

The manager holds the installation and profile locks and runs the active
release's client with `--move-root` on the held lock (no window, no sync); the
client owns the profile's database and makes every change
(`lib/core/local/root_move.dart`). `manager.jsonl` records `root_move_started`
and `root_move_finished` with the outcome; GTK output goes to `client.log`.

## Verification

```bash
python3 -m unittest discover -s apps/client/tool -p 'test_linux_install.py' -v
python3 -m unittest discover -s apps/client/tool -p 'test_inspect_linux.py' -v
apps/client/tool/check.sh
```

Installer tests need the development compiler, `desktop-file-validate` and `gio`.
They use private temporary trees, real native locks/children, actual desktop
argument parsing, interrupted publication and malformed archives. Their synthetic
ELF source IDs test manager mechanics; they are not two released application
versions. `check.sh` serializes test files because concurrent `dart run` crash
fixtures publish SQLite native assets into a shared, temporarily partial path;
this avoids the observed test-loader SIGBUS rather than ignoring a failed run. Separately qualify two actual committed/generically built releases,
paired-profile preservation and protected sync readback, then installed launch on
the VM host and a second computer with exact own-process/source/profile evidence. Those deployment
gates are not established by unit tests or generic-builder rendering.
