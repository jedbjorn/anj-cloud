# Self-hosting AnJ Cloud

AnJ Cloud uses Nextcloud for household file storage and sharing, and adds device pairing, per-device access
control, and client updates. The guided installer puts those services on one Debian 13 machine with a
separate data disk.

**Start with the [quick start](quickstart.md).** It is the canonical stranger-to-working-server path: prepare
the machine, create DNS and forwarding, run the installer, check health, and pair the first admin device.
It needs neither Subfloor nor client build/signing tools.

> Unattended Debian VM installs, synthetic-device access, and local upgrades have passed lab checks.
> The complete interactive public walkthrough and real-network setup remain unverified. Read the
> quick start's exact validation scope and follow its stop conditions.

## Read alongside the quick start

- [Requirements](requirements.md): hardware, blank-disk rules, users, network destinations, and secrets.
- [DNS, TLS and port forwarding](dns-tls-forwarding.md): domain versus hostname, Cloudflare DNS and DDNS,
  public IPv4/CGNAT, the single TCP 443 forward, household certificates, and hairpin/split DNS.
- [Accounts and pairing](accounts-and-pairing.md): the first admin, one-time codes, more devices, and
  recovery commands.

These references explain the same installation path; they are not alternative installers.

## Deployment routes

The default is a **generic Debian 13 amd64 VM**, recommended when the physical host has other uses, or a
**dedicated Debian 13 amd64 machine**. Run the quick start inside that VM or machine. It talks directly to
the guided installer and needs no VM-host profile or staging tool.

An existing **advanced libvirt VM-host route** is documented in [The VM host and gateway VM](host-and-vm.md).
It uses a separate deployment profile and host staging commands. With that route, the router's TCP 443
forward targets the VM host, which forwards to the VM. Do not mix its host commands into the generic quick
start.

The generic quick start covers installation and first pairing, not a completed backup design. Its
[backup and alert limitations](quickstart.md#6-what-is-configured-and-what-is-not) are explicit: one data
disk is not a backup, and local ntfy alerts are not independent external monitoring.

## Operate the server

- [Upgrades](upgrades.md): the generic `local_upgrade.py` route first, with `stage.py anj-prod` kept for the
  advanced libvirt route. Local upgrades and explicit rollback passed in the lab; automatic failure
  fallback and the live advanced staging route were not exercised.
- [Troubleshooting](troubleshooting.md): generic-first status, health, pairing, DDNS, upgrade, and emergency
  checks, with host-only commands labelled separately.
- [Backups and restore](backups.md): the existing encrypted virtiofs workflow, explicitly scoped to the
  advanced VM-host route. It is not a generic quick-start backup procedure.
