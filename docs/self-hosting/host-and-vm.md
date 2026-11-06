# The VM host and the gateway VM

## 1. Get the code and write your profile

```bash
git clone https://github.com/jedbjorn/anj-cloud.git
cd anj-cloud
mkdir -p ~/.local/share/anj-cloud
cp deploy/profile.example.toml ~/.local/share/anj-cloud/profile.toml
chmod 600 ~/.local/share/anj-cloud/profile.toml
$EDITOR ~/.local/share/anj-cloud/profile.toml
```

Fill in:

| Section | Keys |
|---|---|
| `[gateway]` | `host` (public DNS name), `origin` (`https://` plus the host; the clients' default server) |
| `[host]` | `name` (the VM host's hostname, which `halo-vm.sh` insists on), `interface` (its LAN interface), `backup_uuid` (filesystem UUID of the backup drive, from `lsblk -f`) |
| `[network]` | `lan_addr` (VM host LAN address), `router`, `household_lan` (for example `192.168.0.0/24`), `bind_address`, `admin_ssh_source` (keep the defaults unless they clash) |
| `[dns]` | `zone_id` (Cloudflare zone id: the 32-hex id on the zone's overview page) |
| `[household]` | `accounts` (first accounts; the first is the first admin) |
| `[repo]` | `github` (`owner/name` of your fork, used by release tooling) |

`[release]` stays empty until [you create your keys](keys-and-releases.md). The lookup order is `$ANJ_PROFILE`, then
`~/.local/share/anj-cloud/profile.toml`, then `deploy/.local/profile.toml`. Back the file up next to your keys.
`halo-vm.sh` also reads it as the user who runs `sudo`.

Install the pinned Python dependencies once: `python3 deploy/checks.py --deps` (it also checks the client build
tools; you can ignore client complaints if you only host).

## 2. Prepare the VM host

`deploy/host/halo-vm.sh` (the name is historical) creates and manages the VM and everything on the host side.
It never changes anything without `--apply`, and it takes a snapshot of what it must not touch.

```bash
sudo deploy/host/halo-vm.sh                 # dry run: reads the host, prints the plan, changes nothing
sudo deploy/host/halo-vm.sh --apply         # apply all steps
sudo deploy/host/halo-vm.sh --verify        # read-only check, any time
```

The steps are: 1 preflight, 2 network (an isolated libvirt network and firewall rules), 3 the domain (the VM
with its OS and data disks), 4 the backup share, 5 the 443 forward to the VM, 6 start and stop with the host,
7 a hosts entry so the host reaches the gateway by name, 8 host checks and alerts. Use `--only <step>` to run
one, `--rollback <step>` to undo one. Details of each are in `deploy/README.md` ("The VM host").

Two switches to know now:

```bash
sudo deploy/host/halo-vm.sh --forward off   # emergency stop of the 443 forward; only you turn it back on
sudo deploy/host/halo-vm.sh --forward on
```

## 3. Install the gateway in the VM

Stage the sources into the VM, then run the guided installer there (it needs a terminal because it asks questions).

```bash
python3 deploy/vm/stage.py anj-prod         # copies `git archive HEAD` into the VM and prints the command to run
```

Run the command it prints; it looks like:

```bash
ssh -t -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup
```

The installer asks only what it cannot work out: the public host name, whether to keep DNS updated (DDNS), your
router's network range, the first accounts, where alerts go, and for the Cloudflare API token if DDNS is on. It
then prepares the data disk, installs Docker and the pinned PM2, builds the images, creates your **household
certificate authority**, the server certificate and the first accounts, starts the stack and verifies each step.
A re-run repairs only what is missing.

Other modes (inside the VM):

```bash
anj-cloud-setup status                      # one-screen health summary
sudo anj-cloud-setup doctor                 # every check, read-only, each with its fix
sudo anj-cloud-setup --dry-run              # plan only
sudo anj-cloud-setup --answers FILE         # unattended; deploy/vm/answers/prod.example.toml shows the keys
```

## 4. Check the stack

```bash
python3 deploy/prod.py check                # inside the VM: read-only verification
python3 deploy/prod.py status               # every app and its health, as JSON
```

Next: [DNS, TLS and port forwarding](dns-tls-forwarding.md).
