# Backups and restore

Backups are encrypted with [restic](https://restic.net) into a repository on the external drive that the VM host
shares into the VM. A nightly run (03:30) stops Nextcloud briefly (maintenance mode, capped at 30 minutes), then
saves the database dump, the gateway's registry and your files. Redis is not backed up.

## Set up

Inside the VM, as user `anj`, or through the guided install (`sudo anj-cloud-setup backup`):

```bash
python3 deploy/backup.py init --show-escrow    # creates the repository, shows the password once on this terminal
python3 deploy/backup.py seed --cap <minutes>  # the first full backup, at a time you schedule
```

**The repository password is the one secret a full recovery needs besides the drive.** Copy it somewhere off
the machine now. If you lose it, the backups cannot be opened. `python3 deploy/backup.py show-password` shows it
again on a terminal.

The nightly and "stale backup" timers are installed by the guided install. You are alerted if there is no
successful backup for 36 hours.

```bash
python3 deploy/backup.py status        # JSON: last success, next run
python3 deploy/backup.py check         # restic check of the repository
```

## Restore

A restore creates a fresh install from a snapshot; it does not overwrite a running server. The full recovery
runbook (a new OS disk and a new data disk):

1. On the VM host: `sudo deploy/host/halo-vm.sh --recreate-os` (rebuilds the OS disk, keeps the data disk) or
   recreate the VM with new disks. The VM's address stays the same, so the forward needs no change.
2. In the new VM: `sudo anj-cloud-setup --restore-from /mnt/anj-backup`. It asks for the backup password,
   restores, and continues as an adopted install: no new CA, no new secrets, no new accounts.
3. `python3 deploy/prod.py check`. Devices keep working without re-pairing, because the CA and the server
   certificate are the same.
4. After the first nightly run, test the whole path from the VM host.

If only the OS disk is lost and the data disk is fine: `sudo anj-cloud-setup --adopt-data`.

## Test your backups

```bash
python3 deploy/backup.py drill         # on the VM host, unattended: rebuilds a throwaway VM, restores into it, checks, destroys
```

The drill refuses between 03:20 and 05:00 and while another qualification VM exists. Run it once before you rely
on the backups, and again after a major upgrade. Its receipt is written under
`~/.local/share/anj-cloud/qualification/`.

Next: [upgrades](upgrades.md).
