# Installing the clients

All clients are built from `apps/client/`. Release archives are produced by the packaging tools below and are
installed with a checksum you pass explicitly. Builds carry your gateway's address and, for desktop updates,
your release key, both read from your deployment profile at build time (see [self-hosting/README.md](self-hosting/README.md)).

| Platform | State | Install |
|---|---|---|
| Linux x86_64 | Usable | `linux_install.py` from a packaged archive |
| macOS (Apple silicon) | Usable | `anj-cloud-macos-install.sh` from a packaged zip |
| Android (arm64) | Usable | Signed APK |
| Windows (x86_64) | Early | `anj-cloud-manager.exe` from a packaged zip; no in-app updates yet |

## Linux

Needs a desktop session with a secret-service keyring (GNOME Keyring or KWallet) and, for the tray item, a
tray host (KDE Plasma has one; GNOME needs an AppIndicator extension).

```bash
# Build a release archive from a clean checkout of a commit (Docker is used for an isolated build):
python3 apps/client/tool/package_linux.py /absolute/absent/output-dir

# Install it (the digest is in the printed output and the .sha256 file next to the archive):
python3 apps/client/tool/linux_install.py install /path/to/anj-cloud-linux-x86_64-<commit>.tar.gz --sha256 <hex>
~/.local/bin/anj-cloud status
~/.local/bin/anj-cloud run
```

The app installs under your home directory (no root), puts a menu entry and the `anj-cloud` command in place,
starts hidden in the tray, and keeps syncing when the window is closed. Start at login is a toggle in the app
(`~/.config/autostart/anj-cloud.desktop`). `apps/client/LINUX_INSTALL.md` is the full reference: paths, tray
behavior, in-app and explicit updates, switching profiles, and moving the synced folder.

## macOS

Needs Apple silicon and a Mac with Xcode command line tools and the pinned Flutter SDK for building.

```bash
# On the Mac, from the client directory, build and package a release:
zsh tool/macos/package_release.sh build/release
# Install or update with the manager (POSIX sh, no sudo, base macOS tools only):
sh tool/macos/anj-cloud-macos-install.sh install build/release/anj-cloud-macos-arm64-<version>.zip --sha256 <hex>
```

The app is ad-hoc signed. The manager installs into `~/Applications`, can enable start at login, and the app
updates itself from your gateway afterwards (after you install a first release by hand). See
`apps/client/ARCHITECTURE.md` (macOS) for what the manager guards: journaled swaps, a launch check and
automatic rollback.

![The macOS client before pairing: choose a root folder, then pair this device](images/macos-pairing.png)

## Android

```bash
python3 apps/client/tool/android/release_android.py keygen    # once: your signing key (keep an offline copy)
python3 apps/client/tool/android/release_android.py build /absolute/absent/output-dir
```

Install the signed APK on the phone (allow installs from the source you use). From then on the app offers
updates it downloads from your gateway; Android installs them only if they carry the same signing certificate
(see [updates-and-signing.md](updates-and-signing.md)). The synced folder is a folder you choose in shared
storage, visible to file managers and other apps you authorize.

## Windows

An installer and update manager exist; **in-app updates are not available yet**, so you update by running the
manager with a new archive. Treat the Windows client as early.

Building needs Windows x86_64 with Visual Studio Build Tools 2022 (C++ workload and C++ ATL) and the pinned
Flutter SDK (`apps/client/tool/windows/install.ps1` installs them on a build seat).

```powershell
# in apps\client, after `flutter build windows --release`:
powershell -File tool\windows\package.ps1 -SourceHead <40-hex commit>   # writes the zip and prints its SHA-256
# install or update (the manager runs from the unpacked release; get its checksum separately):
anj-cloud-manager.exe install <zip> --sha256 <hex>
anj-cloud-manager.exe run
anj-cloud-manager.exe autostart enable      # start at login; also: status, disable
anj-cloud-manager.exe uninstall             # removes exactly what install added
```

`update <zip> --sha256 <hex>` refuses while the app runs. The app keeps its secrets in Windows DPAPI and shows a
notification-area icon. Pairing is as on the other desktops.

## First launch on any platform

1. Open the app and choose **Pair device** ([pairing.md](pairing.md)).
2. Pick a local folder as your root.
3. Choose which folders stay on the device on the first-sync screen, then **Start sync**.

![The first-sync screen: choose which folders stay on this device](images/android-first-sync.png)
