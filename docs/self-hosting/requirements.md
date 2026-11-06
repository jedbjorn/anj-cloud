# Requirements

## The VM host

- A Linux machine that stays on, with **KVM** (hardware virtualization enabled in firmware) and **libvirt**.
  The host tooling targets Arch-family systems (it checks `pacman`, `ufw`, `nft`, `virsh`, `systemd`, `sshd`
  and `runuser`); other distributions need the same tools and may need adjustments. `sudo deploy/host/halo-vm.sh`
  (a dry run) tells you exactly what is missing and changes nothing.
- A LAN interface with a fixed (or DHCP-reserved) address.
- About 4 GiB of RAM free for the VM, a disk with room for the VM's OS disk and a larger data disk for your files,
  and an **external drive** for backups (it is mounted on the host and shared into the VM; the tools never format it).
- The host user needs access to libvirt; every host-changing step runs with `sudo` and is yours to run.

## A domain and DNS

- A domain name you control and a host name for the server, for example `gateway.example.com`.
- DNS hosted at **Cloudflare** if you want the built-in dynamic-DNS updater: it needs the zone id and an API
  token that can edit DNS in that zone. If your home address never changes, any DNS provider works: create the
  record yourself and answer "no" to DDNS during setup.

## The network

- A router where you can **forward TCP port 443** to the VM host, and a public IPv4 address (a CGNAT connection
  cannot accept inbound connections; ask your provider for a public address or use another route).
- Optional: an [ntfy](https://ntfy.sh) topic. Alerts (backup failed, address change failing, emergency stop) go
  there.

## Your workstation

- Python 3.11 or newer for the tools (3.14 is what the project tests).
- To build the clients yourself: see [../clients.md](../clients.md) and [../development.md](../development.md).
- Optional but recommended: a password manager or offline media for three secrets: the backup password, the
  release signing key and the Android keystore.

Next: [the VM host and the gateway VM](host-and-vm.md).
