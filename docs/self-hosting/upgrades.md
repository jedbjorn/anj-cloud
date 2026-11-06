# Upgrades

A server upgrade switches the gateway to a newer commit with a health-checked redeploy: it builds the new release,
restarts the services in order, and switches only when they are healthy; otherwise it falls back.

```bash
git pull                                    # on the VM host: a commit from the branch you follow
python3 deploy/vm/stage.py anj-prod --upgrade   # stages `git archive HEAD` in the VM and runs the upgrade there
```

`stage.py --upgrade` (add `--commit <sha>` for another commit, `--no-backup` to skip the backup) refuses a checkout with local changes and, for production, a commit that is not on `origin/main`. It
runs `anj-cloud-setup upgrade --expect <commit>` in the VM, which:

1. refuses while a backup, a restore or another upgrade is running;
2. does nothing if that release is already live;
3. runs a backup first if the last one is older than 24 hours (`--no-backup` skips it, with a warning);
4. installs the release, switches with `prod.py redeploy`, and restarts the affected services.

If your terminal drops, the upgrade continues in the VM and either finishes or falls back by itself; follow it
with `anj-cloud-setup status` and read `/var/log/anj-cloud-setup/upgrade-<UTC>.{out,err}`. To go back to the
previous release: `sudo anj-cloud-setup upgrade --rollback`.

After a server upgrade, check `python3 deploy/prod.py check`. Clients are upgraded separately; see
[keys and releases](keys-and-releases.md) for publishing a client release that devices pick up by themselves.

The VM itself also installs Debian security updates unattended (no automatic reboot).

Next: [your release keys and publishing](keys-and-releases.md).
