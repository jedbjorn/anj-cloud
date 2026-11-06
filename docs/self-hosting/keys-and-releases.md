# Your release keys, and publishing client releases

Your gateway can serve each client its next release. Devices accept a release only if it is signed by **your** key:
desktop releases with an Ed25519 key you create once, Android releases with an Android signing certificate you
create once. Nobody else's release will install, and neither key is ever shared with the server.

## Create the keys (once)

```bash
python3 deploy/release.py keygen
python3 apps/client/tool/android/release_android.py keygen
```

- `release.py keygen` creates the private key in `~/.local/share/anj-cloud/release-key/release-key.pem` (directory
  0700, file 0600) and prints the **key id** and the **public key line** (`ed25519 ...`).
- `release_android.py keygen` creates the keystore and its properties in
  `~/.local/share/anj-cloud/signing/android/` and prints the certificate's **SHA-256**.

Put the public values in the `[release]` section of your profile:

```toml
[release]
public_key = "ed25519 ..."            # the line keygen printed
key_id = "..."                        # 16 hex characters
android_signer_sha256 = "..."         # 64 hex characters
```

**Back up both private keys offline now** (password manager, encrypted USB). The keystore password is in the
properties file next to it. Never put them in the repository, in the VM, or in a chat. If the desktop key is lost
nothing breaks until you want to publish: you then rotate, which means reinstalling by hand once per device. If
the Android keystore is lost, every phone must uninstall and reinstall.

Builds read the profile through `apps/client/tool/apply_profile.py`, which writes the public key into the build
(`apps/client/assets/release/household-release-key.pub`, untracked) and sets the default server address.

## Build a release

```bash
# Linux (builds in an isolated Docker container from a clean checkout of a commit):
python3 apps/client/tool/package_linux.py /absolute/absent/output-dir

# Android (a signed APK of a committed source; versionCode comes from the commit count):
python3 apps/client/tool/android/release_android.py build /absolute/absent/output-dir

# macOS (on a Mac): see ../clients.md; Windows (on Windows): see ../clients.md
```

A release can only be built from a commit, and `publish` refuses unless that commit is on `origin/main`: push
your changes first.

## Publish it to your gateway

```bash
python3 deploy/release.py publish --target linux-x86_64 --artifact <archive>.tar.gz --dry-run
python3 deploy/release.py publish --target linux-x86_64 --artifact <archive>.tar.gz
python3 deploy/release.py publish --target android-arm64 --artifact <apk>
```

Always run `--dry-run` first. `publish` checks the commit, the version code (it must be higher than the served
release's), and the signature or certificate against your profile, then uploads it to your gateway in the VM
(over ssh with the VM host's `ssh_config`). Paired devices see "Update available" the next time they check.

## First install of the Android app

The first install of the Android app cannot come from your gateway (the app is not on the phone yet). Publish the
APK as a GitHub release of your fork, which shows the file and its SHA-256:

```bash
python3 apps/client/tool/android/release_android.py github-release --apk <apk>            # shows what it would run
python3 apps/client/tool/android/release_android.py github-release --apk <apk> --create   # creates the release
```

Compare the SHA-256 on the release page with the `.sha256` file before installing.

## Rotating a key

There is no remote revocation. Rotate only if a key is lost or may be known to someone else. The exact steps,
and what every device needs to do afterwards, are in `services/access/README.md` ("Rotating a release key");
publish nothing until you finish them.

Next: [troubleshooting](troubleshooting.md).
