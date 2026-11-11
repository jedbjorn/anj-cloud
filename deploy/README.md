---
title: Private development stack
tags: [development, nextcloud, pairing]
date: 2026-11-01
project: anj-cloud
purpose: Isolated synthetic qualification
---

# Private development stack

## Deployment profile

Values that belong to one household (domain, addresses, accounts, release key, Android signer pin) are not in tracked code. They come from one TOML profile, `deploy/deployment_profile.py` reads it, and `deploy/profile.example.toml` documents every key with placeholders. Lookup order: `$ANJ_PROFILE`, then `~/.local/share/anj-cloud/profile.toml` (the real profile: keep it mode 0600 and back it up beside the release and signing keys), then `deploy/.local/profile.toml`. With no file the placeholders apply.

- `python3 -I deploy/deployment_profile.py get gateway.host` prints one value; `--json` prints the whole profile.
- Client builds: `apps/client/tool/apply_profile.py` writes the profile's release public key (`assets/release/household-release-key.pub`) and origin (`anj-defines.env`, used as `--dart-define-from-file`) into the tree, both untracked. `package_linux.py`, `release_android.py` and `mac_test.sh send` do this for their own build tree; `check.sh` does it for the checkout.
- Releases: `deploy/release.py publish` to production refuses unless the signing key's id equals `[release] key_id`; Android releases are checked against `[release] android_signer_sha256`.
- Tests run against the placeholders (`deploy/checks.py` sets `ANJ_PROFILE`); set `ANJ_PROFILE=deploy/profile.example.toml` when running `unittest` directly.
- `deploy/host/halo-vm.sh` reads the same file (host name, interface, backup drive UUID, LAN address, router, host name). Only `--dry-run` and `--verify` run without one.

## Run

This is an isolated synthetic development stack, currently qualifying the device-access prototype. It provides no production ingress, household-data migration or inference integration. Docker Compose, Python 3.10+ and OpenSSL 3.6+ are prerequisites; installation of host packages remains operator-owned.

Run from this checkout. Dependencies install into ignored `deploy/.local/access-venv`, with the complete resolved version set pinned in `services/access/requirements.txt`.

```bash
export SC_DEV_PORT=8834
python3 deploy/dev.py deps
python3 deploy/dev.py setup
python3 deploy/dev.py doctor
python3 deploy/dev.py up
python3 deploy/dev.py check
deploy/.local/access-venv/bin/python -m unittest discover -s tests -v
deploy/.local/access-venv/bin/python -m deploy.access_fixture
python3 deploy/dev.py stop
```

Only `https://127.0.0.1:$SC_DEV_PORT` is published, by the access service. Nextcloud, PostgreSQL and Redis are internal. Setup generates a one-year Dev issuer and server certificate; the issuer private key remains in local operator tooling and is never mounted into the access container. Secret directories are 0700, files 0600. No credentials, personal directories or Docker socket are embedded in the access image.

Use the same project name, port, checkout and retained private state for subsequent operations. Independent review can select another project/port with `--project anj-cloud-review --port 18834` on both management and operator commands. Compose prefixes durable volumes and containers with that project name. Do not reuse an existing project's name with different local secrets.

## Pair and operate

A pairing code carries the first 10 bytes (80 bits) of the issuer certificate's SHA-256 (decision #151, spec #35): the client fetches `GET /v1/ca` and accepts the CA only when it matches the code, so no CA file is copied. Never accept a CA the code does not pin, disable certificate validation or omit hostname checks. Certificate/key material stays outside the client's watched root.

```bash
deploy/.local/access-venv/bin/python -m deploy.access_operator trust
deploy/.local/access-venv/bin/python -m deploy.access_operator invite anj-fixture-alice --rights write
deploy/.local/access-venv/bin/python -m deploy.access_operator pending
deploy/.local/access-venv/bin/python -m deploy.access_operator approve PAIRING_ID --fingerprint FULL_DISPLAYED_SHA256
deploy/.local/access-venv/bin/python -m deploy.access_operator devices
deploy/.local/access-venv/bin/python -m deploy.access_operator revoke DEVICE_ID
```

Invitation output intentionally contains a secret for the operator; do not pipe it into logs or PRs. The client generates its P-256 key and signed CSR, reserves the code over TLS, displays the SHA256 public-key fingerprint, and receives the public certificate after matching operator approval. The client certificate is valid until the issuer's expiry (decision #44); revocation, not lifetime, ends access. Devices whose leaf has already expired, or that were revoked, re-pair using bootstrap requests without their expired certificate; local pending files must remain intact.

`approve` obtains an independently named Nextcloud app token using supported `occ user:auth-tokens:add --no-interaction`, checks the canonical UID, signs a fixed clientAuth leaf with OpenSSL and commits activation through the private Unix socket. The local operation lock/journal records issuance intent before creating external credentials. The access service has neither issuer key, account master password nor Docker authority. Password-dependent backend features remain outside the proven credential scope.

### Reissue

```bash
deploy/.local/access-venv/bin/python -m deploy.access_operator reissue DEVICE_ID
deploy/.local/access-venv/bin/python -m deploy.access_operator reissue --active
```

`reissue` reads the active device's stored enrollment request through the private socket, checks it against the registered key, signs a new fixed-profile clientAuth leaf for the same key and subject (`CN=DEVICE_ID`) valid to issuer expiry, and commits it through the socket, which re-verifies issuer, key, subject and profile. Intent is journaled privately under `operator/journals/reissue/` before signing; `reconcile` resolves an interrupted reissue against registry state, and a lost commit response is checked before reporting failure. Revoked, inactive and already-expired devices are refused (`--active` lists expired ones as `skipped`: they re-pair). A device whose leaf already reaches issuer expiry is reported `current` unless `--force` is given. The registry, account binding and app token are unchanged.

The device keeps using its previous leaf until it fetches the new one from `GET /v1/device/certificate`; `devices` shows `transition_leaves` 1 until the device first authenticates with the new leaf, then 0. Revocation refuses every leaf. Issuer rollover (before the one-year Dev issuer expires) and server certificate renewal are separate operator steps not covered here.

### Runbook: deploy permanent credentials to an existing stack

Run from the checkout that owns the project's `deploy/.local/<project>` state (the operator issuer and the access secrets are read from there), updated to the merged change, with `SC_DEV_PORT` set as for that stack. Only the access service is rebuilt and recreated; Nextcloud, PostgreSQL, Redis, cron, volumes and the registry are retained, and the registry gains its transition table on startup. Recreating the access service drops in-flight transfers; clients retry.

```bash
export SC_DEV_PORT=8834
# 1. Preconditions: writes not fenced, and a rollback image of the current gateway.
deploy/.local/access-venv/bin/python -m deploy.access_operator fence          # expect "state": "clear"
docker image tag anj-cloud-dev-access:unit2 anj-cloud-dev-access:pre-permanent-credentials \
  || docker commit --pause=false anj-cloud-dev-access-1 anj-cloud-dev-access:pre-permanent-credentials
docker image inspect --format '{{.Id}}' anj-cloud-dev-access:pre-permanent-credentials
#    STOP if the tag/commit or this inspect fails: do not redeploy without a rollback image.
# 2. Rebuild and recreate only the access service, then check TLS health, ports and backend.
python3 deploy/dev.py redeploy-access
deploy/.local/access-venv/bin/python -m deploy.access_operator fence          # still "clear"; otherwise recover-writes
# 3. Reissue every active device to issuer expiry.
deploy/.local/access-venv/bin/python -m deploy.access_operator reissue --active
# 4. Verify: each reissued device expires at the issuer's notAfter with transition_leaves 1.
openssl x509 -noout -enddate -in deploy/.local/anj-cloud-dev/operator/issuer.crt
deploy/.local/access-venv/bin/python -m deploy.access_operator devices
```

`redeploy-access` runs `docker compose up --detach --build --no-deps --wait access` for this project and then the same TLS health, published-port and backend checks as `check`. Before the client release, a device keeps syncing on its previous leaf. After installing the client release on each device, its worker picks up the new leaf at start: the device's `transition_leaves` drops to 0 and the client's `certificateExpires` setting moves to the issuer's expiry with no re-pairing. A device that never picks up keeps working until its previous leaf expires.

Step 1 tags `unit2` because, on the anj-cloud-dev stack, the running container's `docker inspect` image ID is not resolvable by `docker image tag` (containerd snapshotter), while its `/app/access` code is identical to `unit2` and to the pre-change `main`; `docker commit` of the running container is the fallback. If `unit2` might differ from the running gateway code, use `docker commit` instead.

Rollback (gateway only), from the same checkout:

```bash
docker image tag anj-cloud-dev-access:pre-permanent-credentials anj-cloud-dev-access:unit2
SC_DEV_PORT=8834 \
ANJ_SECRETS_DIR=$PWD/deploy/.local/anj-cloud-dev/secrets \
ANJ_OPERATOR_DIR=$PWD/deploy/.local/anj-cloud-dev/operator \
ANJ_CONSOLE_DIR=$PWD/deploy/.local/anj-cloud-dev/console \
docker compose --env-file /dev/null --project-name anj-cloud-dev --file deploy/compose.json \
  up --detach --no-build --no-deps --wait access
python3 deploy/dev.py check
```

The previous gateway admits only each device's current leaf and refuses activation of leaves longer than seven days: after `reissue --active`, devices that have not picked up their reissued leaf lose access, and new approvals fail, until the change is redeployed.

After interrupted approval, run `deploy.access_operator reconcile`. It checks authoritative registry state, retains a known active device's exact token, and removes exact-name orphan tokens for unfinished/denied/expired provisioning before retry. Journals are private; do not copy them into diagnostics. A lost activation response never implies activation failed.

### Household accounts and directory sharing (spec #26)

