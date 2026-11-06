# AnJ Cloud

Household file sync and private inference access, from a gateway you host yourself.
One small server at home, matching apps on Linux, macOS, Windows and Android, and one place to say who and
which devices may connect.

![The library on an Android phone: filter chips, search, sync and share badges](docs/images/android-library.png)

## What it does

- **Sync your files between your own devices.** Each device keeps a local folder in step with the household
  cloud. Folders can stay in the cloud and download only when opened, and local space can be freed without
  deleting anything remotely. Conflicts keep both versions.
- **Share folders inside the household.** An owner shares a folder with other household accounts, read only or
  editable, and the recipients see it as "Shared by ...".
- **Pair a device with a code.** An admin creates a one-time code (ten minutes). Typing it on a new device
  pairs it: the code also carries the pin of your household's certificate authority, so there is nothing else
  to install or trust by hand. Devices keep their own keys; an admin can revoke any device.
- **Update the apps from your own server.** The gateway serves each client's next release. Desktop releases are
  signed with a key you own; Android releases must carry your Android signing certificate.
- **Administer from the app.** Users, invitations, devices, settings, health and activity are in the Admin
  section for household admins.

| Library, search and filters | Sharing |
|---|---|
| ![Search on the desktop client](docs/images/desktop-search.png) | ![Folders shared with the household](docs/images/desktop-sharing.png) |

| Recent files | Managing who a folder is shared with |
|---|---|
| ![The Recent filter lists the latest files with Show in folder](docs/images/desktop-recent.png) | ![The Manage sharing dialog with two household members](docs/images/desktop-manage-sharing.png) |

## Status

AnJ Cloud is young software built for one household first.

| Platform | State |
|---|---|
| Gateway (a Linux host running a VM) | In use. **[Server setup guide](docs/self-hosting/README.md)** |
| Linux client (x86_64) | Usable: installer, tray, start at login, in-app update |
| Android client (arm64) | Usable: signed APK, in-app update |
| macOS client (Apple silicon) | Usable: installer, menu-bar item, in-app update |
| Windows client (x86_64) | Installer exists (install, update, run, start at login, uninstall); in-app updates are not available yet |

Inference access (routing paired devices to your own model gateway) is planned and is not part of this
repository yet.

## Set up your server first

Every client needs a gateway to pair with, so start there. The **[server setup guide](docs/self-hosting/README.md)**
walks through it end to end: [requirements](docs/self-hosting/requirements.md) (a Linux host with KVM, a domain,
Cloudflare DNS), [the VM host and gateway VM](docs/self-hosting/host-and-vm.md),
[DNS, TLS and port forwarding](docs/self-hosting/dns-tls-forwarding.md),
[accounts and the first device](docs/self-hosting/accounts-and-pairing.md),
[backups and restore](docs/self-hosting/backups.md), [upgrades](docs/self-hosting/upgrades.md),
[your release keys and publishing client releases](docs/self-hosting/keys-and-releases.md), and
[troubleshooting](docs/self-hosting/troubleshooting.md).

## Install a client

You need a pairing code from your server's admin ([how to make one](docs/pairing.md)). The commands below use
placeholders: `gateway.example.com` is your server. Each section says how to get the app, how to install it,
and how to pair. Fuller instructions are in [docs/clients.md](docs/clients.md).

### Linux

- **Get it:** build the release archive from a clean checkout (Docker is used for an isolated build), or take the
  archive your server's admin built:
  `python3 apps/client/tool/package_linux.py /absolute/absent/output-dir`. It prints the archive's SHA-256.
- **Install** (no root; installs under your home directory, adds the `anj-cloud` command and a menu entry):
  `python3 apps/client/tool/linux_install.py install <archive>.tar.gz --sha256 <hex>`, then
  `~/.local/bin/anj-cloud run`. It needs a desktop keyring (GNOME Keyring or KWallet); the tray item needs a tray
  host (KDE has one; GNOME needs an AppIndicator extension).
- **Pair:** choose **Pair device**, check the server is `https://gateway.example.com`, type the code, pick a local
  folder. Updates then arrive in the app.

### macOS (Apple silicon)

- **Get it:** on a Mac with Xcode command line tools and the pinned Flutter SDK, from `apps/client`:
  `zsh tool/macos/package_release.sh build/release`; it writes a `.zip`, its `.sha256` and a receipt.
- **Install:** `sh tool/macos/anj-cloud-macos-install.sh install <zip> --sha256 <hex>` (no sudo; installs to
  `~/Applications`, ad-hoc signed; `autostart on` enables start at login).
- **Pair:** open the app, **Pair device**, server `https://gateway.example.com`, code. Later updates arrive in the app.

### Windows (x86_64)

- **Status:** an installer and update manager exist; **in-app updates are not available yet**, so you update by
  running the manager again with a new archive. Treat it as early.
- **Get it:** on Windows with Visual Studio Build Tools 2022 (C++ workload and ATL) and the pinned Flutter SDK,
  build with `flutter build windows --release`, then package with `apps/client/tool/windows/package.ps1`; it writes
  a `.zip` and prints its SHA-256.
- **Install:** run the packaged `anj-cloud-manager.exe install <zip> --sha256 <hex>`, then `run`;
  `autostart enable` starts it at login.
- **Pair:** as on the other desktops.

### Android (arm64)

- **Get it:** the first install comes from the signed APK on this repository's
  [GitHub Releases](https://github.com/jedbjorn/anj-cloud/releases) page, if its publisher attached one, or from an
  APK you build for your own household (`apps/client/tool/android/release_android.py build`). The release page
  shows the APK's **SHA-256**: compare it with `sha256sum <apk>` before installing.
- **Install:** open the APK on the phone (allow installs from that source). Android only installs later updates
  signed with the same certificate; the app offers them from your server.
- **Pair:** open the app, **Pair device**, enter the server and the code (or **Scan QR code**), choose a folder.

Use the APK from a release only if you trust its publisher: a release built by someone else is signed by their
key, so it can only update from their server. To run your own server, build and sign your own
([keys and releases](docs/self-hosting/keys-and-releases.md)).

## Documentation

- [Overview and architecture](docs/overview.md)
- [Self-hosting the gateway](docs/self-hosting/README.md)
- [Installing the clients](docs/clients.md)
- [Pairing a device](docs/pairing.md)
- [Updates and release signing](docs/updates-and-signing.md)
- [Development and testing](docs/development.md)

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md). Report vulnerabilities
privately as described in [SECURITY.md](SECURITY.md).

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
