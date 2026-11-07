# Backups and restore

## Scope: the existing workflow is advanced-only

The encrypted backup workflow on this page belongs to the **advanced libvirt VM-host route**. An external
drive attached to that host is shared into `anj-prod` through **virtiofs**, with tag `anj-backup`, at
`/mnt/anj-backup`. The restic repository is `/mnt/anj-backup/restic`.

**The [generic quick start](quickstart.md) does not supply this share or a backup repository.** Its one data
disk is not a backup. Do not point `backup.py` at a directory on that same data disk, invent a local mount,
or treat installed timers and ntfy alerts as evidence that a restorable backup exists. Production backup
commands require the expected virtiofs share, and a same-disk directory would not protect against disk or
server loss.

A generic backup target and restore procedure remain necessary before relying on a generic quick-start
server for irreplaceable data. The rest of this page applies only after the advanced host and backup share
have been configured as described in [The VM host and gateway VM](host-and-vm.md).

## What the advanced backup contains

The backup uses [restic](https://restic.net) and includes:

- the AnJ Cloud state root, including operator certificates/keys, secrets other than the restic password,
  release source archives, and stack configuration;
- the Nextcloud and gateway volumes, including household files and a consistent gateway registry copy;
- PostgreSQL database and role dumps; and
- a manifest with counts and sentinel checksums.

Redis is not backed up. The nightly timer runs at 03:30 local time. A nightly run briefly enables Nextcloud
maintenance mode while it takes consistent dumps and snapshots, with a hard 30-minute maintenance cap. A
night missed while the VM is off is not caught up automatically at boot.

The external drive is never formatted by this workflow. The VM sees only the designated backup directory
through the host's virtiofs share, not the whole block device.

## Initialize and check the advanced backup

The preferred interface is an interactive terminal inside `anj-prod`:

```bash
sudo anj-cloud-setup backup
```

This initializes the repository and shows the repository password on the terminal with an escrow
confirmation. Save a copy off the server and off the backup drive. **Without that password, the repository
cannot be decrypted for recovery.** To show it again through the same terminal-only interface:

```bash
sudo anj-cloud-setup backup --show-password
```

The equivalent lower-level commands run as `anj`, not root, from the installed release directory:

```bash
cd /srv/anj-cloud/release/current
python3 deploy/backup.py init --show-escrow
```

Optionally run a first full backup immediately, choosing the maintenance cap in minutes:

```bash
cd /srv/anj-cloud/release/current
python3 deploy/backup.py seed --cap <minutes>
```

The guided installer installs the nightly and stale-backup timers, but a timer is useful only after the
repository is initialized successfully. The stale check alerts after 36 hours without a successful backup.

Check status or run restic's repository check as `anj`:

```bash
cd /srv/anj-cloud/release/current
python3 deploy/backup.py status
python3 deploy/backup.py check
```

`status` prints JSON with repository, last-success, and housekeeping information. These commands do not
replace a restore drill.

## Restore in the advanced route

Restore is a fresh-install operation, not a generic in-place cleanup command. The guided restore adopts the
latest snapshot's state, release source, database, volumes, and household files rather than intentionally
creating a new household CA, accounts, or secrets.

### New OS disk and new data disk

1. On the **VM host**, rebuild `anj-prod` with a new OS disk and a blank data disk, keeping the configured
   backup share attached. Follow the advanced host procedure; do not format or replace the backup drive.
2. From the host's reviewed checkout, stage a source archive into the rebuilt VM:

   ```bash
   python3 deploy/vm/stage.py anj-prod
   ```

3. In an interactive terminal **inside the rebuilt VM**, run the staged installer with restore mode:

   ```bash
   sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --restore-from /mnt/anj-backup
   ```

   `--restore-from` accepts only the expected `/mnt/anj-backup` share. Setup asks for the escrowed backup
   password, reads the repository ID, restores the latest snapshot, and continues through the normal
   health-checked setup steps. The staged path is necessary because a new OS disk does not yet have the
   stable `/usr/local/bin/anj-cloud-setup` link.

4. After setup is healthy, verify as `anj` from the restored release:

   ```bash
   cd /srv/anj-cloud/release/current
   python3 deploy/prod.py check
   python3 deploy/prod.py status
   ```

A complete restore keeps the household issuer and server certificate, so existing devices do not need to
re-pair merely because the OS and data disks were replaced. Verify a real device before declaring recovery
complete. A restore does not prove that a later backup is healthy; check the next scheduled run too.

### Only the OS disk is lost

The advanced host command below rebuilds the OS disk while preserving the data disk:

```bash
sudo deploy/host/halo-vm.sh --recreate-os
```

Stage the source from the host as above, then adopt the existing `ANJ_DATA` disk inside the VM:

```bash
sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --adopt-data
```

Adoption keeps the existing household state rather than initializing a new CA, account list, or secret set.
Run the same release-directory `prod.py check` and `prod.py status` afterwards.

## Test the advanced backup with a restore drill

From the **VM host user's** reviewed checkout:

```bash
python3 deploy/backup.py drill
```

The unattended drill creates a throwaway qualification VM with the backup share read-only, restores into
it, checks the restored data and gateway path, and destroys only the drill-owned VM. It refuses while
another qualification VM exists and between 03:20 and 05:00 local time. Its receipt is written under
`~/.local/share/anj-cloud/qualification/`.

Run a drill before relying on this backup design and after significant upgrades. The drill exercises the
restore and checks without performing the final production cut-over; it is not evidence for the generic
quick start, which has no such share or repository.

Next: [upgrades](upgrades.md).
