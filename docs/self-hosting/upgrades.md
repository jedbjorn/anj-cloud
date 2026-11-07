# Upgrades

A server upgrade installs the source from an exact reviewed commit, builds and checks that release, restarts
the affected services, and switches `release/current` only after the new stack is healthy. The previous
release's source remains available for a release rollback.

> **Validation status:** the generic `local_upgrade.py` route has been source-reviewed, but a live generic
> upgrade has not passed yet. Keep the pre-upgrade checks and stop conditions in this page; do not infer a
> successful upgrade from a wrapper that is still running or has failed its checks.

## Generic VM or dedicated machine

Use this route on the same generic Debian machine where you ran the [quick start](quickstart.md). It uses
the clean public clone as `anj`; it does not use SSH staging, the VM-host `stage.py` route, or a deployment
profile. `local_upgrade.py` reuses `stage.py`'s local validation helpers, but archives the source and invokes
the installed setup command locally.

### 1. Fast-forward the clean public clone

Change to the clone root. If you cloned as `anj` with the quick start, that is `~/anj-cloud`:

```bash
cd ~/anj-cloud
git status --short
git pull --ff-only origin main
git status --short
```

Both `git status --short` outputs must be empty. The pull must fast-forward `main` to `origin/main`; stop if
it refuses or reports divergence. Do not reset, clean, merge, or discard local work to make the wrapper
accept the checkout. Preserve or move that work deliberately and use a clean reviewed clone instead.

The explicit pull is required even though the wrapper also fetches: **`local_upgrade.py` runs
`git fetch origin main` but never pulls.** Without your pull, it can select an older merged `HEAD` rather
than the current reviewed release.

### 2. Run the local wrapper

From that same clone root:

```bash
python3 deploy/vm/local_upgrade.py
```

The wrapper:

1. resolves the checkout's exact `HEAD` commit;
2. fetches `origin main` without changing the working tree;
3. refuses uncommitted or untracked files, a `HEAD` not merged into the fetched `origin/main`, or a tree
   without the required reviewed history/fixes;
4. archives that exact commit with `git archive`; and
5. calls `sudo anj-cloud-setup upgrade --source <temporary-tar> --expect <full-commit>`.

It must be run from the checkout root, not from `/srv/anj-cloud/release/current`. The installed release is
the payload being replaced, not the reviewed Git checkout used to select the next release.

If you intentionally need to skip the pre-upgrade backup, use:

```bash
python3 deploy/vm/local_upgrade.py --no-backup
```

`--no-backup` skips a fresh backup **when backups are configured**, with a warning. If backups are not set
up, setup already warns and continues without one either way; the flag does not create or configure a
backup. The generic quick start has no backup target, so an upgrade on that path has no pre-upgrade restore
point. See [Backups and restore](backups.md).

### 3. What setup does

The installed setup command:

- refuses to start while another upgrade, backup, or restore is active;
- reports a no-op when the selected release is already live;
- runs a backup first when backups are configured and the last successful backup is not recent;
- installs the exact archived release and runs the health-checked `prod.py redeploy` path; and
- keeps the previous release source, switching the live symlink only after health checks pass. A failure
  before a healthy switch leaves the previous release live or attempts the same health-checked fallback.

If your terminal disconnects, the detached switch continues in the VM and either finishes or falls back.
Check `anj-cloud-setup status` and read `/var/log/anj-cloud-setup/upgrade-<UTC>.out` and
`/var/log/anj-cloud-setup/upgrade-<UTC>.err`. Do not start a second upgrade while one is active.

> **Data migrations are not reversible by a release rollback.** A newer Nextcloud image or gateway registry
> migration can make data incompatible with the previous release. Neither automatic fallback nor
> `upgrade --rollback` can undo that data change. Review the target release for such migrations and make a
> fresh, restorable backup before upgrading. On the generic quick-start path, that backup does not exist yet.

### 4. Verify the result

As `anj` inside the generic machine:

```bash
anj-cloud-setup status
sudo anj-cloud-setup doctor
cd /srv/anj-cloud/release/current
python3 deploy/prod.py check
python3 deploy/prod.py status
```

Expect the new release in status, `Healthcheck     ready`, and `doctor: all checks pass`. The `prod.py`
commands must run from `/srv/anj-cloud/release/current` as shown. `status` is JSON containing each app and
the health check; investigate any non-ready result before pairing more devices or attempting another update.

To switch back to the recorded previous release:

```bash
sudo anj-cloud-setup upgrade --rollback
cd /srv/anj-cloud/release/current
python3 deploy/prod.py check
```

Rollback uses the same health-checked release-switch path and pre-upgrade backup behavior. It does not undo
Nextcloud or registry data migrations and is not a substitute for restoring a backup.

## Advanced libvirt VM-host route: `stage.py anj-prod`

For the separately configured `anj-prod` VM, run the staging wrapper **on the VM host**, from its clean
reviewed checkout:

```bash
git status --short
git pull --ff-only origin main
python3 deploy/vm/stage.py anj-prod --upgrade
```

Use `--commit <full-sha>` to select another reviewed commit, or append `--no-backup` with the same meaning as
above. Production requires the selected commit to be merged into the fetched `origin/main`. The staging
route refuses dirty/untracked checkouts and unsupported history, archives the selected commit into the VM,
and invokes the staged `anj-cloud-setup upgrade --expect <commit>` over SSH.

After either route, verify inside `anj-prod` with the same `cd /srv/anj-cloud/release/current` followed by
`python3 deploy/prod.py check` and `python3 deploy/prod.py status` shown above.

## Client updates and OS updates

Server releases and client releases are separate. For publishing signed client updates, see
[keys and releases](keys-and-releases.md). The guided server install configures Debian security updates;
that OS mechanism is separate from `local_upgrade.py`.
