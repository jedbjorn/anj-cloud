# Troubleshooting

Start with the read-only checks; they print what is wrong and the fix.

```bash
sudo deploy/host/halo-vm.sh --verify          # on the VM host: the host side
sudo anj-cloud-setup doctor                    # in the VM: preflight plus every verification, each with its fix
anj-cloud-setup status                         # in the VM: one-screen summary
python3 deploy/prod.py check                   # in the VM: PM2, limits, ports, health, TLS
python3 deploy/prod.py status                  # in the VM: every app, restarts, health (JSON)
```

| Symptom | Look at |
|---|---|
| `halo-vm.sh` says "no deployment profile found" or "runs only on <name>" | The profile is missing or `[host] name` is not this machine's hostname. Check `~/.local/share/anj-cloud/profile.toml` (mode 0600, readable by the user who runs `sudo`). Only `--dry-run` and `--verify` run without one. |
| `halo-vm.sh` preflight lists missing tools | Install what it names (it never installs packages). |
| The guided install stops with a preflight error | Fix what it prints and run it again; a re-run repairs only what is missing. The clock must be synchronized in the VM. |
| A device says "This code is not for this server" | The code was made by another server, or the server field is wrong. Check the field matches your `https://gateway.example.com` exactly. |
| A code is refused or expired | Codes are single use and last ten minutes. Make a new one (Admin, or `sudo anj-cloud-setup pair --new-code`). |
| Devices cannot connect from outside | `python3 deploy/golive.py line-check --router-wan <WAN IPv4>` (is the DNS record right?), then the router forward (TCP 443 to the VM host), then `deploy/host/halo-vm.sh --verify` (is the forward on? `--forward on`). A CGNAT connection cannot accept inbound connections. |
| Works at home, not outside (or the reverse) | The hairpin case: your router may not loop back to its own public address. `golive.py health ... --resolver system` shows the LAN path. |
| The DNS record is stale | The DDNS updater alerts after three failures. In the VM: `python3 -I deploy/ddns.py run` runs one cycle and prints why it did or did not change anything. |
| No alerts arrive | Check the ntfy topic you gave setup, and that the VM host can reach it. |
| Backup alert | `python3 deploy/backup.py status` (in the VM) shows the last result; make sure the drive is mounted on the host (`halo-vm.sh --verify`). |
| An upgrade seems stuck | `anj-cloud-setup status` ("Update running now"); logs in `/var/log/anj-cloud-setup/upgrade-<UTC>.{out,err}`; it falls back by itself after an hour. |
| The last admin is gone | `anj-cloud-admin invite --user <account>` in the VM, then pair a device with the code. |
| Something looks wrong and you want it off | `python3 deploy/golive.py stop --reason "..."` (VM host), or `sudo deploy/host/halo-vm.sh --forward off`. |

Still stuck? Open an issue (never paste pairing codes, keys, tokens or your real host name), or for a security
problem follow [SECURITY.md](../../SECURITY.md).