The registry's accounts table is the household user list's only source (decision #78 N5). It holds id, display name, enabled and the admin role column of decision #87 (default false; the console work owns every admin API). `accounts` lists it; `account-set UID [--display-name NAME] [--enable|--disable]` registers an account or changes it (display names: 1-64 printable characters, no control or format characters). Disable is reversible (decision #79 (b)): the gateway first records where every recipient mounts the account's shares, from one read of the owner's own share list (Nextcloud reports each recipient's actual mount there, including collision suffixes and a recipient's renames, also while that recipient is disabled), then refuses every device of that account with 403 (no certificate revoked), and only then is the Nextcloud account disabled; `--enable` reverses the order. The CLI reads the owner's list with a temporary owner token (journaled, deleted afterwards), so an owner without a paired device can be disabled too, and a disabled recipient never blocks it. The result carries `mounts_recorded` (`true` after a disable, `null` otherwise). If the owner's list cannot be read (a backend error), the gateway refuses with "Could not read this account's shares to record where recipients mount them; the account was not disabled. Retry the disable.": the registry is unchanged, `occ user:disable` is never run and the CLI exits non-zero. Retry later. Without that record a recipient's client would read the hidden share as an unshare. The socket's `account-set` accepts the same optional `token`; without it the gateway uses one of the owner's active devices and refuses when there is none. `revoke` stays the separate, permanent action. Dev `up` registers the fixtures as "Alice" and "Bob".

Shares are directories only: never the root, `Shared` or anything beneath it, or a file. `share [DEVICE_ID] PATH RECIPIENT_UID [--rights read|write]` maps `write` (the default) to Nextcloud permissions 15, full access, the one sharing level (decision #155); `read` (View only) is refused for new shares and changes, and `share-update SHARE_ID --rights write` raises a share made earlier as View only. The share bit is never set, so recipients cannot reshare. `share-update [DEVICE_ID] SHARE_ID --rights …`, `unshare [DEVICE_ID] SHARE_ID` and `shares [DEVICE_ID]` act on the owner's own shares only. Name the owner by an active device, or by `--owner UID` for an owner with no paired device: the CLI then mints a short-lived, uniquely named per-owner token (journaled like inspection's, removed by `reconcile` if interrupted), passes it over the socket for that one call, deletes it and verifies it is gone (decision #80 (4)). Recipients must be enabled household accounts. Every create, change and removal, from a device route or the socket, runs through one sharing component under the gateway's single mutation lock and write fence.

A known failed share mutation fences only its own scope (`share:<id>`, or `path:<owner>:<path>` for a create; decision #80 (1)); `share-fences` lists them and `share-fence-clear SCOPE` clears one after the operator has checked the share with `inspect-shares`. Only an unknown outcome of an owner's `share`, `share-update` or `unshare` closes the household-wide write fence, resolved by the sharing reconciliation below; a recipient's `leave` or `share-rename` never does (see below). New incoming shares must land as a direct child of `anj-cloud/Shared`; a share of a folder inside the owner's `Documents`, `Music` or `Videos` is then moved by the gateway into the recipient's same folder, the only other allowed place (spec #34 P6, [access protocol](../services/access/README.md#directory-sharing)). Nextcloud resolves name collisions during the recipient's first mount, so the CLI reports share ID/incoming root rather than promising a provisional filename. Clients use the mTLS routes in the [access protocol](../services/access/README.md#directory-sharing). There is no general OCS or browser-login forwarding endpoint.

The local share path is a plain filename path, not an escaped URI: quote a value such as `'Documents/report #1?'` for the shell. Its JSON/query/form adapters preserve filename data without another URI decode. Public DAV requests encode those characters in their URI segments; MOVE destinations and response references use the same confined URI rules.

Run `deploy/.local/access-venv/bin/python -m deploy.filename_fixture` only with exclusive ownership of the synthetic stack. It fences gateway writes, uses supported own-stack quiescence/recovery around a nonce backend folder, then checks paired gateway round trips, distinct percent-like names, confined sharing and invalid URI refusal. It removes its folders/shares and revokes its two devices. `--backend-only` qualifies a pinned backend before changing gateway rules. Existing credentials, unrelated fixture data and project volumes are retained.

If an incoming share escapes its configured root, its exact ID is recorded for cleanup, always under the share's owner, also when the gateway found the escape while moving a recipient's mount (spec #34 P6): `share-cleanups` shows `uid:<owner>` or the owner's device, the `share:<id>` fence names the owner, and `repair-share OWNER_UID SHARE_ID` removes and resolves it in one step. `share-cleanups` reports unresolved entries. Confirmed cleanup failure is reported truthfully and can be retried with local `unshare`; an unknown cleanup result keeps writes fenced until scoped recovery. Never assume a failed cleanup removed the share.

### Client releases (spec #28 G1, spec #37)

The gateway serves every paired device the latest client package for its platform, over its own mTLS connection ([access protocol](../services/access/README.md#client-releases)). The operator publishes it; the gateway never signs:

```bash
deploy/.local/access-venv/bin/python -m deploy.access_operator release-publish android-arm64 app-release.apk --manifest app-release.json
deploy/.local/access-venv/bin/python -m deploy.access_operator releases
```

The manifest file is JSON `{"version": "1.2.0", "version_code": 12, "size": <bytes>, "sha256": "<64 hex>", "signer_sha256": "<64 hex>"}` (an optional `target` must match); the release build writes it, with `signer_sha256` from `apksigner verify --print-certs`. The CLI checks the package's size and SHA-256 against the manifest and the `version_code` against the served release before anything is sent, then streams the file (never read into memory) through `docker compose exec` into `access.release_publish`, which relays it to the private socket; the gateway checks it all again, stores it and swaps it in atomically. A refusal changes nothing. While a spec #22 backup or restore holds its marker (`state/run/backup-in-progress`, `restore-in-progress`) the CLI refuses with "A backup is running (deadline …); nothing was published. Retry after it finishes.": the backup reads the access volume live, and a snapshot taken mid-publish could hold a manifest without its package. The result names the release now served, the version code it replaced and the ones removed: the gateway keeps the current release and the previous one per target. If removing older ones fails the release is still published and served; the CLI prints a warning, sends a `release-prune-failed` alert (production; a spool record when the dispatcher is missing) and the next publish removes them.

Packages live in the access volume under `releases/<target>/` (in production the data disk, `/srv/anj-cloud/docker`). They are in the nightly backup with the rest of the access volume, so a restored server keeps serving its current update; an upload in progress (`releases/.incoming/`) is excluded. In production the release package and manifest are copied into the VM and published there as `anj`, like the other operator commands: `python3 -m deploy.access_operator --project anj-cloud-prod --state-root /srv/anj-cloud/state release-publish android-arm64 <apk> --manifest <json>`.

#### Desktop releases: signing and publishing (spec #37 U-core, U-publish)

Desktop clients (`linux-x86_64` now; `macos-arm64`, `windows-x64` with their updaters) trust one household Ed25519 **release key** (decision #159). Its private half exists only on the VM host, in `~/.local/share/anj-cloud/release-key/release-key.pem` (directory 0700, file 0600): never in the VM, a worktree, evidence or chat. Its public half lives in the deployment profile (`[release] public_key`, with its `key_id`); `apps/client/tool/apply_profile.py` writes it to the untracked `apps/client/assets/release/household-release-key.pub`, and every release build carries it; a build from a commit without a key in that file shows no updates. `deploy/release.py` (standard library plus `openssl` 3) does both steps on the VM host:

```bash
python3 deploy/release.py keygen          # once: the key, the public key file, key id and fingerprint
python3 apps/client/tool/package_linux.py /absolute/absent/output-dir     # from a clean checkout of a main commit
python3 deploy/release.py publish --target linux-x86_64 --artifact /absolute/absent/output-dir/anj-cloud-linux-x86_64-<commit12>.tar.gz [--dry-run]
```

`keygen` refuses if a key or a public key already exists, or if `--key-dir` is a symlink; rotation is a new key, a reviewed commit of the new public key and a manual reinstall on every device (spec #37 rule 2). `publish` refuses a shallow checkout and local changes to the signing code (`deploy/release.py`, `deploy/client_version.py`, `apps/client/release-version.json`, `services/access/release_manifest.py`, `apps/client/tool/linux_install.py`). It reads the archive's `bundle-receipt.json` and refuses unless: the source commit is in `origin/main` (fetched first); its `version_code` equals the number in that commit’s `apps/client/release-version.json`; the archive's built-in public key is the VM host key and a usable Ed25519 key (low-order keys are refused everywhere a key is read) (a release trusting another key could never update itself again); the `version_code` is above the one the target serves. It then signs `{version, version_code, size, sha256, key_id}` (signature over `release_manifest.signed_message`), checks the signature with `openssl` and publishes through the operator's `release-publish` in the VM: `ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod` (`--ssh-host`, `--ssh-config` to override), copying package and manifest into a private `mktemp -d /var/tmp/anj-release.*` that is removed afterwards. `--min-client-version-code N` adds the unsigned "Update required" floor. For a dev or review stack on the VM host, `--local-project anj-cloud-review-x --port N` runs the local operator instead, and only there may `--source-ref REF` replace `origin/main` (disposable test builds). The VM must already run a release that knows the desktop targets (this one or later).

**Version codes (all clients).** `apps/client/release-version.json` allocates the release number shared by Linux, macOS and Android; all packagers and the publisher read it from the exact source commit. Increment it before each new release, keeping it above every published/installed version and no higher than Android's 2100000000 limit. The first public-history release is 167, above the existing 166. Never derive versions from commit counts: exporting or squashing history changes those counts. The displayed version remains the commit's UTC date plus the release number (for example `2026.11.07.167`). Publishing refuses a number not above the destination's current release; changing source without increasing the number cannot replace that release.

### Household administration (spec #27)

Admins manage the household from the **Admin** section of the client app, over the same mTLS gateway as file sync (decision #87); the routes, confirmations, last-admin rule and audit are in the [access protocol](../services/access/README.md#household-administration). The admin role is on the account; any admin can make another user an admin, and the gateway always keeps at least one enabled admin.

Work needing the issuer key, `occ` or PM2 runs in the **console backend**, `deploy/vm/console_backend.py`, on a private Unix socket. In the VM it runs as `anj` as the PM2 app `console` (`deploy/vm/ops/console`, the live release's launcher), on `/run/anj-console/backend.sock` (directory 2750 `anj:anj-gw` from the bootstrap's tmpfiles entry, socket 0660), bind-mounted read-only into the access container; the gateway reaches it through its one supplementary group `anj-gw` (`ANJ_RUN_GROUPS=10002`), still with no capabilities. `anj-cloud-setup` (step 9: tmpfiles; step 10: the app and `/usr/local/bin/anj-cloud-admin`) installs all of it, so the Admin section works from the first install (decision #112 (1)); `--adopt-data` and `--restore-from` start it the same way, a restore drill (`start_stack = false`) does not. The backend refuses to start when its socket directory has another owner, group or mode. The watchdog supervises it like the other apps: online, and its socket answers (60 s start grace). It opens no network port and serves only the gateway's uid and its own account. On the VM host, a dev or review gateway reaches a backend run by the dev operator through `deploy/.local/<project>/console`, which `dev.py` mounts at `/run/anj-console`:

```bash
deploy/.local/access-venv/bin/python -m deploy.vm.console_backend --project anj-cloud-review-x --port 18834 \
  --socket deploy/.local/anj-cloud-review-x/console/backend.sock
```

Without the backend, approve, reissue, user add, enable or disable on the Nextcloud side, health facts and test alerts answer "The server's admin service is restarting; try again in a minute."; lists keep working. Revoked devices' app tokens are removed by the backend; if it is down, the gateway retries every 30 s until removal is confirmed. Role changes, disables, revokes, and invitations or approvals for another account send one ntfy message each through `admin-alert` ("anj-cloud admin: sam revoked a device of alex", `--key admin --every 0`), spooled to `state/run/alerts/` when the dispatcher is missing. An account with no paired device is disabled through `account-disable`, which mints and deletes a journaled temporary owner token like `access_operator account-set --disable`.

**First admin.** The bootstrap grants the role directly, or writes `state/accounts.json` (`{"admins": ["sam"]}`); the backend imports it once at start (missing account rows created, admin granted only when no enabled admin exists, never a demotion), audits `first-admin-import` and renames the file to `accounts.json.imported`. An unknown account is refused and alerted; the file stays.

### Recovery CLI (spec #27)

`anj-cloud-admin` is the text console for emergencies, including a lost last admin. It runs as `anj` inside the VM, reached by SSH from the VM host only (#89 (5)); from another machine, jump through the VM host over Tailscale SSH:

```bash
ssh -J halo anj@10.77.10.10 anj-cloud-admin admins   # halo: Tailscale SSH host; 10.77.10.10: the VM on the VM host (deploy/vm/paths.py)
```

Commands: `users`, `admins`, `user-add UID --name NAME`, `user-enable UID`, `user-disable UID`, `admin-grant UID`, `admin-remove UID`, `devices`, `invite --user UID [--grant read|write] [--label L]`, `pending`, `approve INVITATION_ID --fingerprint FP`, `deny INVITATION_ID`, `revoke DEVICE_ID`, `reissue DEVICE_ID`, `health`, `audit`. Every action goes through the gateway's operator socket, so the last-admin rule applies and the audit records actor `recovery-cli`. Destructive commands ask for the target typed back (`--yes` is for scripted tests only). `invite` prints its one-time code for the person at the terminal; never paste it into chat or logs. If the gateway is down, a mutating attempt is written to `state/operator/recovery-audit.jsonl` (0600) and imported into the audit when the backend next reaches the gateway: each entry once (by id); a line that is not a valid entry is set aside in `recovery-audit.jsonl.rejected` with one alert. On a dev or review stack add `--project anj-cloud-review-x --port N --backend-socket deploy/.local/anj-cloud-review-x/console/backend.sock`.

**Lost last admin.** Nobody can open Admin when the last admin's devices are gone. Pair a new device for that admin from the CLI:

```bash
anj-cloud-admin invite --user sam            # type the code on the new device; it pairs at once
```

The code carries the CA's pin and the gateway approves the device when it is redeemed (decision #151); the new device alerts once. Only if that approval cannot run (the `console` app is down) does `anj-cloud-admin pending` show it waiting, and `anj-cloud-admin approve INVITATION_ID --fingerprint FINGERPRINT_SHOWN_ON_THE_DEVICE` still approves it, as for codes issued before code-only pairing.

Or give the role to another enabled account with `anj-cloud-admin admin-grant alex`. Recovery of the VM account itself is host access: the operator's key-only SSH from the VM host (#89 (5)).

## File and mutation contract

The [access protocol](../services/access/README.md) defines exact enrollment fields and DAV semantics. Each certificate maps to one authoritative UID and read/write grant. Every request rechecks registry state and maps only to that UID's Nextcloud `anj-cloud/` folder, with `Music`, `Videos`, `Documents` and `Shared` beneath it. Public requests cannot select a backend account or URL. DAV hrefs/locations are validated and rewritten into the gateway namespace.

All normal content writers pass through one gateway worker and one global mutation lock, including share aliases and operator share changes. Existing PUT/DELETE/MOVE require a concrete `If-Match`; new PUT/MKCOL require `If-None-Match: *`; MOVE requires `Overwrite: F`. Missing baselines return 428 and stale versions 412. Folder comparison is performed against fresh metadata under the same lock held through backend completion, because Nextcloud rejects concrete collection `If-Match`. This does not protect against independent backend writers. Direct content maintenance must quiesce gateway writes.

Dev uploads require declared Content-Length and are bounded to 64 MiB per request, with a 128 MiB staging budget and a further 32 MiB disk floor. Staging occurs privately outside all watched roots. A full/error/revoked upload never deletes the source file on the client. Downloads may remain concurrent. This prototype is not a universal large-file claim; chunked uploads and larger budgets require later qualification.

Revocation denies new work and closes the client transport. Staging/queued work cannot acquire new authority. A backend commit already dispatched using accepted bytes may finish while retaining the mutation lock; no response is returned to the revoked client. Revocation does not undo a completed commit or erase downloaded copies.

## Recovery and cleanup

An unknown backend mutation result or service crash leaves a durable write fence. Do not bypass it or blindly replay a destructive operation. Reads remain available where possible. Supported scoped recovery is:

```bash
deploy/.local/access-venv/bin/python -m deploy.access_operator recover-writes
```

This marks maintenance, stops only this project's Nextcloud/cron/database so uncertain PHP/SQL work cannot outlive quiescence, restarts those same services with their volumes, then clears the fence after no gateway mutation remains. It never starts or stops another workload. Reconcile client versions after recovery instead of assuming whether the interrupted mutation committed.

### Sharing reconciliation

Generic recovery refuses an unresolved sharing outcome. Keep writes fenced and use the following bounded operator procedure; no SQLite edits are required:

```bash
deploy/.local/access-venv/bin/python -m deploy.access_operator fence
deploy/.local/access-venv/bin/python -m deploy.access_operator quiesce
deploy/.local/access-venv/bin/python -m deploy.access_operator share-cleanups
deploy/.local/access-venv/bin/python -m deploy.access_operator inspect-shares OWNER_UID
deploy/.local/access-venv/bin/python -m deploy.access_operator repair-share OWNER_UID EXACT_SHARE_ID
deploy/.local/access-venv/bin/python -m deploy.access_operator recover-writes --confirm-sharing-reconciled
```

`quiesce` cancels queued/staged mutations and stops/restarts only the owned backend/cron/database, retaining the fence. Inspect after quiescence so an earlier backend operation cannot appear later. The fence reports the authoritative owner and sharing intent, including source path, recipient, rights and share IDs that existed before dispatch. Inspection uses a short-lived, uniquely named per-owner Nextcloud credential, verifies its canonical UID, and lists only shares owned beneath `anj-cloud/`.

A recipient's leave or rename for everyone (decisions #155, #157) never keeps the household fence (decision #158): a failure or unknown outcome leaves a scoped `share:<id>` fence of kind `leave` or `share-rename` (`share-fences`); the journal entry named the share and its owner (`share_owner`, and for a rename the owner's `path` and `to`). For a leave, check the share with `inspect-shares OWNER`: absent means the recipient left. For a rename, check the owner's folder in Nextcloud: the new name present and the old absent means it was applied. Then `share-fence-clear share:<id>`; no `repair-share` is needed. 

Repair only an exact recorded cleanup ID or a new ID identified against the recorded prior IDs with matching owner/source/recipient. Do not guess when evidence is ambiguous. `repair-share` validates ownership/root, uses the supported OCS DELETE, verifies subsequent OCS404, marks the obligation resolved and removes its temporary credential. An already-absent exact ID is also verified before resolution. An intended confined share can be retained after inspection. The final confirmation flag is the trusted local operator's explicit reconciliation statement; it cannot bypass unresolved known cleanup rows. Recovery quiesces again before clearing the fence, then clients reconcile actual versions.

If a reconciliation command is interrupted, `reconcile` removes its exact journaled temporary credential. A failure to inspect or confirm absence leaves the obligation/fence unresolved. This is a private operator procedure, never a public administration endpoint or automatic deletion of ambiguous shares.

`stop` removes this project's containers/networks, retaining its four named volumes and all local credentials. Deliberately erase only this disposable project's durable data with:

```bash
python3 deploy/dev.py destroy --confirm-delete-project anj-cloud-dev
```

For another project supply its exact name with both flags. This deletes its files, registry, accounts/database and cache state. Once the volumes are gone, it also deletes that project's operator journals (`deploy/.local/<project>/operator/journals/` and `reconciliation-token.json`, under the operator lock), because they describe pairings and tokens that no longer exist. Left in place, they would make `reconcile` on the recreated stack fail with "Unknown pairing" (SC-055). The issuer, server certificate and other local credential files remain; retained credentials are not a backup. No broad Docker prune is needed.

## Production stack (spec #20 rev7: the anj-prod VM under PM2)

Production (`anj-cloud-prod`) runs inside a dedicated Debian 13 VM (`anj-prod`, decision #84), never on the dev stack. Rootful Docker Engine runs the containers; **PM2 is the only supervisor** (decision #85): every service has Docker restart policy `no`, and one PM2 app per service (`db`, `redis`, `nextcloud`, `cron`, `gateway`, `haproxy`) runs `deploy/vm/run-service <app>`, which waits for its dependencies to be healthy and runs the container attached. A container exit is a PM2 restart with exponential backoff; `pm2 startup systemd -u anj` and `pm2 save` (spec #21's bootstrap) bring the stack back on every boot. Installing Docker, PM2, the tmpfiles for `/run/anj-cloud-gw`, `/run/anj-haproxy` and `/run/anj-console` (spec #27's console backend), the firewall and the watchdog is spec #21's job.

The shared paths, socket names, markers, PM2 app names and `prod.py` subcommands are in `deploy/vm/paths.py` (`python3 -I deploy/vm/paths.py --json`). State lives on the data disk (`/srv/anj-cloud`, label `ANJ_DATA`) in `/srv/anj-cloud/state/` (0700, owner `anj`): `operator/`, `secrets/`, `release/<commit12>/` (`source.tar`, `compose.json`, rendered `haproxy.cfg`, `ecosystem.config.js`, `release.json`), `bin/` (the release's `run-service`), `run/` (markers, alert spool), `haproxy/` (0755: `household.acl`, 0644, written by spec #23's DDNS app). Only the exact paths in `paths.PUBLIC_STATE_PATHS` (`haproxy/`, `haproxy/household.acl`, `haproxy/haproxy.cfg`, `release/<commit12>/haproxy.cfg`) may be world-readable; everything else stays 0700/0600. The release source is also extracted to `/srv/anj-cloud/release/<commit12>/`, and `/srv/anj-cloud/release/current` points at the live one. `prod.py` runs as `anj` and refuses root.

```bash
cd /srv/anj-cloud/release/current
python3 deploy/prod.py setup --host gateway.example.com [--bind-address 10.77.10.10] [--household-lan 192.168.0.0/24]
python3 deploy/prod.py up            # build if needed, start the PM2 apps, wait for health, pm2 save
python3 deploy/prod.py status        # JSON: PM2 state, container health, healthcheck per app
python3 deploy/prod.py check         # read-only: PM2 online, restart policy no, limits, no ports, non-root, health, TLS
python3 deploy/prod.py redeploy <commit12>   # merged commit; verify, restart in order, switch only when healthy
python3 deploy/prod.py redeploy [<commit>] --source <tar>   # the same from a `git archive` tar: no git needed (#122)
python3 deploy/prod.py stop          # pm2 stop every stack app (a reboot resurrects them)
python3 deploy/prod.py emergency-stop --reason "<what was seen>"
python3 deploy/prod.py resume        # only on the operator's instruction
python3 -m deploy.access_operator --project anj-cloud-prod --state-root /srv/anj-cloud/state user-add sam --display-name Sam
```

**Emergency stop.** `emergency-stop` writes `state/run/emergency-stop` and alerts at once: one `emergency-stop` message with the reason goes through `state/bin/anj-alert`, or into `state/run/alerts/` when the dispatcher is missing. It then stops the `haproxy` and `gateway` apps and saves the PM2 list. `resume` sends one "re-enabled" message. While the flag exists, `run-service` refuses those two apps with exit code 78, which is in PM2's `stop_exit_codes`, so the stop survives PM2 restarts and VM reboots. Only `resume` clears it (decision #68 (9)).

**`status` JSON.** `{"project", "host", "release", "emergency_stop", "apps": {<app>: {"status", "restarts", "pid", "service": {"status", "health"}|null}}, "healthcheck"}`. `apps` always lists all six apps. Each status is one of `online`, `stopped`, `stopping`, `launching`, `errored` or `missing`:
- PM2's `waiting restart` (a crashed app held for its backoff restart) reports `launching`.
- `one-launch-status` reports `stopped`.
- An unknown PM2 state reports `errored`.
- `haproxy` or `gateway` held down by the emergency flag reports `stopped`, whatever PM2 shows (PM2 leaves an app that exited 78 in `waiting restart`).

**Redeploy.** `redeploy` runs under the operations lock (`state/run/backup.lock`, the lock spec #22's backup holds). It refuses while a backup or another redeploy holds that lock, or while a restore holds `restore.lock`. Nothing waits for it: while it holds the lock it writes `state/run/release-switch` (its pid), and a backup timer run that finds the lock held for a switch is skipped quietly (a log line, no `backup-failed` alert); the next night's run backs up. A second redeploy, an upgrade or a setup re-run is refused.

1. It builds, exports and verifies the new release before anything restarts: release files, source digest, rendered config, built image and `docker compose config`.
2. It installs the new release's `state/bin` files (`run-service`, `paths.py`, `stackenv.py`), sets `stack.json` to the new release, restarts the apps in dependency order with health waits and runs `check`. The health check therefore covers the wrapper that keeps running.
3. Only after a healthy check does it switch `release/current` and record `previous_release`.
4. It then runs `pm2 restart` for `console`, `watchdog` and `watchers`, the operations apps that run `release/current`'s code, so none keeps the old release (decision #114; `watchers` added with #122). This is still inside the redeploy run, which the watchdog treats as maintenance. An app PM2 does not run is left alone. A failed restart there is reported in the result and alerted, never rolled back.

`ddns` is not restarted: it is a `cron_restart` app with autorestart off whose script is `release/current/deploy/ddns.py`, so its next 5-minute run starts the new release. `alerts` runs `state/bin/anj-alert`, which `anj-cloud-setup upgrade` refreshes.

On any failure before the switch completes, it falls back. That includes the build, verification, the health check, the switch itself, Ctrl-C (SIGINT), SIGTERM and SIGHUP:

- it restores the previous `state/bin` files and `stack.json`;
- it leaves `release/current` on the previous release (or puts it back there);
- it restarts the previous release;
- it sends one `redeploy-failed` alert naming the release that stays live.

The fallback ignores further SIGINT, SIGTERM and SIGHUP. prod.py prints `ALERT: redeploy-failed <dispatcher|spool|none>` on stderr. The release it falls back to is the one `release/current` names; after an interrupted run, `stack.json` may name another.

**Redeploy from a tar (decision #122).** The VM has no git: its releases are unpacked trees. `redeploy --source <tar>` takes the release from a `git archive` tar instead of a commit lookup. The tar names its own commit (its pax header); a commit given as well must be that one. The tar becomes `state/release/<commit12>/source.tar` (0600) unless one for that commit is already there, which must then be the same release. Whether the commit is merged and carries the required fixes cannot be checked without git, so `stage.py --upgrade` checks both on the VM host before it stages. Production is updated through `stage.py … --upgrade` (Updating production, below), never by hand.

**Ingress.** The `haproxy` container uses the VM's host network and binds only the VM address on 443 (`10.77.10.10` on the VM host). It relays TLS untouched with PROXY v2 to `/run/anj-cloud-gw/gateway.sock` (owner uid 10001, group `anj-gw` 10002, mode 2750). HAProxy runs as a single process and is PID 1: the compose file sets `entrypoint: ["haproxy"]`, because the image's entrypoint script would start master-worker mode, whose master keeps uid 0. It starts as container root holding only `NET_BIND_SERVICE`, `CHOWN`, `SETUID` and `SETGID`: it binds 443 and creates the admin socket `/run/anj-haproxy/admin.sock` (0660, group `anj`), then runs as the image user (uid 99) with gid 10002 and no capabilities. `deploy/prod/haproxy.cfg.tmpl` is rendered by `deploy/vm/render.py`. Limits are per source 20 concurrent and 60 new connections per minute; the household (LAN range plus the file-backed published address) gets 64 concurrent and no rate limit.

**Gateway.** Non-root uid 10001, `ANJ_LISTENER=proxy-unix`, internal `proxy` network only, no published port, journald logging. Its start step (container root with only `CHOWN`, `DAC_READ_SEARCH`, `SETUID` and `SETGID`: under rootful Docker it is not the owner of the 0600 secrets, so it reads them with `DAC_READ_SEARCH`, then drops to uid 10001 with no capabilities) copies the TLS files from the secrets into a tmpfs on every container start (decision #81), so every PM2 restart loads a renewed certificate; `up` and `redeploy` restart the gateway when its copies are stale. Health: `docker compose -p anj-cloud-prod exec -T access python -m access.health`.

**Limits.** Every container has `mem_limit` and `pids_limit`: db 512m/128, redis 256m/64, nextcloud 1536m/256, cron 384m/64, access 256m/64, haproxy 128m/64. That is 3 GiB in total, leaving 1 GiB of the 4 GiB VM for the OS, PM2 and Docker. PM2 output for `nextcloud`, `cron`, `db` and `redis` goes to `/dev/null`, so no Nextcloud access line (file paths) lands in PM2 logs.

Releases must be merged into `origin/main` and contain 4c3bb82 (spec #19) and f554e13 (SC-028, `/v1/files/added`). The production issuer is "anj-cloud Household issuer" (P-256, `CA:TRUE, pathlen:0`, ten years). The server certificate's SAN is `DNS:<host>` only, valid one year. Operator commands take `--project anj-cloud-prod --state-root /srv/anj-cloud/state`; `--state-root` refuses a git worktree path, a symlink or loose modes.

Qualification moves to the `anj-qual` VM (spec #21, B2); the VM host-hosted `prod_qualify.py` is retired.

## Evidence and pins

Offline protocol/registry tests supplement the real TLS fixture; configuration parsing alone does not qualify pairing, sharing, cancellation or recovery. The fixture uses synthetic accounts/devices and unique folders, verifies real certificates and file operations, and revokes its devices afterward. Private client fixture keys remain in ignored operator paths. Integration qualification is still in progress while PR #2 is draft.

Nextcloud `33.0.10-apache`, PostgreSQL `17.11-bookworm` and Redis `7.4.12-bookworm` use exact multi-platform manifest digests in Compose. The Python base `3.14.10-slim-bookworm` is pinned similarly in the access Dockerfile. Official sources were checked on 1 November 2026: [Nextcloud maintenance](https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule), [Nextcloud33 requirements](https://docs.nextcloud.com/server/33/admin_manual/installation/system_requirements.html), [official image catalogues](https://github.com/docker-library/official-images/tree/master/library), [PostgreSQL support](https://www.postgresql.org/support/versioning/), [Nextcloud Docker configuration](https://github.com/nextcloud/docker). Nextcloud33 support ends February 2027; reassess before that date.

The earlier token prerequisite remains `python -m deploy.token_spike` using the local privileged fixture helper, not a published bypass. It is direct maintenance: run `quiesce` first, the prerequisite proof second, then `recover-writes`. It proves local-account DAV/sharing capability only. Exact backend token deletion took about 9 seconds to affect new authentication because of Nextcloud's local cache; active gateway revocation uses registry state independently.

## Encrypted onsite backup and restore (spec #22 rev7, anj-prod VM)

Backups run inside the `anj-prod` VM (decision #84). The VM sees the Data Traveler only through the virtiofs share of `DOS_BACKUP/anj-cloud-prod/`, tag `anj-backup`, mounted at `/mnt/anj-backup` (spec #21 step 4). The repository is `/mnt/anj-backup/restic`, so nothing else on the drive is visible to or written by the VM, and the drive is never formatted. Paths, markers and names come from spec #20's `deploy/vm/paths.py` and are not redefined here.

On the VM host the share is owned by the system account `anj-cloud-backup` (no login, never uid 1000), mode 0700, so the operator's user and the VM host's agents can neither read nor write the backups (decision #115). In the VM every file on the share appears as `anj`: the VM host's virtiofsd wrapper maps the guest's `anj` (1000:1000) to the account, squashes guest root (restic's container) to it too, and refuses creates and chowns by any other guest uid (see [the VM host](#halo-vm-host-spec-21)).

`deploy/backup.py` runs restic as a one-off container pinned by digest (`restic/restic:0.18.1@sha256:39d9…797e76`). Each container is `--rm`, `--network none`, has every source read-only, `--cap-drop ALL` plus `DAC_READ_SEARCH`, `DAC_OVERRIDE` and `FOWNER`, `no-new-privileges`, and `--memory 2g --pids-limit 256`. restic runs as the container's root, which under the VM's rootful Docker is guest root, while the cache and the repository belong to `anj`: without `DAC_OVERRIDE` and `FOWNER` it could read but not write them. Its only writable mounts are `/repo` and `/cache`. Output is JSON without file paths, file names or secrets.

A snapshot holds:
- the state root (`/srv/anj-cloud/state`: operator issuer and server keys, `secrets/` except the restic password, `release/<commit12>/` with `source.tar`, `stack.json`);
- the Nextcloud and access volumes, with a consistent registry copy;
- a `pg_dump` plus `pg_dumpall --roles-only`;
- a manifest with counts and sentinel checksums.

Redis is not backed up.

### Set up (inside the VM, user `anj`)

```bash
python3 deploy/backup.py init --show-escrow     # creates restic/ in the share, records the repository ID
python3 deploy/backup.py seed --cap <minutes>   # first full backup at the time the operator schedules
```

The password goes to `secrets/restic-password` (0600). `--show-escrow` writes it to the terminal device only. Keep a copy off the VM host; it is the only secret a full recovery needs besides the drive. Agents never read, copy or print it.

### Units (installed by spec #21's bootstrap)

`python3 deploy/backup.py units --out <dir>` (source default `/srv/anj-cloud/release/current`, `paths.RELEASE_CURRENT`) renders `deploy/vm/systemd/` for the bootstrap. The units are system units in the VM running as `anj`, not PM2 apps, so a PM2 restart never starts a backup (#89 (4)):

- `anj-cloud-backup.timer`: `OnCalendar=*-*-* 03:30:00`, `Persistent=false`. A night missed while the VM was off is not caught up at boot; it runs the next night (#69 (d)).
- `anj-cloud-backup-stale.timer`: hourly `status --alert-stale`. It sends one alert after 36 h without success, and one for a marker past its deadline. When no run holds the lock it clears maintenance after a crash.

### Nightly run

Preflight runs before any maintenance, and any failure means no maintenance and one alert:
- `/mnt/anj-backup` is a `virtiofs` mount with tag `anj-backup`, writable, and not on the VM's own disk (`share-absent`, `not-virtiofs`, `wrong-tag`, `share-read-only`);
- the repository opens with the recorded password and has the recorded ID (`wrong-repository`);
- free space is at least today's measured growth (or twice the last upload) plus 10 GB, plus prune headroom (`low-space`);
- the stack is healthy.

The drive's UUID is the VM host's host check (spec #21); the VM cannot see the block device.

**Share absent (#89 (2)).** Production starts and keeps serving without the drive. Only the backup refuses, with one `backup-preflight` alert.

The window follows the rev6 sequence: marker on, maintenance on, dump and snapshots, restic. Maintenance is cleared and the marker removed in a `finally`. The hard cap is 30 minutes from the start; at the cap restic is stopped (and killed if it hangs), maintenance goes off, one `backup-cap` alert is sent, and the next run adopts the uploaded packs.

Retention (7 daily, 4 weekly, 6 monthly), the weekly prune and the weekly or monthly `restic check` need no maintenance. They run **after maintenance is cleared**, so the stack is serving, under the backup lock (so `window --check` stays busy and the reboot guard waits), with their own deadline at **04:10 local**, before the 04:15 reboot target. A run at another hour (seed, manual) bounds them to 6 hours. Work still running at 04:10 is stopped and deferred. Because the lock is held until 04:10 at the latest, spec #21's update run (`apt-daily-upgrade`) should fire after 04:10; at 04:00 its `ExecCondition` would see the window busy and skip that night.

The last success of forget, prune, check and the read check is recorded (`status` shows it under `housekeeping`). When any of them is more than 8 days past its period (1, 7, 7 and 30 days), one `backup-housekeeping-overdue` alert is sent; the episode closes when they are back on time.

### Window coordination (decision #86)

Markers live in `/srv/anj-cloud/state/run/`, as named in `paths.py`:
- `backup-in-progress` is held by a run;
- `restore-in-progress` is held by `restore` and `drill-checks` for their whole run.

Both are JSON with `deadline_epoch`. Spec #21's watchdog, the `apt-daily-upgrade` `ExecCondition` and the reboot guard use one command, which works as root:

```bash
python3 -I /srv/anj-cloud/release/current/deploy/backup.py window --check    # 0 clear, 1 busy, 2 error
```

It only reads: no ownership or euid refusal, no writes to the state root (locks are probed with a shared non-blocking `flock`). It reports busy (exit 1) while a marker is before its deadline (an unreadable marker counts as busy), or while a backup or restore process holds its lock; that includes forget, prune and check after the window.

Any error (missing state root, unreadable run directory) exits 2. That fails closed: the update run and the reboot guard treat it as busy, and systemd's `ExecCondition` skips on 1–254. So that a broken check cannot block updates silently, an error also sends one "update window check failing" alert per day; the daily stamp lives in `/run` as root, never in the state root.

### Restore

```bash
python3 deploy/backup.py restore --snapshot latest --target <empty dir> --project anj-cloud-prod \
    --state-root /srv/anj-cloud/state [--password-file <escrow>] [--replace-production --confirm anj-cloud-prod]
```

Behaviour from 43f97f7 is kept:
- non-destructive steps first;
- production volumes are removed only with the flag (stop production through PM2 first, `prod.py stop`);
- the state root is placed last, with `secrets/` merged per file so `restic-password` and `backup.json` stay;
- dump, roles and the password copy are deleted in every outcome.

A share that cannot be written is read with restic `--no-lock` and mounted `:ro` into restic: one mounted `ro`, or one that refuses an actual write probe (a uniquely named empty file in the repository directory, created and removed at once). Mount options alone are not enough: the VM host's `--share-readonly` export (libvirt `<readonly/>`) can be mounted `rw` in the guest, and restic would then retry its lock on `EROFS` until it timed out (SC-067). Only the restore probes: `init --adopt` writes nothing to the share, not even a probe, and backups never probe: they keep the lock and refuse a share mounted `ro`. A probe file is removed whatever happens once it exists; a removal that fails is reported on stderr (`write-probe-left`; restic ignores the file) and counts as not writable. The result, without secrets, goes to `run/last-restore.json`.

### Restore drill: rebuild and restore (on the VM host, unattended)

```bash
python3 deploy/backup.py drill
```

It refuses between 03:20 and 05:00. If any `anj-qual` object exists (another run holds it) it refuses with reason `qual-busy` and touches nothing. Ownership is spec #21's run id (`halo-vm.sh`, PR #40); nothing here retitles or retags a VM. Then:

1. Runs `deploy/host/halo-vm.sh --qual --run-id <run id> --share-readonly`. It writes the run id to its tag file and the domain description before defining anything, then creates `anj-qual` (4 GiB, the same pinned threads, `10.77.11.0/24`, no forward) with the backup share read-only. Exit 3 (`qual-busy`) means another run got there first: that VM is not ours. ssh uses `halo-vm.sh`'s aliases (`ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod|anj-qual`).
2. Waits for the fresh VM's clock (`timedatectl show -p NTPSynchronized --value` every 5 s, at most 300 s); the bootstrap's preflight refuses an unsynchronized clock, so a timeout fails the drill with reason `clock-unsynced` before the password moves. Then mounts the backup share read-only itself (`mount -t virtiofs -o ro,…`, creating the mount point only when nothing is mounted there and it is missing, or `remount,ro` if already mounted, never touching the share's root) and confirms `ro` is in effect (reason `share-mount-failed` otherwise); the bootstrap leaves an existing mount alone, so the restore reads the share without a lock.
3. Writes an answers file: `ddns = "off"`, alerts tagged drill, `restic_password_file`, `start_stack = false`, `data_disk_init = true` (the drill VM's blank data disk; spec #21 never formats a disk without that answer).
4. Moves the password by decision #95: `ssh -F $CFG anj-prod 'sudo cat /srv/anj-cloud/state/secrets/restic-password' | ssh -F $CFG anj-qual 'sudo install -m 600 -o anj -g anj /dev/stdin /run/anj-drill/restic-password'`, where `$CFG` is `halo-vm.sh`'s ssh_config. The two processes are piped directly, so the password is never in the drill's process, an argument, a log or the receipt. The copy is on tmpfs and goes with `anj-qual`. There is no prompt.
5. Stages the bootstrap into the fresh VM (spec #21's `deploy/vm/stage.py`: `git archive HEAD` of this checkout to `/var/lib/anj-cloud-setup/`, because `release/current` exists only after the bootstrap) and runs its restore mode, `sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --restore-from /mnt/anj-backup --answers …`. It installs the release recorded in the restored `stack.json`.
6. Runs `backup.py drill-checks` inside `anj-qual`, holding `restore-in-progress`:
   - it starts only `db`, `redis`, `nextcloud`, `cron` and `gateway` through spec #20's PM2 ecosystem (`pm2 start …/ecosystem.config.js --only <app>`), never `haproxy`, and verifies `haproxy` is absent;
   - the restore's manifest checks (config and user-file sentinels, file-cache count, registry digest);
   - issuer certificate against its key;
   - the production healthcheck;
   - Nextcloud `pgsql` and Redis locking;
   - no `ddns` app;
   - a drill-only account and device with a 1-day leaf, enrolled and doing an mTLS DAV write and read **over the gateway socket with a PROXY v2 `LOCAL` header** (a one-off client container, `--network none`, uid 10001 and group 10002).
7. Runs `halo-vm.sh --qual-destroy --run-id <run id>` (never `--force`) only after reading this run's id from the record of ownership. While a domain named `anj-qual` is defined, only its description counts. The tag file counts only when no domain is defined (a partial create that left only the network or pool). The create runs inside the cleanup's scope, so a `--qual` that wrote our id and then failed partway is destroyed too, and the receipt is still written. A VM with another run's id, or none, is left in place and the receipt names its owner. The drill confirms with `virsh` that nothing of `anj-qual` remains and that `anj-prod` is untouched. A destroy that fails, is refused or times out is recorded, not raised.

The receipt goes to `~/.local/share/anj-cloud/qualification/f15-restore-drill-<UTC>/receipt.json`.

### Full recovery runbook (new OS and data disks)

1. On the VM host (operator, sudo): `halo-vm.sh --recreate-os` plus a new data disk for `anj-prod`. The VM address stays the same, so the forward needs no change. The share is spec #21 step 4.
2. In the new VM: `sudo deploy/vm/anj-cloud-setup --restore-from /mnt/anj-backup`. It prompts for the escrowed password, runs `backup.py init --adopt` (repository ID read from the share; nothing written) and `backup.py restore`, then continues as an adopted install: no new CA, secrets or accounts.
3. `prod.py check`. Devices keep working without re-pairing, because the issuer and server certificate are the same.
4. After the first nightly run: `backup.py drill` from the VM host.

The drill exercises every step except the final production cut-over.

### Qualification

- **Merge (The VM host, no VM):**
  - `tests/test_backup.py`: refusals, window, cap, markers, units, the stub guard and update run, in-place restore, drill orchestration.
  - `ANJ_DOCKER_TESTS=1 python -m unittest tests.test_backup_restic`: real `findmnt` and restic in bounded `--rm` containers.
  - `apps/client/test/maintenance_window_test.dart`.
- **VM rows on `anj-qual`:** `python3 deploy/backup_qualify.py halo --scratch-share <scratch dir> --evidence …` covers hard cap, encryption at rest and the drill. `<scratch dir>` uses the production ownership model (decision #115): create it with `python3 -I deploy/host/anjvm.py scratch-share create ~/.local/share/anj-cloud/qualification/backup-scratch`, which makes it owned by one of your subordinate uids (from `/etc/subuid`), mode 0700, so you cannot enter it on the VM host and the VM's `anj` reaches it only through the wrapper's mapping. Give it as an absolute path without symlinks; `halo-vm.sh --qual --scratch-share` refuses any other (one owned by you, root or uid 1000, or not 0700), and refuses every share until the operator's `--apply` has installed the wrapper. The VM host-side encryption-at-rest search enters it through `anjvm.py share-exec` (an unprivileged user namespace); `anjvm.py scratch-share remove <dir>` deletes it. Each phase creates its own `anj-qual` under its own run id (or refuses with `qual-busy`), destroys only that one, and pipes anj-prod's password into it as above. It needs B1's `--qual` and B2's bootstrap.

## Production DNS, DDNS and go-live (spec #23)

DDNS runs inside the `anj-prod` VM as PM2 app `ddns` (decisions #84, #85). Go-live checks run on the VM host or a second computer. Standard library only; never as root. The DNS token lives only in the VM at `/srv/anj-cloud/state/secrets/cloudflare-dns-token` (0600, owner `anj`; written by the bootstrap's hidden prompt). Agents never read, copy or print it.

In the VM (as `anj`, from the release source):

```bash
python3 -I deploy/ddns.py check                 # one read-only GET of the record: type, proxied, TTL
python3 -I deploy/ddns.py run                   # one cycle (PM2's command)
python3 -I deploy/ddns.py pm2-app --answers <answers.toml>   # PM2 entry for the bootstrap (script under release/current); [] unless ddns = "on"
```

The PM2 entry has `autorestart: false` and `cron_restart: "*/5 * * * *"`, so PM2 runs it when it resurrects the stack after boot and every 5 minutes. DDNS is opt-in. Only an explicit `ddns = "on"` in the answers file installs the app, and the production bootstrap writes that key. A missing key or `ddns = "off"` (qualification and drill VMs) installs nothing.

Each cycle reads the public IPv4 from two independent endpoints and acts only when they agree on a public address. It reads the A record by exact name, patches only `content` with `proxied=false`, and never creates or deletes a record. It then writes the address to `state/haproxy/household.acl` (0644, by atomic rename inside `state/haproxy/`, which HAProxy mounts read-only as a directory; only when changed or missing) and replaces the file-backed ACL's runtime entry over `/run/anj-haproxy/admin.sock` (prepare/add/commit, or clear + add), with no reload. While the emergency-stop flag exists, only the file is written.

Every failure is counted. The 3rd consecutive one calls spec #21's dispatcher once as `state/bin/anj-alert --key ddns --every 0 --title "anj-cloud DDNS" -- MESSAGE` (`--every 0` because D throttles itself) (`paths.ALERT_COMMAND`; category only), and a `ddns-alert` line is always logged; spec #21's DDNS watcher must not alert again for it. An address that is not one public IPv4 never reaches the ACL and alerts at once. The state file `state/run/ddns-state.json` (`paths.DDNS_STATE`) records `last_success` for the watchdog.

From the VM host or a second computer:

```bash
python3 deploy/golive.py line-check --router-wan <WAN IPv4>
python3 deploy/golive.py fingerprint <issuer.crt copied from the VM>
python3 deploy/golive.py health --host gateway.example.com --cacert <issuer.crt> --expect-ip <home IPv4> --no-hosts-entry --concurrent 25   # second computer hairpin
python3 deploy/golive.py source-check --source <source HAProxy logged in the VM> --published <home IPv4>                                   # hairpin source
python3 deploy/golive.py health --host gateway.example.com --cacert <issuer.crt> --resolver system --expect-ip 192.168.0.10              # The VM host path (output DNAT)
python3 deploy/golive.py scan <home IPv4> --host gateway.example.com --evidence-dir <dir>                                                # tethered second computer
python3 deploy/golive.py stop --reason "<what was seen>" [--ssh-config <file>]                                                                # emergency stop (The VM host)
```

`source-check` passes for the household LAN or the published IPv4. It fails on an address in the VM network: `10.77.10.1` means the VM host applied source NAT, so return to the planner.

`golive.py stop` runs `ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config -o BatchMode=yes -o ConnectTimeout=15 anj-prod python3 -I /srv/anj-cloud/release/current/deploy/prod.py emergency-stop --reason …` (the release's `prod.py` is not executable, so it always runs through the interpreter). `anj-prod` resolves on the VM host only through `halo-vm.sh`'s ssh_config, so every golive ssh call uses that file (resolved from the invoking user's home) when it exists; `--ssh-config <file>` overrides it (a missing override is refused before any ssh) and `--ssh-host` names another alias. If the default file is missing it falls back to plain `ssh` and says so in the JSON (`ssh_config: null`, `ssh_config_source`). That writes the flag, stops PM2 apps `haproxy` and `gateway`, runs `pm2 save` and sends one ntfy message from the VM, which the VM host cannot observe. The command then verifies through `prod.py status` (exactly A's published JSON shape) that `apps.gateway.status` and `apps.haproxy.status` are `stopped` and `emergency_stop` is true. If the stop cannot be confirmed, it alerts from the VM host through the VM host's dispatcher given as `--alert-command <absolute path>` (same `anj-alert` contract: `--key emergency-stop --every 0 --title … --priority urgent -- MESSAGE`). B1's root-only dispatcher `/usr/local/lib/anj-cloud-host/anj-alert` runs as `sudo -n <path> …` under a narrow sudoers rule; it never prompts, and a refused sudo is reported as "fallback not delivered". There is no resume command here: only the operator re-enables, with `prod.py resume` in the VM. The operator's root stop is `sudo deploy/host/halo-vm.sh --forward off` (and `--forward on` to restore).

## The VM host (spec #21)

Production runs in the `anj-prod` VM on the VM host (decision #84). `deploy/host/halo-vm.sh` creates or
adopts it and owns the VM host side; every the VM host-changing mode is operator-run with sudo (#49), and the
agent-runnable modes use only the VM host user's libvirt access.

| Command | Who | What |
|---|---|---|
| `sudo deploy/host/halo-vm.sh` | operator | Dry run (default): reads, others-untouched snapshot, plan. Without sudo: agent subset |
| `sudo … --apply [--only <step>]` | operator | 1 preflight, 2 network, 3 domain, 4 backup share, 5 forward, 6 start/stop, 7 hosts, 8 host checks; `--only qual-firewall` adds the anj-qual bridge rules |
| `sudo … --verify` / `--rollback <step>` | operator | Read-only check with the others-untouched comparison / undo one step |
| `sudo … --recreate --confirm anj-prod` | operator | Replace the domain and both disks from the templates (once, before go-live, #89 (7)) |
| `sudo … --recreate-os` | operator | Rebuild `vda` from the verified image; the data disk is kept |
| `sudo … --forward off\|on` | operator | Emergency stop of the 443 forward; only the operator turns it back on |
| `… --qual [--run-id ID] [--share-readonly \| --scratch-share DIR]` | agent | Throwaway `anj-qual` (4 GiB, threads 14,30,15,31, `10.77.11.0/24`); refused below 5 GiB `machine.slice` headroom; exit 3 `qual-busy` if one exists. A share needs the installed wrapper; `DIR` comes from `anjvm.py scratch-share create` |
| `… --qual-destroy [--run-id ID \| --force]` | agent | Remove `anj-qual` (domain, disks, pool, network) when its run id matches |

### Backup share ownership (decision #115)

Step 4 owns the backup share:

- `/etc/sysusers.d/anj-cloud-backup.conf` and `systemd-sysusers` create the system account
  `anj-cloud-backup` (system uid/gid, no login shell, no password, never 1000);
- `DOS_BACKUP/anj-cloud-prod` is created, or (only while it is empty) re-owned, as
  `anj-cloud-backup:anj-cloud-backup 0700`. A share holding data owned by anyone else is never
  re-owned: the step fails and names the owner. The drive is never formatted.

The share is served by `/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud` (installed by step 6
with `anjvm.py`), the domain's `<binary path>`. It runs `/usr/lib/virtiofsd` with libvirt's
arguments plus `--translate-uid`/`--translate-gid`: `map:1000:<owner>:1` (guest `anj` is the
share's owner), `squash-guest:0:<owner>:1` (guest root, restic's container, writes as the owner
too) and `forbid-guest` for every other guest id. It refuses to serve (exit 1) a directory other
than the production share or `~/.local/share/anj-cloud/qualification/<name>`, a path with a
symlink, a share owned by root or 1000 or not 0700, and any argument outside libvirt's
`--fd=N --shared-dir PATH [--readonly]` (so no `-o`, `--sandbox`, `--seccomp`, `--modcaps`); it
checks the directory through one `O_NOFOLLOW` descriptor. A share is therefore never served
unmapped. libvirt's `<idmap>` is not used: it becomes virtiofsd `--uid-map`, which virtiofsd
refuses when libvirt (`qemu:///system`) runs it as root.

`vm-start` attaches the share only when it is owned by the account with mode 0700, otherwise it
starts the VM without it and alerts. If the domain fails to start with the share (the wrapper or
virtiofsd failed), it redefines and starts anj-prod without the share and alerts "running without
backups" (its JSON record names `/var/log/libvirt/qemu/anj-prod-fs0-virtiofsd.log`): production never stays down
for the share (#89 (2)). `vm-start --stop` is done only at `shut off` (`in shutdown` is not) and
exits 1 at its 120 s timeout; a start waits for `shut off` before it switches the definition.

`--verify` (step 4) checks the account, the share's owner and mode, that the installed wrapper equals
the checkout, that the persistent and the running definitions use it, that the running virtiofsd
carries the mapping (from its own arguments), and, by a real attempt, that uid 1000 (and the invoking
user) can neither list nor create anything in the share.

Migration of a running `anj-prod` whose share is still `root:root 0750`: the operator runs the `sudo`
lines on the VM host, from one clean checkout of the merge commit (`wrapper_current` compares that checkout
with the installed files); the planner runs the anj-qual proof and the release upgrade. The exact
sequence, with the rollback, is in PR #49's description:

1. `--dry-run --only backup-share`, then `--apply` (account, share re-owned 0700, wrapper; the VM keeps running);
2. agent: the libvirt-managed proof on anj-qual, before production is touched, no bootstrap, about 20
   minutes (`anjvm.py scratch-share create`, `--qual --run-id share-3 --scratch-share …`): the running
   virtiofsd in `/proc` is the installed wrapper's (carries the mapping); in the guest the share is
   `anj:anj 0700`, `anj` creates and reads a file, other uids are refused; on the VM host that file belongs to
   the scratch owner (through `share-exec`) and the user is denied; `--qual-destroy`;
3. `systemctl stop anj-cloud-vm-stop.service`, then wait (at most about 150 s) until `virsh domstate anj-prod`
   prints `shut off`; if it does not, do not restart: run the rollback, or `sudo virsh destroy anj-prod`;
4. `systemctl restart anj-cloud-vm.service` (vm-start switches the definition to the wrapper), then
   `systemctl start anj-cloud-vm-stop.service`;
5. `--verify` (step 4 must pass); then the merge commit's release goes live in the VM; then
   `sudo anj-cloud-setup backup`. The in-VM `prod.py redeploy <commit12>` cannot do that (the VM has no
   git and its releases are unpacked trees); it is replaced by decision #122's upgrade path, an agent
   step from the VM host: `python3 deploy/vm/stage.py anj-prod --commit <merge sha> --upgrade` (once #122 lands).

Rollback: stop the VM as in 3, `sudo chmod 0750 /mnt/anj-backup/anj-cloud-prod` (vm-start then
refuses the share and starts anj-prod without it), restart `anj-cloud-vm.service`, start
`anj-cloud-vm-stop.service`. A later `--apply` restores the mode.

SSH: `ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-qual` (written by `--qual`); `anj` has
passwordless sudo inside the VMs (#89 (5)). The Debian image must match the digest pinned in
`deploy/host/libvirt/debian-13-genericcloud-amd64.sha512` and its `SHA512SUMS` line; Debian
publishes no signature for cloud-image checksums, so the reviewed pin is the trust anchor.
Evidence: `~/.local/share/anj-cloud/qualification/f15-vm-host-<UTC>-<mode>/`.

Order matters for the network mode (#89 (8)): `anj-prod` starts in libvirt NAT mode, and switching
to `--net-mode open` is only possible through `--recreate --confirm anj-prod`, which deletes both
disks. Run the forward probe (LAN client reaches `/health` through `192.168.0.10:443`) right after
the first `--apply`, before the bootstrap installs anything into the VM.

The VMs reach the VM host only for DHCP (67/udp) and DNS (53/tcp+udp to the bridge address); every other
input from `virbr-anjprod` and `virbr-anjqual` is denied (#89 (3) as refined). `--forward off`
writes `/etc/anj-cloud-host/forward-off` and disables the forward unit, whose
`ConditionPathExists=!` keeps it down across reboots until `--forward on`. Step 8 also installs
`/etc/sudoers.d/anj-cloud-host-alert` (validated with `visudo -cf`), letting only the operator user run
`/usr/local/lib/anj-cloud-host/anj-alert` as root for golive's emergency-stop fallback. The VM host
TLS check is pinned once `/etc/anj-cloud-host/issuer.crt` exists. The bootstrap (B2) creates the issuer inside
the VM and cannot write the VM host's `/etc`, so its summary prints the one operator step (sudo on the VM host, #49):
copy to a temporary file, check it with `openssl x509` (which prints its SHA-256 fingerprint, to compare
with the one the summary shows), install it atomically, so a failed ssh never installs an empty file, and
keep a user-owned copy, `~/anj-cloud-ca.crt` (devices no longer need it: the pairing code carries the CA's pin, decision #151):

```bash
bash -c 't=$(mktemp) && ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod cat /srv/anj-cloud/state/operator/issuer.crt > "$t" && openssl x509 -noout -fingerprint -sha256 -in "$t" && sudo install -m 644 -o root -g root "$t" /etc/anj-cloud-host/issuer.crt.new && sudo mv -f /etc/anj-cloud-host/issuer.crt.new /etc/anj-cloud-host/issuer.crt && install -m 644 "$t" ~/anj-cloud-ca.crt; rm -f "$t"'
```

## Bootstrap and VM operations (spec #21, B2: `anj-cloud-setup`)

`deploy/vm/anj-cloud-setup` turns a fresh Debian 13 machine into a complete anj-cloud server: the
`anj-prod` VM, `anj-qual`, or any small amd64 machine with one spare data disk and the admin user
`anj` (decisions #84, #85, #89). Python 3 standard library only, run with `sudo`. Inside the VMs
`anj` has passwordless sudo, so agents run installs, re-runs, `status` and `doctor`; only the
hidden secret prompts of the production install need the operator (#89 (5)); `stage.py --with-secrets`
removes them on the VM host (#109).

Once step 10 has run, `/usr/local/bin/anj-cloud-setup` links the installed release's copy, so every
printed instruction is `sudo anj-cloud-setup …`; before that, each one names the absolute path of
the copy that is running.

```bash
sudo anj-cloud-setup                      # guided install (or repair: re-runs only what is missing)
sudo anj-cloud-setup pair [--new-code]    # pair the first device: a code on demand, wait, approve
sudo anj-cloud-setup backup [--show-password]   # set up encrypted backups and save (or re-show) the password
anj-cloud-setup status [--json]           # one-screen health summary, read-only (as anj, or root)
sudo anj-cloud-setup doctor               # preflight plus every verification, strictly read-only, each with its fix
sudo anj-cloud-setup --answers FILE       # unattended install (TOML; secrets only by file path)
sudo anj-cloud-setup --dry-run [...]      # plan per step; changes nothing, asks no secret
sudo anj-cloud-setup --adopt-data         # OS rebuilt (halo-vm.sh --recreate-os), data disk kept
sudo anj-cloud-setup --restore-from /mnt/anj-backup   # new data disk, restore from spec #22's backup
sudo anj-cloud-setup first-code --reissue # = pair --new-code without waiting (scripts, qualification)
sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup upgrade   # switch to the staged release (stage.py --upgrade runs it)
sudo anj-cloud-setup upgrade --rollback   # switch back to the previous release
```

**Getting it onto a fresh VM.** The data disk, and so `/srv/anj-cloud/release/current`, exists only
after step 3. From the VM host, `python3 deploy/vm/stage.py anj-qual|anj-prod [--commit HEAD]`
copies `git archive <commit>` to the VM's `/var/lib/anj-cloud-setup/source.tar`, unpacks it to
`/var/lib/anj-cloud-setup/src/` and prints the runnable command,
`ssh -t -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup`
(`-t`: the questions need a terminal; the staged tar is its default `--source`). Spec #22's drill and
`backup_qualify.py` stage the same way.

**Secret hand-off from the VM host (decision #109; operator only).** `python3 deploy/vm/stage.py anj-prod --with-secrets`
stages the release, then starts the guided setup itself with the VM host's two existing secrets: the Cloudflare
token file (`~/.local/state/anj-cloud-prod/secrets/cloudflare-dns-token`) and the VM host's ntfy topic
(`/etc/anj-cloud-host/ntfy-topic`, read with `sudo cat`). Both are read into stage.py's memory and served
once over a Unix socket in a private 0700 directory, which `ssh -R` forwards into the VM (`ExitOnForwardFailure`,
no connection sharing; the VM end is `/home/anj/.anj-cloud-setup-<random>.sock`, owner-only through sshd's
`StreamLocalBindMask` 0177, and setup refuses it otherwise). The socket serves only the ssh child stage.py
started (its `SO_PEERCRED` pid): any other connection is closed before a byte is sent and logged without a
value, and serving goes on. Setup reads them into its own memory (`--secrets-socket PATH`, the only argument,
a path), removes the socket and stores them only in its 0600 state; a run that will not read them (no
terminal, `--dry-run`, `pair`, `backup`, `status`, `doctor`) removes the socket at once and stage.py reports
them as not used; they are never an argument, a file outside that state, a log line, evidence or terminal output.
Interactively setup then offers "Use the Cloudflare token copied from the VM host?" and topic option 1 "Use the
topic copied from the VM host" (the default); with `--answers` they are used when no `token_file`/`ntfy_topic_file`
is named. Agents never run it with the real files: `--token-file`/`--topic-file` exist for throwaway test values.

**The guided flow** (bootstrap UX audit M1–M9). A "Before you start" list (password manager, phone with
ntfy, the Cloudflare token, the app), then the machine checks (preflight) **before** the first question.
Numbered questions `[n/9]`, each saying what it is for: the public hostname (permanent: it is in the
server certificate; a non-default name is typed twice); DDNS; the Cloudflare zone ID (where to find it);
the Cloudflare API token (what it is, where it lives, what if lost; hidden, typed twice, only its length
echoed) followed by one **read-only** Cloudflare check (`ddns.py`'s GET of the A record: token, zone and
record together; on failure: paste again, change the zone ID, continue knowingly, or stop — with
`--answers` the run stops before any change); the ntfy topic as an explicit choice — copied from the VM host
(default with the hand-off), "I already have a topic — type it" (default on the VM host without it; hidden, typed
twice) or "Create a new topic" — and, for an existing topic, one test alert sent straight to ntfy and
"Did it arrive on your phone?" (no: check the subscription, resend, change the topic or skip); the accounts
(the first is the admin, read back for confirmation); the home network; the network (on the VM host the detected values, kept with Enter; elsewhere the bind address and the one SSH
source are asked, the source defaulting to this session's address, never the router, with a note to
reserve a DHCP address) with the **SSH lockout guard**: if this session comes from
another address than the SSH source (`$SSH_CONNECTION`, also read from the ancestor processes since sudo
resets it; an address not under a live sshd ancestor, e.g. inside tmux, is called possibly stale), setup
refuses unless the address is typed again, and Enter takes the current one (an IPv6 session is told to
reconnect with `ssh -4`; `--answers`: refused with a fix the answers check accepts); the time zone (backup 03:30, updates 04:12, reboot window 04:15–05:00). Then a
review of every answer and "Start installing?", the data disk with its size and model ("This erases it",
default N, "Nothing was changed" on N), and `[ n/12]` progress lines with a plain name, a purpose and the
usual duration, a "still working …" heartbeat every 30 s, and the result with its time. An unexpected stop
says where ("step 9 of 12 (starting anj-cloud)"), what in plain words (never an exception name), the two
commands that help (`doctor`, re-run) and the evidence path.

After the steps: a **created** topic is shown once with a terminal QR code of its `ntfy://ntfy.sh/<topic>`
subscribe link (`qrencode -t ANSIUTF8`, the link on its stdin, installed in step 1) and its notes, then the
test alert (with no terminal the link goes to `state/secrets/ntfy-subscribe-link`, 0600, #104 (6)); backups
are offered when the share is attached (below); then the summary, then pairing.

**Answers file** keys: `host`, `ddns` (`"on"`/`"off"`; a missing key means off, as spec #23's
opt-in), `zone_id`, `token_file`, `ntfy_topic_file`, `ntfy_server`, `accounts`, `display_names`,
`household_lan`, `bind_address`, `admin_ssh_source`, `timezone`, `data_disk`, `data_disk_init`,
`source`, `alerts_tag`, `restic_password_file`, `start_stack`, `wait_first_device`. A secret written
inline (`token = …`) or an unknown key is refused by name; flags (`--host`, `--ddns`, `--source`,
`--data-disk`) override the file. `deploy/vm/answers/qual.toml` is anj-qual's (`ddns = "off"`, a scratch
token file); `deploy/vm/answers/prod.example.toml` writes `ddns = "on"` explicitly for production.

**Preflight** (before any change; each failure prints a plain-language fix and nothing changes):
Debian 13, amd64, ≥3.5 GiB RAM, ≥2 CPUs, ≥8 GiB free on `/`, user `anj`, the data disk, DNS,
outbound HTTPS (Debian mirror, Docker Hub, npm registry, ntfy.sh, and Cloudflare's API with DDNS on),
port 443 free (other than our own HAProxy), time synchronized, no other Docker-published port. Example:
"Port 443 is used by apache2. Stop it with `sudo systemctl disable --now apache2`, then run setup again."

**Data disk rule.** A disk is initialised only when blkid, wipefs and its first and last MiB show no
signature at all, only after confirmation (or `data_disk_init = true`), and the check is repeated
right before `mkfs.ext4 -L ANJ_DATA` (run with empty stdin, so mke2fs's own question answers no). Any
signature (a file system, a partition table, LVM, unreadable or non-zero data) or any blkid/wipefs
probe error is refused with a fix; an `ANJ_DATA` disk needs `--adopt-data`, which never re-creates the
CA, secrets or accounts. Before formatting, setup records the new file system's UUID in
`/var/lib/anj-cloud-setup/formatted-data-disk-uuid`, so an install interrupted after `mkfs`
recognises its own disk on the next run. A blkid failure stops the run before `/etc/fstab` changes.

**Secrets with `--adopt-data` and `--restore-from`.** The DNS token and the ntfy topic live on the data
disk (or in the snapshot), so they are looked for only after step 3 mounts the disk (or after the
restore), and only what is still missing is asked for (or, with `--answers`, required as `token_file`).

**Changed settings on a re-run.** A changed `bind_address` or `household_lan` is applied everywhere: the
firewall (step 5), `prod.py setup` with the new values, HAProxy re-rendered and restarted onto them.
Step 9 checks that the firewall's 443 accept, `stack.json` and the rendered HAProxy bind are one
address. A changed hostname is refused with a fix (it needs a new server certificate; `prod.py`
refuses it too).

| Step | Change |
|---|---|
| 1 Packages | `qrencode` (terminal QR codes); Debian 13 `docker.io` 26.1.5 with `docker-cli` (Debian 13 ships the CLI separately) and `docker-compose` 2.26.1 (they satisfy `compose.prod.json`: Engine ≥25.0, Compose ≥2.20.2); otherwise Docker's apt repository (key pinned by digest, versions pinned, its origin added to unattended-upgrades). `nodejs`, `npm`, `nftables`, `unattended-upgrades`, `logrotate`, `curl`, `ca-certificates`, `python3`, `python3-cryptography` and `openssl` (prod.py and the operator CLI), `qemu-guest-agent` |
| 2 PM2 | `npm ci` from `deploy/vm/pm2/package-lock.json` (pm2 7.1.1) into `/opt/anj-cloud/pm2`, `/usr/local/bin/pm2` |
| 3 Data disk | `ANJ_DATA` on `/srv/anj-cloud` (fstab by UUID, `nofail`); `state/` 0700 and `release/` 0755 owned by `anj`; the virtiofs share `anj-backup` on `/mnt/anj-backup` (`nofail`: production runs without it, #89 (2)) |
| 4 Docker | `/etc/docker/daemon.json` (`data-root /srv/anj-cloud/docker`, journald, no userland proxy, no live-restore); group `anj-gw` (10002); `anj` in `docker` and `systemd-journal`; Docker requires the data disk mount |
| 5 Firewall | `anj-cloud-firewall.service` loads only `table inet anj_cloud` from `/etc/anj-cloud/firewall.nft` (input drop; loopback, established, ICMP, DHCP replies, 443 to the bind address, 22 from the admin source); never `flush ruleset`. The file is validated (`nft -c`) before it is installed, and replaces the table in one nft transaction; the unit reloads (never stops) and has no ExecStop, so input is never left open |
| 6 Journald | `zz-anj-cloud.conf`: persistent, 1G, 90 days |
| 7 SSH | read-only: password authentication and root login are reported, never changed |
| 8 Release | `state/release/<commit12>/source.tar`, extracted to `/srv/anj-cloud/release/<commit12>/`; a re-run never switches a release (`upgrade` does: Updating production) |
| 9 Stack | tmpfiles for `/run/anj-cloud-gw` and `/run/anj-haproxy`; `prod.py setup` and `up`; accounts (`user-add`, `account-set`); the first admin (audited); `pm2 startup systemd -u anj`, `pm2 save`, and the stack handed to `pm2-anj.service`; the 443 consistency check |
| 10 Operations | `/usr/local/bin/anj-cloud-setup` → `release/current/deploy/vm/anj-cloud-setup`; `state/bin/anj-alert` and `state/run/ops.json` (machine-local: `run/` is never backed up or restored, so a drill VM keeps its own `alerts_tag`; the restore step installs both before spec #22's init records the dispatcher); the ntfy topic and DNS token (0600); `state/ops/ecosystem.config.js` with `alerts`, `watchdog`, `watchers` and spec #23's `ddns` entry when DDNS is on; only missing or changed apps are (re)started |
| 11 Timers | time zone; `anj-cloud-boot-health.service`, `anj-cloud-reboot-guard.timer`, `anj-cloud-image-check.timer` and spec #22's `anj-cloud-backup*.timer` (rendered by `backup.py units`); `systemd-analyze verify` |
| 12 Updates | unattended-upgrades with Debian-Security origins only, no automatic reboot; `apt-daily-upgrade.timer` at 04:12 (after spec #22's 04:10 housekeeping deadline, #98), skipped by `backup.py window --check` while a marker or a backup or restore process is active; logrotate for `~anj/.pm2/logs` |
| 13 Summary | above; then backups and pairing; evidence `state/setup-log/<UTC>.json` (steps, before and after, changed commands and files by digest, the topic source and test result, the Cloudflare check; never a secret) |

A re-run on a complete install prints every step "already done" and restarts nothing.

**First admin (#87, #89 (9), #112 (3)).** The first account is admin on the registry's accounts table
(spec #26 built it with `admin` default 0). The bootstrap writes `admin = 1` for the first account once,
inside the gateway container, and only while no admin exists; it never demotes anyone. In the same
transaction it records one `admin_audit` entry (actor `bootstrap`, action `role-grant`, target the first
account, result `ok`), as #43's first-admin import records its own. An image without the column gets
`state/accounts.json` `{"admins": ["sam"]}` instead. With `--adopt-data` or `--restore-from` roles are kept.

**Pairing, last (M2).** Step 9 no longer issues the first code. Pairing is the install's last phase and
`sudo anj-cloud-setup pair` re-enters it at any time. The 10-minute clock starts only after "Is the
anj-cloud app open on that device? Press Enter when ready, or type 'later'": then one invitation is issued
through the operator's `invite`, shown once, in groups of four (the gateway ignores the dashes), with its
clock expiry and its notes. It is a pinned code (decision #151, spec #35): the person types the server
(prefilled) and the code, the app checks the CA against the code, and the gateway approves the device when
it redeems the code. Setup waits until the invitation is approved and prints "Paired: <uid>'s device
"<label>"" (label stripped of control characters). If the gateway's approval has not finished 45 s after
the device asked (its `console` app down), setup approves it itself through the operator's `approve` with
the fingerprint of the CSR that redeemed the code; nobody types anything. The gateway's alert pass then
writes its audit entry and sends its new-device alert once the console answers again (setup says so). A code issued before this release
(32 characters) still shows the fingerprint and approves when its last 4 characters are typed (the full
fingerprint is what `approve` checks); Enter does nothing there and refusing takes an explicit `deny`; then
"press Pair again" in the app. An expired code, also one that expires before the approval, says so and
offers a new one; Ctrl-C stops waiting. A live code is never
replaced without `--new-code` (#104 (5)): a re-run or `pair` says until when it works. With `--answers`
one code is issued at the end of the first run only, shown on a terminal, else written to
`state/secrets/first-pairing-code` (0600), and `pair` without a terminal never waits (0600 file).

**Backups (M7).** At the end of an interactive install, with the backup share attached and no
repository yet, "Set up encrypted backups now? You will save one password." runs `backup.py init
--show-escrow` as anj on the same terminal (`sudo anj-cloud-setup backup` later). The password is written
to `/dev/tty` only, with what is at stake (if this server's disks are lost, the backups can only be restored
with it), where to save it ("anj-cloud backup password" in a password manager kept off this server), then
confirmed by typing its last 6 characters (hidden, 3 tries); the screen and, where the terminal supports
it, the scrollback are cleared in every case, also on Ctrl-C or Ctrl-D.
`sudo anj-cloud-setup backup --show-password` (`backup.py show-password`) shows it again the same way.

**Summary (M3).** The status in plain words (server, firewall, DNS, backups, data disk, services with
"ddns idle between runs — normal"), the alerts line, warnings, then "What to do now, in order": the VM host
step (on the VM host), backups, the router forward (to the VM host, which forwards it, or to this server), the first
device; then the VM host step itself (the one-liner that pins the issuer for the VM host's host check, prints its
SHA-256 fingerprint and keeps a copy as `~/anj-cloud-ca.crt`), with the issuer fingerprint to compare; and
what the app's pairing dialog needs, field by field (P1): "Server" `https://<host>` (prefilled) and "Code".
It ends with "Saved in your password manager?" for the secrets this run showed.

### Updating production (decision #122)

Re-running `anj-cloud-setup` never changes the release. An update installs a reviewed commit as a new
release and switches to it through `prod.py redeploy`'s health-checked path. Tell the operator before
updating anj-prod; agents may run it (`anj` has sudo in the VM, #84 (5)). On the VM host, from a **clean**
checkout (`git status` empty) that has the commit:

```bash
git fetch origin main
python3 deploy/vm/stage.py anj-prod --commit <sha> --upgrade      # production: <sha> must be merged into origin/main
python3 deploy/vm/stage.py anj-qual --commit <sha> --upgrade      # qualification: a PR head is allowed
python3 deploy/vm/stage.py anj-prod --commit <sha> --upgrade --no-backup   # skip the backup first (warns)
```

**What stage.py checks and does.**
- It refuses a checkout with changes and a commit without prod.py's required fixes (4c3bb82, f554e13).
- For every target except `anj-qual`, it also refuses a commit that is not in `origin/main` as fetched.
- It then stages `git archive <sha>` exactly as for a bootstrap (`/var/lib/anj-cloud-setup/source.tar` and `src/`).
- It runs `sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup upgrade --expect <sha>` over `ssh -t`. It uses the staged copy because the installed command belongs to the old release, which may not know `upgrade`. The VM refuses a staged tar whose commit is not `<sha>` (a failed or concurrent stage).
- The exit code is the upgrade's.

**`anj-cloud-setup upgrade`** (root, in the VM):

1. **Refusals.** It refuses when:
   - nothing is staged (the installed copy says to use stage.py);
   - another upgrade runs (`/run/lock/anj-cloud-upgrade.lock`);
   - the install does not run the stack (`start_stack = false`);
   - a backup, restore or release switch is running: the operations lock (`state/run/backup.lock`), `restore.lock`, or a backup or restore marker before its deadline.

   A plain setup re-run on an installed server refuses in the same cases.
2. **No switch.** Upgrading to the release that is already live (`stack.json` and `release/current`) switches, backs up and restarts nothing. It still runs step 8 (converge), so running the same upgrade again finishes a setup an earlier upgrade left incomplete.
3. **Backup first.**
   - When backups are set up and the last successful backup is older than 24 hours, it runs `backup.py run`, detached like the switch (step 5): a dropped session does not kill a backup that has Nextcloud in maintenance mode. If that backup fails, nothing is updated. `backup.py` treats SIGHUP and SIGINT like SIGTERM: it unwinds and turns maintenance mode off.
   - `--no-backup` skips the backup, with a warning.
   - When backups are not set up (`sudo anj-cloud-setup backup`), it warns and continues.
4. **Install.** It installs the staged tar as step 8 does:
   - `state/release/<commit12>/source.tar` (0600 `anj`, 0700 directories);
   - extracted by `anj` to `/srv/anj-cloud/release/<commit12>/` (0755).

   An existing tar must be the same commit. If it is neither the live nor the previous release and its bytes differ from the staged one, it is replaced and extracted again.
5. **Switch.** It runs the new release's `python3 deploy/prod.py redeploy <commit> --source <that tar>` as `anj`, in **its own session with no terminal**, started directly under `anj`'s uid, gid and groups (no `runuser`, whose watching parent SIGKILLs its child 2 s after forwarding a SIGTERM). Ctrl-C at the terminal, or an ssh session that drops, stops only the waiting:
   - The switch goes on in the VM and either finishes or falls back by itself.
   - setup says "The upgrade is still running in the VM … see `anj-cloud-setup status`". `status` shows "Update running now".
   - prod.py's output goes to `/var/log/anj-cloud-setup/upgrade-<UTC>.{out,err}`.

   redeploy does the rest (Redeploy, above):
   - it renders `compose.json`, `haproxy.cfg`, `ecosystem.config.js` and `release.json` from the new source;
   - it installs the new `state/bin`;
   - it restarts and checks the stack;
   - it switches, then restarts `console`, `watchdog` and `watchers`.
6. **Timeout.** After 1 hour, setup sends SIGTERM to every process of that session, which makes prod.py fall back (its first signal also ignores every further one, so a second cannot cut the fallback short). After 30 more minutes it sends SIGKILL. It then reports that the state is unknown (check `prod.py status`).
7. **After the switch.** It refreshes `state/bin/anj-alert` from the new release and restarts `alerts`, only if the dispatcher changed. It records `release` and `last_upgrade` in `setup.json`.
8. **Converge (flag SC-110).** A new release can change what a setup step wants (the PM2 ecosystem's `ddns` arguments, the firewall file, the PM2 lockfile, a timer). The switch alone does not apply that, so the upgrade then runs the **live release's own** `anj-cloud-setup converge` as root, detached like the switch (its own session, no terminal, output in `/var/log/anj-cloud-setup/converge-<UTC>.{out,err}`, shown when it ends): a dropped session or Ctrl-C does not cut it short. It runs under the upgrade's own setup lock (`/run/lock/anj-cloud-upgrade.lock`, handed down as an open descriptor); a standalone `sudo anj-cloud-setup converge`, an upgrade and a setup re-run on an installed server each take that lock, so no two of them run at once.
   - **Answers.** It reads every step's state under the answers recorded in `setup.json` (the host from `stack.json`). The SSH source is the recorded `admin_ssh_source`; only when `setup.json` has none does it use the live firewall's rule (a commented-out rule is no rule). Any other missing answer refuses rather than guesses; with DDNS on, a missing or placeholder `zone_id` refuses.
   - **Safe steps, re-applied** through the same check → apply → verify as an install when no longer "already done":
     - 2 PM2. It installs into `/opt/anj-cloud/pm2.new`, checks the tree loads as `anj` and is the pin, then swaps the two directories in one step (`renameat2` exchange). A failed or interrupted install leaves the installed PM2 untouched. The running daemon keeps its version until its next start (a reboot); `pm2 update`, which restarts every app, is never run, and a new pin says so.
     - 5 Firewall. `nft -c`, then one atomic reload. Converge never moves the SSH source: when the live rule's source differs from the recorded one, or the `--answers` path's lockout guard sees this session coming from elsewhere, step 5 is blocked instead.
     - 6 Journald (restarts `systemd-journald` only).
     - 10 Operations apps. Only the missing or changed operations apps are replaced, the `pm2 delete` + `pm2 start` pair with hang-up, Ctrl-C and SIGTERM held off; a start that fails brings back the previous definition (`state/ops/ecosystem.previous.config.js`, kept for that run). Blocked when the ntfy topic or DNS token is missing.
     - 11 Timers, 12 Updates.
   - **Blocked steps.** When step 1 Packages, 3 Data disk, 4 Docker, 8 Release, 9 Stack, a blocked step 5 or 10, or a step whose state cannot be read is not done, it applies **nothing** and names each step, its state and why (apt may upgrade Docker; Docker, `prod.py setup` and `up` can restart the gateway, Nextcloud, the database or HAProxy). Run `sudo anj-cloud-setup` at a terminal: it shows and applies each step.
   - **Failures.** A safe step that fails does not stop the later ones (they are independent): each failure is named and the run exits 1.
   - It never prompts, issues a pairing code, offers or runs a backup, or writes a secret.
   - It then runs doctor's checks (read-only). Any problem left fails it, including doctor's network reachability checks.

   The upgrade prints the child's output, what was re-applied ("Setup re-applied: step 10 Operations apps", or "every step was already done") and "Doctor: all checks pass". Only then does it say "live and healthy" and exit 0. Otherwise it says "Release <commit12> is live …, but this server is NOT fully set up for it", lists every step not applied and every problem with the next command, and exits 1; the switch itself stands. When the cause may have passed (a network blip), running the same upgrade again re-applies and re-checks without switching anything. Ctrl-C while converging stops only the waiting (exit 130); converge finishes in the VM. Evidence: the upgrade's `state/setup-log/<UTC>.json` lists the re-applied steps under `steps` (or "unknown …" when converge ended without a result) and converge's outcome under `converge`; converge writes its own `state/setup-log/<UTC>-converge.json`.

   `deploy/vm/local_upgrade.py` runs the **installed** `anj-cloud-setup upgrade --source <tar>`: on its first hop from a release older than this one, that old code does not converge. Run `sudo anj-cloud-setup converge` once afterwards (or update through `stage.py`, which runs the staged new copy).

On a failure nothing switches. setup prints the reason and "The live release is still <commit12>; nothing switched", then exits 1. It also says "An alert was sent" only when prod.py reported one (build, verification, health check or interrupt). A refusal before the redeploy started sends none. The old release's tar, tree and image stay in place.

**Rollback.** `sudo anj-cloud-setup upgrade --rollback` switches back to `stack.json`'s `previous_release` through the same path, including the backup first. If the last switch did not finish (`stack.json` names a release that is not live), it rolls back to the live release instead.

After a rollback, step 8 runs the setup of the release that is now live, so the server converges to the **old** release's wants (the command that started the rollback belongs to the newer release; its steps are never applied). A release older than `converge` cannot re-apply anything by itself: the rollback then runs that release's own read-only `doctor` and exits 1 if it finds a problem. Then run `sudo anj-cloud-setup` at a terminal (the old release's setup re-applies what is missing, from the recorded answers) and `sudo anj-cloud-setup doctor`.

The newest prod.py that has `--source` drives a rollback; a release older than #122 has no `--source`. After a rollback to such a release, its installed `anj-cloud-setup` has no `upgrade`. The way forward again is to re-stage from the VM host with `stage.py <vm> --commit <sha> --upgrade`, and setup prints that line. A rollback between two releases that both have `upgrade` can be reversed with another `--rollback`.

**Data migrations: a one-way door.**
- The pinned Nextcloud image upgrades its database on its first start on a newer image, and refuses to start on data newer than itself.
- The gateway migrates its registry forward on start.
- So after a release that bumps the Nextcloud pin or the registry schema has started, an older release cannot simply run again. In particular, if a forward update fails after Nextcloud has started on the new image, the automatic fallback cannot start the older Nextcloud, and the stack stays down until it is restored from the backup taken first (or the update is retried). Neither `--rollback` nor the automatic fallback can undo it: the way back is a restore from the backup taken before the update (Restore, above).
- Until the migration guard lands (a follow-up to this delivery: each release records its Nextcloud and schema versions, and `--rollback` and the fallback refuse an older target), check `deploy/compose.prod.json`'s `nextcloud` image and `services/access/registry.py` before updating across such a change. Make sure a fresh backup exists.

Secrets, the data disk, accounts and the OS-level steps (firewall, units, tmpfiles) are not touched. If the new release changes those, `sudo anj-cloud-setup doctor` names the step afterwards and a plain `sudo anj-cloud-setup` re-run applies it.

**Watchdog.** A running `anj-cloud-setup upgrade` and the `prod.py redeploy` it starts are mutating maintenance runs. Each suppresses restarts for at most 15 minutes (decision #113); a run still going after that gets one "watchdog suppressed by …" alert. The backup first has its own marker, and the image build runs before anything restarts.

After an update, `anj-cloud-setup status` shows the release and the last update, and `sudo anj-cloud-setup doctor` should pass. Old releases accumulate in `/srv/anj-cloud/release/` and `state/release/`. Remove one only if it is neither `release/current` nor `previous_release`.

### VM operations (decision #89 (4): PM2 for long-running work, systemd for boot and calendar jobs)

- **`alerts`** (PM2): `state/bin/anj-alert --key K [--every S] [--title T] [--priority P] -- MESSAGE`
  queues one record in `state/run/alerts/` (spec #20's `ALERT_SPOOL_FIELDS`, 0600) at most once per
  key per `--every` seconds (default 3600; `--every 0` for callers that throttle themselves, #99).
  `anj-alert --drain` posts them oldest first to ntfy.sh on `secrets/ntfy-topic`, retrying with
  backoff up to 5 minutes; messages are scrubbed of paths and secret-like strings; `alerts_tag`
  (drill, qualification) prefixes titles. Root callers are switched to `anj` first.
- **`watchdog`** (PM2, every 60 s): stack apps online and healthy, spec #20's healthcheck, the
  HAProxy path, Nextcloud `status.php`, `alerts` and `watchers` online, spec #27's `console` online
  with its socket answering (an empty request gets its refusal; 60 s grace after a start). Only PM2 `errored`, or an app
  PM2 reports `online` whose checks fail, counts: `stopped`, `stopping`, `launching` and `waiting
  restart` (`prod.py stop`, redeploy, PM2's own backoff) never do, and Docker health `starting` is "not
  yet" for the service's own `start_period` + `interval` x `retries` from `compose.prod.json` (Nextcloud
  330 s). Three failures → `pm2 restart` and one "restarted" message; still failing 5 minutes later
  → one "down", then one "recovered"; at most 2 restarts per app per hour (each with its "restarted"
  message), then a third is not attempted and one "down, not restarting" alert is sent instead. A
  dependency's failure is not counted against its dependents. Apps held by the emergency stop, and
  PM2 `stopped` apps, are reported, never restarted or alerted. DDNS alerts its own failures
  (`--every 0`), so the watchdog alerts only when DDNS has not run for 30 minutes at all.
  **Every quiet or "not yet" state is bounded (decision #113)**, and its expiry raises exactly one
  alert naming the reason:
  - 3 or more PM2 restarts of one app in 10 minutes (the watchdog's own not counted) is a crash
    loop: one alert, no watchdog restart while PM2 restarts it; the crash-loop state ends after a full
    10 minutes without a PM2 restart, whatever the health, and a still failing app then gets normal
    handling (2 restarts an hour, then "down, not restarting") inside the same down episode, which a
    healthy round closes with one "recovered";
  - flapping (decision #113): unhealthy in at least half of the last 30 rounds, and healthy in at
    least one, gives one "flapping" alert unless a down or crash-loop episode is open for the app;
    30 healthy rounds in a row close it with one "recovered"; the round history survives a recovery,
    and a down episode whose window already flapped before the recovery (a healthy round earlier
    in it) stays open as flapping, so repeated down/up cycles are one episode, while a single outage
    recovers on its first healthy round (only the window from its first unhealthy round counts, so
    healthy rounds before an outage never make it "flapping"); an alert whose enqueue fails is
    retried every 5 rounds, bypassing the dispatcher's throttle, and only a queued alert marks its
    episode;
  - "not yet" (launching, waiting restart, no container yet, health `starting`, missing from PM2)
    lasts at most twice the app's health window (container pending grace 120 s + the healthcheck
    bound, e.g. Nextcloud 2 × 450 s) since it was last healthy, then one "down"; PM2 not answering
    at all, one alert per episode once 4 minutes of it add up (the episode survives answering gaps
    under 10 minutes, and its rounds freeze every app's counts and clocks instead of clearing them);
  - a round in which an app's dependency fails clears nothing: the app's clock keeps aging, and it
    alerts itself unless the dependency is on its own clock, has alerted or was stopped on purpose;
  - an unreadable backup or restore marker suppresses nothing (one alert); a `watchdog.json` of the
    wrong shape is reset with one alert; a round error never resets the state and alerts at most
    hourly; a backward clock step never stretches a bound;
  - Nextcloud in maintenance mode with no backup or restore marker: one alert at 30 minutes, no restart;
  - quiet reasons (nothing counted): a backup or restore marker before its deadline (its own bound);
    every mutating maintenance run at most 15 minutes from first sight: an `anj-cloud-setup`
    install, adopt or restore, `prod.py up`/`stop`/`redeploy`, apt, dpkg, unattended-upgrade or the
    update run (its short tail after the run stays inside the same 15 minutes), the system starting
    or stopping and the first 10 minutes after boot. Only a real interpreter running the script
    counts: `status`, `doctor`, `first-code`, `pair`, `backup`, `--dry-run`, editors and pagers never suppress. Past its
    bound a reason stops suppressing and one "watchdog suppressed by <reason> for N min" alert is
    sent (the dispatcher also throttles it per hour); an attended first install that runs longer
    gets that one harmless alert.
- **`watchers`** (PM2, every 60 s, gateway journal): one alert per enrollment block (6 per hour, then
  an hourly summary), ≥20 enrollment 429s or ≥10 401/403 from one source in 5 minutes, certificates
  within 30 days, a daily digest. Backup and DDNS failures are alerted by their owners; the watchers
  only count them in the digest. They also remove `secrets/first-pairing-code` once its invitation
  expired (setup removes it on approval or reissue; backups exclude it) and the no-terminal
  `secrets/ntfy-subscribe-link` after a day.
- **`console`** (PM2, spec #27, decision #112 (1)): the console backend behind the Admin section and
  `anj-cloud-admin` (Household administration, above).
- **`doctor`, `status` and `--dry-run`** are strictly read-only: `pm2` runs only while `pm2-anj.service`
  has a live daemon (any `pm2` command would otherwise start one), the update check reads `apt-config
  dump` and the last run's log instead of `unattended-upgrade --dry-run`, and no Python bytecode cache
  is written. Step 9 also compares the live 443 listener (`ss -ltnH`) with the recorded bind and
  restarts HAProxy when it still serves an old one; `--adopt-data` and `--restore-from` refuse a changed
  host as soon as the data disk or the restore shows the recorded one.
- **`anj-cloud-boot-health.service`** (`Type=exec`: boot never waits for it, and it always exits 0):
  once per boot, one "back healthy after reboot" message (an emergency stop is stated), or one alert
  at 10 minutes naming the failed checks.
- **`anj-cloud-reboot-guard.timer`** (04:15, root): reboots only when `/run/reboot-required` exists,
  between 04:00 and 05:00, with `backup.py window --check` clear, no backup, restore or restic
  process, and the dpkg lock free; otherwise rechecks every 5 minutes until 05:00. One alert when a
  reboot has been pending more than 3 nights. Decisions are JSON lines in the journal.
- **`anj-cloud-image-check.timer`** (weekly): newer digests and point releases of the pins, Debian
  security updates in the Python image, OSV for `requirements.txt`; internet-facing pins (Python,
  HAProxy, OpenSSL, aiohttp, cryptography) alert after 7 days behind a fix, others after 30.

### Qualification

- **Merge (The VM host, no VM):** `tests/test_vm_bootstrap.py` (preflight fixes, answers, no-format rule,
  dry run, script safety, units with `systemd-analyze verify`, first code and evidence),
  `tests/test_vm_ops.py` (dispatcher against a loopback ntfy, watchdog, watchers, boot health, the
  reboot window guard with the clock and markers injected), `tests/test_vm_watchdog_bounds.py`
  (decision #113: the real probe and watchdog over hours of simulated crash loops, maintenance and
  quiet reasons), `tests/test_vm_bootstrap_round3.py` (a dry run that fails on any write or spawning
  command; the live listener; the host check after the disk; qualify.py's leak search and log
  parsing), `tests/test_vm_prompts_pty.py` (the prompts, hidden entries typed twice, and two whole guided
  installs from the banner to the approved device through a real pseudo-terminal on
  `tests/vm_bootstrap_flow.py`'s fakes: secrets from the VM host, and a new household with a QR code and the
  lockout guard), `tests/test_vm_bootstrap_ux.py` (each UX must-have, the hand-off socket, the escrow
  confirmation, the first-admin audit entry on a real registry, and no secret in any argument, output or
  evidence), `tests/test_prod_upgrade.py` (decision #122: `redeploy --source`, `upgrade` and
  `--rollback` with two real git-archive releases, the no-op, the failed check, `stage.py --upgrade`'s
  refusals).
- **VM rows on `anj-qual`** (after the operator's `halo-vm.sh --apply --only qual-firewall`):

  ```bash
  systemd-run --user --scope --unit=anj-test-<tag>-<n> -p MemoryMax=2G -p TasksMax=512 \
      deploy/.local/access-venv/bin/python deploy/vm/qualify.py --run-id <tag>-<n> [--commit HEAD] [--rows …] [--keep] [--evidence DIR]
  ```

  Rows, in order on one `anj-qual` (`--list` prints them): create; stage (release, scratch token,
  `qual.toml`); dry run changes nothing; install through the secret hand-off with throwaway values (token
  and topic byte-exact in the VM, the socket removed, the summary's checklist and client fields; the code
  file is 0600 anj); `status`, `doctor` and
  `--dry-run` change nothing and start no PM2 daemon, with PM2 up and with `pm2-anj.service` stopped;
  idempotence (no restart, no second code); firewall (443 from the VM host outside the VM and from a
  non-admin source in a network namespace, 22 refused from it, Docker's tables intact); first admin (and
  its one audit entry); pair without a terminal (`--new-code` replaces, a live code is kept,
  `first-code --reissue`, status through `/usr/local/bin/anj-cloud-setup`); enrolment at a terminal
  (`pair --new-code` over `ssh -tt`: the grouped code enrols a synthetic device through HAProxy, typing the
  fingerprint's last 4 approves it, then an mTLS DAV write and read); `console` (decision #112 (1), SC-041:
  the PM2 app started by the bootstrap and watched; directory 2750 `anj:anj-gw`, socket 0660, read-only in
  the gateway, whose process keeps group `anj-gw` and no capability; `nobody` refused, no listener; that
  enrolled device as admin lists users, grants and removes a role with the confirmation, reads Health's
  PM2 through the backend, and a user add held 150 s behind the operator lock shows "setup incomplete"
  while it runs and completes through 202 polls, every exchange under 60 s; `anj-cloud-admin admins` and
  `health` over SSH); `--adopt-data` on the same disk keeps roles; doctor
  failure rows (stopped app, missing firewall table, full data disk); security-only updates and the
  update run skipped on its ExecCondition under a marker (`window --check` 0/1/0); killed containers
  (#20: a PM2 restart within 60 s, counted, healthcheck ready within 3 minutes); DDNS off, the
  household address in HAProxy's runtime `show acl`, an invalid one refused with one alert (#23);
  hung gateway (one restart, one delivered message, no "down"); watchdog quiet (no restart, no
  watchdog alert) under a marker and the emergency stop; watchdog cap (two restarts seeded into
  `state/run/watchdog.json`, then one real hang: one "down, not restarting", no further restart, one
  "recovered"; the hour's timing is proven by the unit tests with a fake clock); reboot (PM2 resurrects, one healthy notice, no watchdog restart in the
  first 10 minutes); the emergency stop persists across a reboot (#20: haproxy and gateway stopped,
  443 refused, the other apps online, the notice states it); the boot notice's failure path; and a
  production update (`upgrade`, decision #122: bootstrap with `--commit origin/main`, then to
  `--upgrade-to`, default HEAD, through `stage.py --upgrade`'s checks and staging; health, the switch,
  release files rendered from the new source, `console`, `watchdog` and `watchers` restarted after the switch,
  secrets, accounts and the data disk unchanged, `doctor` passes; the same release again is a no-op;
  `upgrade --rollback` and the same checks, with the re-stage hint for a release older than #122; upgrade
  again with the ssh session killed mid-switch, which prod.py finishes by itself); and a
  final leak sweep. Both pairing codes, the ntfy topic and the scratch token are copied into in-VM
  pattern files only; every VM log, the journal, the PM2 logs, `state/run/` and the run's host-side
  outputs are searched inside the VM, and only found/clean per place is reported.
  `--qual-destroy --run-id` runs in every outcome unless `--keep`; exit 3 from `--qual` (busy or
  another run's VM) stops the run and destroys nothing. Spec #22's hard cap and drill
  run separately through `backup_qualify.py` (they need anj-prod's restic password).
