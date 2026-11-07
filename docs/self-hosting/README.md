# Self-hosting AnJ Cloud

AnJ Cloud is built on Nextcloud: Nextcloud stores the household's files and provides sharing, while the AnJ Cloud
gateway adds device pairing, per-device access control and client updates. This guide takes you from an empty Linux
machine to a working household server and a first paired device. Read it in order the first time; each page ends
with what to do next.

1. [Requirements](requirements.md): what you need before you start.
2. [The VM host and the gateway VM](host-and-vm.md): your deployment profile, the host side, the VM, the guided install.
3. [DNS, TLS and port forwarding](dns-tls-forwarding.md): making the server reachable, and checking it.
4. [Accounts and your first device](accounts-and-pairing.md)
5. [Backups and restore](backups.md)
6. [Upgrades](upgrades.md)
7. [Your release keys, and publishing client releases](keys-and-releases.md)
8. [Troubleshooting](troubleshooting.md)

Everything specific to your household (domain, addresses, account names, release key) lives in one file, your
**deployment profile**, never in the code. The reference documentation for every command is
[`deploy/README.md`](../../deploy/README.md) and [`services/access/README.md`](../../services/access/README.md);
these pages are the guided path through it.

Placeholders used throughout: `gateway.example.com` (your public host name), `192.168.0.10` (the VM host's address
on your LAN), `sam` and `alex` (household accounts).

## How the pieces fit

```text
internet -> your router :443 -> VM host (192.168.0.10) -> gateway VM (HAProxy -> access service -> Nextcloud)
                                    |                         |
                                    |                         +-- data disk (files, registry, secrets)
                                    +-- backup drive (encrypted restic repository, shared into the VM)
```

The VM host is any Linux machine with KVM. It runs one VM, forwards port 443 to it, and holds the backup drive.
Everything else, including Docker and the services, is inside the VM, so the host stays clean and the VM can be
rebuilt from its data disk or from a backup.
