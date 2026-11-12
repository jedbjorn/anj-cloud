# Requirements

These are the requirements for the [generic Debian quick start](quickstart.md). The installer checks most
of them before changing the machine and prints a fix when one fails.

## Machine and disks

| Item | Requirement |
|---|---|
| Deployment | A generic VM, recommended when the host has other uses, or a dedicated machine. Run the installer inside that VM or machine. |
| OS | **Debian 13 (trixie), amd64**. Other releases and architectures are refused. |
| CPU | **2 or more CPUs**. |
| RAM | **4 GiB**. The installer's low-level refusal threshold is 3.5 GiB; 4 GiB is the supported allocation to use. |
| OS disk | **At least 8 GiB free on `/`**. A **20 GiB OS disk** is the practical recommendation, not a claim about actual consumption. |
| Data disk | **Exactly one separate blank whole disk**, unmounted and unused. Size it for household files and server data; setup does not impose a data-disk minimum. |
| User | A sudo-capable user named **`anj`**. Services and the recovery CLI run as this user. |
| Time | Synchronized system time. `sudo timedatectl set-ntp true` enables network time sync. |
| Port | TCP **443** free for AnJ Cloud. Setup also refuses other Docker containers with published ports. |

The OS disk and data disk have different jobs. The OS holds Debian and packages. The data disk is mounted
at `/srv/anj-cloud` and holds household files, accounts, registry, keys, service state, release sources, and
Docker data. It is a single point of failure unless you add a real backup.

### Containers, memory and outbound access

The stack runs eight containers. Their memory limits add up to 3,616 MiB: PostgreSQL 512, Redis 256,
Nextcloud 1,536, its cron 384, the access service 256, HAProxy 128, the media fetch worker 512 and its
network guard 32. On a 4 GiB VM that is more than remains once Debian, Docker and PM2 have their share, so
the limits are ceilings, not reservations: in practice the containers use far less (a 1080p download
measured about 72 MiB of process memory in the worker; most of its limit is reclaimable file cache), but if
several reached their limits at once the kernel would have to stop one. Give the VM more memory if you can;
the installer still accepts 4 GiB.

The media fetch worker (the clients' Downloader tab) needs **outbound HTTPS to the internet**: to the sites
members download from, and to GitHub once a day for yt-dlp's own updates. It has no access to the household
network or the other containers. Downloads are staged on the data disk (in Docker's data root) before they
are saved into Nextcloud. At its peak an item takes **twice its size** on the data disk: while video and
audio are merged (both parts and the merged file), and again while it is saved (the staged file and its
copy in Nextcloud), so an item at the 8 GiB limit needs up to 16 GiB free for a while; once saved it takes
its size once. The gateway refuses new downloads, and stops a running one, while the data disk has under
10% free. The staging volume is not backed up.

For this initial path, attach only the OS disk and the one intended data disk. Extra unused disks make
automatic selection ambiguous. A new virtual disk is the simplest choice for a VM.

### What “blank” means

Setup accepts a disk for formatting only when its safety checks find no partition or filesystem signature,
no partitions, and zero data in the first and last MiB. Mounted disks, probe errors, existing AnJ Cloud data,
and foreign signatures are refused. Setup repeats the check immediately before `mkfs.ext4` and asks for a
separate, default-no confirmation.

Do not interpret those checks as a reason to skip your own review. Identify the OS disk by the `/` mount and
the intended data disk by its device, size, and model. If there is any doubt, stop and attach a new blank
disk. The quick start deliberately does not tell you to wipe an existing disk.

## OS account and Git

Prefer creating `anj` during Debian installation and giving it sudo access. A fresh cloud image may instead
provide only root or another OS account. From an existing sudo-capable session, use this sequence; skip
`adduser` when `id anj` shows that the account already exists:

```bash
id anj
sudo adduser anj
sudo usermod -aG sudo anj
su - anj
sudo -v
```

From a root shell, omit `sudo` from `adduser` and `usermod`. If root does not have sudo installed, first run
`apt-get update && apt-get install -y --no-install-recommends sudo`. The fresh login applies the sudo group;
do not run the server install directly as root.

A fresh Debian 13 cloud image can have `curl` but no `git`. Install Git **before cloning**, as `anj`:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends git
```

The quick start's next commands are `git clone`, `git archive`, and the guided installer. Git is also needed
for the generic upgrade wrapper.

## Network

- A fixed or DHCP-reserved **LAN IPv4 address** for the server. The router forward breaks if this changes.
- A fixed or DHCP-reserved LAN IPv4 address for the **one admin computer allowed to make SSH connections**.
  Setup's firewall refuses SSH from every other source. This is not a router SSH forward.
- Working DNS resolution and **outbound HTTPS (TCP 443)**. Preflight contacts:
  - `deb.debian.org:443`
  - `registry-1.docker.io:443`
  - `registry.npmjs.org:443`
  - `ntfy.sh:443`
  - `api.cloudflare.com:443` when DDNS is enabled
- A router where you can forward **external TCP 443 to the server's internal TCP 443**. In the advanced
  libvirt route, target the VM host instead; its own rules forward to the VM.
- A **public WAN IPv4 address** routed to that router. This direct inbound design does not work through
  CGNAT. No alternate public port is part of the current tooling.

No publicly forwarded SSH, DMZ, port triggering, or additional web port is required. The supported client
address is `https://cloud.example.com` with the standard HTTPS port, not a random high port.

## Domain, accounts, and devices

- A registered domain you control and one full DNS hostname for the gateway, such as
  **`cloud.example.com`**. The domain is `example.com`; `cloud.example.com` is one host in that domain.
- **Cloudflare free DNS** is recommended for the built-in DDNS updater. Registrar service is optional. With
  DDNS, prepare the zone ID, one DNS-only A record, and a token from the **Edit zone DNS** template scoped
  to that one zone. Without DDNS, another DNS provider is acceptable; maintain the A record yourself.
- One or more household account names: 1–32 lowercase letters, digits, or `-`, starting with a letter and
  unique within the list. **The first account becomes the first admin.**
- A phone with the **ntfy** app for the guided alert setup. Setup can generate a private topic or use an
  existing one. Anyone with the topic can read or post alerts, so protect it like a password.
- An [official AnJ Cloud client](../clients.md) for the first device. Official Linux, macOS, Windows and
  Android builds can pair with your server without a client build. The Windows build is early.

You do **not** need Flutter, Subfloor, a deployment profile, desktop update signing keys, or an Android
keystore for this installation. Custom client builds and a household-controlled update feed are separate,
optional work.

## Backup and alert boundaries

The generic quick start does **not** configure the backup share used by the libvirt VM-host deployment.
Consequently, finishing it does not create an encrypted repository, a backup password, a successful backup,
or restore evidence. Timers and monitoring do not change that. Plan a separate backup target and restore
test before storing irreplaceable data.

ntfy alerts are delivery through an external service from the server itself. They are useful for local
health, enrollment, and DDNS conditions when configured and confirmed, but they are not an independent
monitor. A dead server, dead router, lost ISP path, or blocked ntfy connection can prevent delivery.

## Optional preflight review

As `anj`, inside the target machine:

```bash
id -un
sudo -v
timedatectl show -p NTPSynchronized --value
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL
df -h /
```

Expect `anj`, a successful sudo check, `yes` for time synchronization, one clearly identifiable blank data
disk, and at least 8 GiB free on `/`. Then continue to the [quick start](quickstart.md).
