# DNS, TLS and port forwarding

## DNS

The clients connect to one host name, `gateway.example.com`. It is built into the server certificate, so decide it
before you install; changing it later means starting over on a new data disk.

- **With Cloudflare and DDNS:** create the `A` record yourself once (any address, **DNS only**, not proxied), then
  answer "on" to DDNS during the guided install and give it the zone id and a Cloudflare API token that can edit
  DNS in the zone. A small updater in the VM reads your public address from two independent services, and only
  when both agree on a public IPv4 does it patch that record (content only; it never creates or deletes
  records). It runs every five minutes, and alerts you after three consecutive failures. The token is stored in
  the VM as `secrets/cloudflare-dns-token` (mode 0600) and never leaves it.
- **Without DDNS:** create the `A` record yourself and keep it correct. Answer "off".

## TLS

You do not need a public certificate. Setup creates your **household certificate authority** and a server
certificate for your host name. Each device pins your CA when it pairs (the pairing code carries the CA's
fingerprint), then authenticates to the server with its own client certificate (mutual TLS). Browsers are not
meant to open the server; there is no public web page.

## Port forwarding

Forward **TCP 443** on the router to the VM host's LAN address (`[network] lan_addr` in your profile). The VM
host's firewall rules (host step 5) forward it on to the VM and keep the VM from reaching the rest of your LAN.
Give the VM host a fixed address or a DHCP reservation, otherwise the forward breaks when it changes.

## Check it

From the VM host or another computer on your LAN, and then again from outside (a phone on mobile data):

```bash
# Do both public lookups agree with your router's WAN address?
python3 deploy/golive.py line-check --router-wan <your WAN IPv4>

# The household CA, copied from the VM (inside the VM it is under /srv/anj-cloud/state/operator/):
python3 deploy/golive.py fingerprint issuer.crt

# The gateway answers, with the right certificate, from the LAN and through the public name:
python3 deploy/golive.py health --host gateway.example.com --cacert issuer.crt --expect-ip <your public IPv4> --no-hosts-entry --concurrent 25
python3 deploy/golive.py health --host gateway.example.com --cacert issuer.crt --resolver system --expect-ip 192.168.0.10

# An outside port scan, from a computer that is not on your home network (a phone tether works):
python3 deploy/golive.py scan <your public IPv4> --host gateway.example.com --evidence-dir ./scan-evidence
```

`deploy/README.md` ("Production DNS, DDNS and go-live") explains each row and the hairpin case (reaching your own
public address from inside the LAN). Your router may or may not support hairpin; if it does not, devices at home
use the LAN path.

## Emergency stop

If something looks wrong, stop the exposed services first and investigate second:

```bash
python3 deploy/golive.py stop --reason "what you saw"      # from the VM host: stops haproxy and the gateway
sudo deploy/host/halo-vm.sh --forward off                 # or close the 443 forward on the host
```

Only `python3 deploy/prod.py resume` (in the VM) and `--forward on` bring them back.

Next: [accounts and your first device](accounts-and-pairing.md).
