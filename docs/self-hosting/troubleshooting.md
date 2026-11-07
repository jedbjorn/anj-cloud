# Troubleshooting

Start with read-only checks and the fix printed by each command. Replace `cloud.example.com`, account names,
addresses, and IDs in these examples with your own values. Never paste pairing codes, API tokens, ntfy
topics, private keys, or real household addresses into an issue.

## Generic VM or dedicated machine

Run these commands as `anj` inside the server unless `sudo` is shown:

```bash
anj-cloud-setup status
sudo anj-cloud-setup doctor
cd /srv/anj-cloud/release/current
python3 deploy/prod.py check
python3 deploy/prod.py status
```

- `anj-cloud-setup status` is the one-screen summary. Expect `Healthcheck     ready` when healthy.
- `doctor` performs read-only preflight and verification checks and prints a fix for each problem.
- `prod.py check` verifies PM2, ports, health, TLS, accounts, and related production invariants.
- `prod.py status` prints app, restart, container-health, and gateway-health JSON.

Run the two `prod.py` commands from `/srv/anj-cloud/release/current` as shown. If an initial installation
fails before the stable command link exists, use `sudo deploy/vm/anj-cloud-setup doctor` from the public
checkout instead.

### Installation and account problems

| Symptom | What to do |
|---|---|
| `git: command not found` on a fresh Debian cloud image | Install Git before cloning: `sudo apt-get update`, then `sudo apt-get install -y --no-install-recommends git`. See the [quick start](quickstart.md#3-run-the-guided-installer). |
| The current OS account is not `anj`, or `anj` cannot use sudo | Follow the [account bootstrap](quickstart.md#create-and-log-in-as-anj-if-needed): create `anj` only if absent, add it to the sudo group, and start a fresh `su - anj` login. Do not run the install directly as root. |
| Guided install reports a preflight error | Fix exactly what it prints, then rerun it. Checks include Debian 13/amd64, CPU/RAM/OS space, user `anj`, one suitable data disk, outbound HTTPS, free TCP 443, synchronized time, and Docker port conflicts. |
| Setup finds zero or multiple unused disks, or refuses a disk signature | Stop and review `lsblk`. Detach extra unused disks so exactly one new blank data disk remains; do not wipe an unidentified disk or bypass the signature checks. |
| Setup stops after earlier steps completed | Read the printed fix and evidence path. Finished steps are kept; run `doctor`, then rerun setup rather than deleting state. |

### Pairing and client access

| Symptom | What to do |
|---|---|
| A device says **“This code is not for this server”** | The code came from another server or the server field is wrong. Use the exact public address, for example `https://cloud.example.com`, with no port or path. Do not disable certificate checks. |
| A code is refused or expired | Codes are single-use and valid for ten minutes. Create a new invitation in Admin, or use `sudo anj-cloud-setup pair --new-code` for the first admin device. |
| Pairing works at home but not outside | Check public DNS and the router's external TCP 443 to internal TCP 443 rule for the generic server's fixed LAN address. A CGNAT connection cannot accept this inbound path. |
| Pairing works outside but not at home | Check hairpin NAT or configure split DNS so the same hostname resolves to the generic server's LAN address at home. Do not change the certificate name or URL port. See [DNS, TLS and forwarding](dns-tls-forwarding.md#hairpin-nat-and-split-dns). |
| The last admin has no paired device | Run `anj-cloud-admin invite --user <account>` as `anj`, then pair a new device with that code. See [Accounts and pairing](accounts-and-pairing.md#recovery-cli-inside-the-server). |

For a read-only public-address comparison, run from a public checkout:

```bash
python3 deploy/golive.py line-check --router-wan <CURRENT_PUBLIC_WAN_IPV4>
```

This compares two independent public-address services with the router WAN address. It does not prove that
inbound TCP 443 reaches the server; an outside-LAN client pairing is the complete check.

### DDNS and alerts

For Cloudflare DDNS, first make a read-only record request as `anj` from the installed release. Replace the
zone placeholder with the 32-hex-character zone ID, not an API token:

```bash
cd /srv/anj-cloud/release/current
python3 -I deploy/ddns.py check --zone-id <CLOUDFLARE_ZONE_ID>
```

The JSON must describe the intended A record with `"dns_only": true`. If the record is stale, this command
runs one update cycle:

```bash
cd /srv/anj-cloud/release/current
python3 -I deploy/ddns.py run --zone-id <CLOUDFLARE_ZONE_ID>
```

Unlike `check`, `run` can change the DNS record and household-address rule. It uses the existing token file;
do not print or copy that token. The updater never creates the A record. Three consecutive update failures
trigger an alert, but an alert cannot arrive if the server or its network cannot reach ntfy.

If no alerts arrive, confirm that the server can reach `https://ntfy.sh`, the phone is subscribed to the
intended private topic, and the setup test was confirmed. Do not publish the topic while debugging. Local
ntfy alerts are not independent external monitoring of a dead server, router, or ISP path.

### Upgrades

If `local_upgrade.py` refuses the checkout:

- run it from the clean public clone root, not from the installed release directory;
- check `git status --short` and preserve any local or untracked work instead of deleting it;
- run `git pull --ff-only origin main` before the wrapper; the wrapper itself fetches but does not pull; and
- make sure the exact `HEAD` is merged into the fetched `origin/main` and has the supported reviewed history.

If an upgrade seems stuck, check `anj-cloud-setup status` and
`/var/log/anj-cloud-setup/upgrade-<UTC>.{out,err}`. Do not start another upgrade while one is active. The
health-checked switch can finish or fall back after the terminal disconnects; neither that fallback nor
`upgrade --rollback` reverses Nextcloud or registry data migrations. See [Upgrades](upgrades.md).

### Backups on a generic quick-start server

A missing-backup warning is expected: the generic quick start does not configure a repository or the
virtiofs share. Do not create a repository in a directory on the same data disk and do not treat timer units
or alerts as backup evidence. The existing encrypted workflow is documented only for the
[advanced VM-host route](backups.md#scope-the-existing-workflow-is-advanced-only).

### Stop public access while investigating

First disable the router's TCP 443 forward. To stop HAProxy and the gateway persistently across reboots, run
as `anj` inside the generic server, without sudo:

```bash
python3 /srv/anj-cloud/release/current/deploy/prod.py emergency-stop --reason "what you observed"
```

Use `python3 /srv/anj-cloud/release/current/deploy/prod.py resume` only after deciding to restore public
access. See [emergency stop](dns-tls-forwarding.md#stop-conditions-and-emergency-stop).

## Advanced libvirt VM host only

Keep these commands and symptoms out of a generic quick-start machine. They apply to the separately
configured host and its `anj-prod` VM.

Run the host-side read-only verification **on the VM host**:

```bash
sudo deploy/host/halo-vm.sh --verify
```

| Advanced-only symptom | What to do |
|---|---|
| `halo-vm.sh` says “no deployment profile found” or “runs only on <name>” | On the VM host, check `~/.local/share/anj-cloud/profile.toml` and that `[host] name` matches that host. The generic route does not use this profile. |
| Host preflight lists missing tools or image artifacts | Supply exactly what the advanced host procedure names; the host script does not install those tools or substitute a different pinned image. |
| The router forward reaches the VM host but not `anj-prod` | Run `sudo deploy/host/halo-vm.sh --verify` on the host and check its host-to-VM TCP 443 forward. The generic router rule instead targets the generic server directly. |
| Advanced backup alert | Inside `anj-prod`, run `cd /srv/anj-cloud/release/current`, then `python3 deploy/backup.py status` as `anj`. On the host, verify the external drive and virtiofs share with `halo-vm.sh --verify`. |
| Host-side emergency stop is required | On the VM host, use `sudo deploy/host/halo-vm.sh --forward off`, or the advanced `python3 deploy/golive.py stop --reason "..."` with its configured SSH alias. Restore only with `--forward on` or the in-VM `prod.py resume` as appropriate. |

Still stuck? Open an [issue](https://github.com/jedbjorn/anj-cloud/issues) with the command, step, and
redacted output. For a security problem, follow [SECURITY.md](../../SECURITY.md).
