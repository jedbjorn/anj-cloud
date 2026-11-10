# Installing the clients

Official Linux x86_64, macOS arm64 and Android arm64 clients are available from
[GitHub Releases](https://github.com/jedbjorn/anj-cloud/releases). Download your artifact and its `.sha256`
file; compare the digest with the release page, then run the checksum command below. `SHA256SUMS` lists all
artifacts in the release. Replace the example filenames and `<hex>` with the downloaded filename and digest.

Official builds carry the maintainer's keys: the Android APK is signed with the maintainer's APK signing key,
and the desktop apps embed the maintainer's Ed25519 update key (macOS builds are ad-hoc code-signed). They pair with any AnJ Cloud server: type your server
address in the editable **Server** field at pairing. `https://gateway.example.com` is only the default text.
In-app updates are downloaded from your paired gateway and only accept releases signed with those same
keys (Ed25519 on desktop; the Android signing certificate on Android). A household that wants its own update
feed builds and signs its own clients; see [keys and releases](self-hosting/keys-and-releases.md).

Desktop commands below use the install managers from this repository's reviewed source, relative to the
repository root. Obtain that source before installing; an archive checksum alone does not authenticate an
installer script.

| Platform | Official download | Install |
|---|---|---|
| Linux x86_64 | `.tar.gz` | `linux_install.py` |
| macOS (Apple silicon) | `.zip` | `anj-cloud-macos-install.sh` |
| Android (arm64) | Signed `.apk` | Open APK on phone, or `adb install` |
| Windows (x86_64) | None yet | Build your own; `anj-cloud-manager.exe` |

## Linux

Download the Linux archive and checksum from [Releases](https://github.com/jedbjorn/anj-cloud/releases).
Needs a desktop session with a secret-service keyring (GNOME Keyring or KWallet) and a tray host
(KDE Plasma has one; GNOME needs an AppIndicator extension).

```bash
sha256sum -c '<archive>.tar.gz.sha256'
python3 apps/client/tool/linux_install.py install '<archive>.tar.gz' --sha256 <hex>
~/.local/bin/anj-cloud status
~/.local/bin/anj-cloud run
```

The app installs under your home directory (no root), adds a menu entry and the `anj-cloud` command,
starts hidden in the tray, and keeps syncing when the window is closed. Start at login is a toggle in the app.
`apps/client/LINUX_INSTALL.md` is the full reference for installation, updates and profiles.

## macOS

Download the Apple silicon zip and checksum from [Releases](https://github.com/jedbjorn/anj-cloud/releases).
Installing needs only base macOS tools:

```bash
shasum -a 256 -c '<archive>.zip.sha256'
sh apps/client/tool/macos/anj-cloud-macos-install.sh install '<archive>.zip' --sha256 <hex>
```

The manager installs into `~/Applications` without sudo and can enable start at login. The app is ad-hoc
signed, without Apple notarization; its in-app release verification trusts the maintainer's Ed25519 key.
See `apps/client/ARCHITECTURE.md` (macOS) for journaled swaps, launch checks and rollback.

![The macOS client before pairing: choose a root folder, then pair this device](images/macos-pairing.png)

## Android

Download the APK and checksum from [Releases](https://github.com/jedbjorn/anj-cloud/releases).
Check on a computer, then install with Android platform-tools if available:

```bash
sha256sum -c 'anj-cloud-<version>.apk.sha256'
adb install 'anj-cloud-<version>.apk'
```

On macOS use `shasum -a 256 -c` instead. Alternatively, transfer the checked APK to your phone and open it,
allowing installs from that source. Android accepts updates only with the same signing certificate.
The synced folder is chosen in shared storage, visible to file managers and other apps you authorize.

## Building your own clients

Building is an alternative to the official downloads. Set up your deployment profile with your default
server address and release keys ([self-hosting guide](self-hosting/README.md)). The address is editable at
pairing; the embedded release key determines which in-app updates the client accepts.

```bash
# Linux: clean committed source, pinned Flutter SDK and Docker:
python3 apps/client/tool/package_linux.py /absolute/absent/output-dir

# Android: pinned Flutter/Android toolchains; create your signing key once and back it up offline:
python3 apps/client/tool/android/release_android.py keygen
python3 apps/client/tool/android/release_android.py build /absolute/absent/output-dir

# macOS: from the Linux build host, over SSH to a configured macOS build host with Xcode and pinned Flutter:
bash apps/client/tool/macos/release_macos.sh HEAD /absolute/absent/output-dir
```

The packaging tools write checksums alongside the artifacts. Install with the same platform commands above.
Keep your signing keys safe; publish your signed updates through your gateway as described in
[keys and releases](self-hosting/keys-and-releases.md).

## Windows

There is **no official Windows build yet**. An installer and update manager exist, and a build you package
with your own release key can update itself in the app. That in-app update is new and has not been verified on
a Windows machine yet; updating by running the manager with a new archive always works. Treat the Windows
client as early.

Building needs Windows x86_64 with Visual Studio Build Tools 2022 (C++ workload and C++ ATL) and the pinned
Flutter SDK (`apps/client/tool/windows/install.ps1` installs them on a build seat).

```powershell
# in apps\client, after `flutter build windows --release`:
powershell -File tool\windows\package.ps1 -SourceHead <40-hex commit>   # writes the zip and prints its SHA-256
#   add -VersionCode <n> -Version <v> for a build that updates itself in the app (see below)
# install or update (the manager runs from the unpacked release; get its checksum separately):
anj-cloud-manager.exe install <zip> --sha256 <hex>
anj-cloud-manager.exe run
anj-cloud-manager.exe autostart enable      # start at login; also: status, disable
anj-cloud-manager.exe uninstall             # removes exactly what install added
```

`update <zip> --sha256 <hex>` refuses while the app runs. The app keeps its secrets in Windows DPAPI and shows a
notification-area icon. Pairing is as on the other desktops.

**In-app updates.** An installed build offers **Update available** when all of these hold: it was built with
your release key in the tree (`apps/client/tool/apply_profile.py` writes it before `flutter build`), it was
packaged with `-VersionCode` and `-Version` (`python3 deploy/client_version.py <commit>` prints both for a
commit), and your gateway serves a newer `windows-x64` release signed with that key
(`python3 deploy/release.py publish --target windows-x64 --artifact <zip>`, see
[updates and signing](updates-and-signing.md)). On **Update now** the app quits and hands the download to the
installed manager (`apply-update`), which verifies the signature, size and SHA-256 again by the key inside the
installed release, installs the new release beside the old one and starts the app. Your profile, secrets and
synced folder are not touched. If anything fails, the release you were running stays active and is started
again, and the app shows **Update could not be installed**. A build without a release key or version shows no
update notices and is updated with `update <zip> --sha256 <hex>`.

## First launch on any platform

1. Open the app, choose **Pair device**, and enter your server address and pairing code ([pairing.md](pairing.md)).
2. Pick a local folder as your root.
3. Choose which folders stay on the device on the first-sync screen, then **Start sync**.

![The first-sync screen: choose which folders stay on this device](images/android-first-sync.png)
