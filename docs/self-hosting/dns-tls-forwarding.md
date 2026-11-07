# DNS, TLS and port forwarding

This page explains the networking used by the [quick start](quickstart.md). Examples use
`example.com` for a domain, `cloud.example.com` for one server hostname, and angle-bracket placeholders for
your addresses. Replace every placeholder; do not copy example addresses into a router.

## Domain versus hostname

A **domain** such as `example.com` is the registered name and its DNS zone. A **hostname** identifies one
service in that zone. `cloud.example.com` combines the host label `cloud` with `example.com`; it is the full
name devices enter as `https://cloud.example.com`.

The public hostname does not have to equal Debian's local machine hostname. It does need to stay fixed:
setup writes it into the server certificate, and setup refuses to change it on an existing data disk later.

Only one gateway A record is needed for this quick start. Other hosts in the same domain are independent.
If you move an existing domain's authoritative DNS, preserve its unrelated website, mail, and verification
records.

## Cloudflare DNS for the built-in DDNS updater

Cloudflare's free DNS plan is sufficient for the built-in updater. You may register the domain elsewhere;
Cloudflare Registrar is optional.

1. [Onboard the domain](https://developers.cloudflare.com/fundamentals/setup/manage-domains/add-site/) and
   choose the Free plan.
2. Follow Cloudflare's [full DNS setup](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/):
   at the registrar, replace the authoritative nameservers with the two assigned to this zone. Review the
   scanned records before making the change. Continue when Cloudflare marks the zone **Active**; this guide
   does not assume a propagation time.
3. In **DNS → Records**, create exactly one record:

   | Field | Value |
   |---|---|
   | Type | `A` |
   | Name | `cloud` (shown as `cloud.example.com`) |
   | IPv4 address | `<CURRENT_PUBLIC_WAN_IPV4>` |
   | Proxy status | **DNS only** (grey cloud) |
   | TTL | `Auto` is sufficient |

   The target is the router's public WAN IPv4, not the server's private LAN address. **DNS only** is
   required: orange-cloud proxying puts Cloudflare's HTTP proxy between the client and the household TLS
   endpoint. Cloudflare explains the distinction in [Proxy status](https://developers.cloudflare.com/dns/proxy-status/).
4. Copy the **Zone ID** from the domain's Overview/API area. It is 32 hexadecimal characters. See
   [Find account and zone IDs](https://developers.cloudflare.com/fundamentals/setup/find-account-and-zone-ids/).
5. Create a user API token from **My Profile → API Tokens → Create Token → Edit zone DNS**. Limit **Zone
   Resources** to the specific `example.com` zone, then create and copy the token. Cloudflare's official
   walkthrough is [Create API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/).
   Do not use the account-wide Global API Key.

The guided installer asks for the token at a hidden prompt, twice, and performs a read-only lookup of the
zone and exact A record before installation. It stores the token as
`/srv/anj-cloud/state/secrets/cloudflare-dns-token`, mode 0600, owned by `anj`. Keep it out of issues, shell
history, documentation, and logs. If it is exposed, revoke it in Cloudflare; the household CA and paired
devices do not depend on it.

A lookup can succeed while printing a `PROXIED` warning. That is not a valid configuration: turn the orange
cloud off and confirm **DNS only** before continuing.

### What DDNS does, and does not do

With DDNS on, the updater runs every five minutes. It:

- obtains the public IPv4 from two independent HTTPS endpoints and proceeds only when both agree on one
  public address;
- requires exactly one existing A record for the configured hostname in the configured zone;
- patches that record's content when the address changes and keeps `proxied=false`; and
- updates the gateway's household-address rule to match.

It **never creates or deletes the DNS record**. Create the A record before setup. DDNS also cannot make a
CGNAT connection reachable, configure a router, or prove that the ISP allows inbound TCP 443. It alerts
after repeated update failures; delivery still depends on the alert path described in the quick start.

## Without DDNS

Another DNS provider is acceptable. Create the same single A record for `cloud.example.com`, pointing to
the current public WAN IPv4, with no HTTP proxy, and answer **no** when setup asks to enable DDNS. You do
not need a Cloudflare zone ID or token in this mode.

You must update that record whenever the public address changes. Devices will use the old address until
DNS is corrected and cached answers expire.

## Public IPv4 and CGNAT

Port forwarding needs an IPv4 path from the internet to your router. A router can have an upstream address
yet still be behind carrier-grade NAT (CGNAT) or another layer of NAT. Private ranges and the shared
`100.64.0.0/10` range are not publicly routable. A mismatch between the router's WAN address and the public
address observed by outside services is a stop condition for this direct path, not something DDNS can fix.

After cloning the public repository, this read-only command compares two independent public-address
services with the WAN address you read from the router:

```bash
python3 deploy/golive.py line-check --router-wan <CURRENT_PUBLIC_WAN_IPV4>
```

A passing result prints JSON containing `"pass": true`, `"router_matches": true`, and a `pending` note that
the operator must still confirm inbound TCP 443 with the ISP. This is an address check, not a connection
test. If it fails or the router is behind CGNAT, ask the ISP for a publicly routed IPv4 address or use an
internet connection that provides one.

### Cloudflare Tunnel is not the current CGNAT answer

[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) uses an
outbound connector and can avoid inbound router forwarding, but **ordinary Cloudflare Tunnel is not
currently supported by AnJ Cloud**. Do not follow generic Tunnel instructions as a substitute for this
quick start.

A future CGNAT tunnel option needs a separately qualified design and client/server validation. Current
clients pin the household CA and authenticate directly with per-device mutual TLS; a generic Cloudflare
proxy or tunnel configuration is not equivalent to that direct path. The same constraint rules out turning
on the A record's orange-cloud proxy.

## Forward exactly one TCP port

For the generic VM or dedicated machine, create this router rule:

| Setting | Value |
|---|---|
| External/public protocol and port | **TCP 443** |
| Internal destination | `<SERVER_LAN_IPV4>` |
| Internal/private protocol and port | **TCP 443** |

For the advanced libvirt VM-host route, the internal destination is the VM host's fixed LAN address instead;
the VM host's own rules then forward TCP 443 to the VM.

Using the standard HTTPS port means the client URL needs no explicit port. Current setup and client
networking assume 443, so this documentation does not offer alternate external or internal ports.

Do **not** configure:

- a DMZ or exposed-host setting;
- port triggering;
- a public forward to SSH (TCP 22) or any other server port;
- a random high port presented as a security control; or
- Cloudflare orange-cloud proxying.

The installer's own firewall accepts TCP 443 on the configured server address and TCP 22 only from the one
admin LAN address selected during setup. The router forward is only for TCP 443.

```text
AnJ Cloud app
    |  HTTPS cloud.example.com, TCP 443
    v
Router at <CURRENT_PUBLIC_WAN_IPV4>
    |  forward external TCP 443 -> internal TCP 443
    v
Debian VM or machine at <SERVER_LAN_IPV4>:443
    |  HAProxy -> AnJ Cloud gateway -> Nextcloud
    +-> separate ANJ_DATA disk
```

## Household TLS instead of a public web certificate

Setup creates a **household certificate authority (CA)** and a server certificate for the public hostname.
You do not need Let's Encrypt or another public certificate for this client protocol.

Pairing carries the first 16 bytes of the CA's SHA-256 fingerprint inside the one-time code. The app
fetches the CA without trusting it blindly, checks it against the code, generates its own device key, and
receives a per-device client certificate. Later connections use mutual TLS: the device verifies the server
and the server verifies the device.

Do not disable hostname or certificate verification. Do not install an unrelated CA to bypass a mismatch.
An ordinary browser is not the expected client and there is no supported public browser login page.

## Hairpin NAT and split DNS

Public DNS returns the public WAN IPv4. When a device inside the household uses that same name, the router
must support **hairpin NAT** (also called NAT loopback) to send the connection back through its own public
address.

If the router does not hairpin, use **split DNS**: household DNS resolves `cloud.example.com` to the
server's fixed LAN IPv4, while public DNS continues to resolve it to the public WAN IPv4. The hostname,
HTTPS URL, certificate, and TCP port stay the same in both places. Split DNS can be provided by the router
or another household DNS resolver; it does not replace the public A record or DDNS.

If the name works away from home but not on the LAN, check hairpin or split DNS before changing the server.
If it works on the LAN but not away, check public DNS, the WAN address, and the TCP 443 forward.

## Check the public path

The simplest complete check is to pair a device on mobile data or a laptop on a hotspot. It exercises DNS,
the router forward, household CA pinning, and per-device enrollment. The quick start uses that as the
end-to-end success check.

For a separate JSON health check, use a management computer with Python 3, `dig`, the public checkout, and
SSH access from the admin source configured during installation. Copy the **public** issuer certificate
(no private key) from the server:

```bash
scp anj@<SERVER_LAN_IPV4>:/srv/anj-cloud/state/operator/issuer.crt ./issuer.crt
python3 deploy/golive.py fingerprint ./issuer.crt
python3 deploy/golive.py health \
  --host cloud.example.com \
  --cacert ./issuer.crt \
  --expect-ip <CURRENT_PUBLIC_WAN_IPV4> \
  --no-hosts-entry
```

Run the last command from outside the LAN to test the public path without depending on hairpin. It uses
public resolvers, verifies the server certificate against the household CA, and requests `/health`. Success
prints JSON containing `"ready": true` and `"pass": true`. A wrong A record, unexpected address, TLS
mismatch, or non-ready response fails the check.

For split DNS, check that the same name resolves to `<SERVER_LAN_IPV4>` on the LAN and pair a real client
there. Keep the outside-LAN check above as the authoritative public-path test.

`golive.py health` needs `dig`; if it is unavailable, use the real-client pairing check rather than treating
a missing diagnostic tool as a server failure.

## Stop conditions and emergency stop

Stop rather than bypassing a check when:

- the WAN path is CGNAT or the public address does not match the router;
- Cloudflare cannot find exactly one DNS-only A record, or its read-only token/zone check fails;
- the resolved address is not the address you configured;
- you see an unexpected open port, certificate, hostname, or pairing device; or
- the server health check or pairing fails.

Remove or disable the router's TCP 443 forward while investigating. To stop the exposed HAProxy and gateway
services persistently across reboots, run this **inside the server as `anj`, without sudo**:

```bash
python3 /srv/anj-cloud/release/current/deploy/prod.py emergency-stop --reason "what you observed"
```

The command writes an emergency-stop marker, stops `haproxy` and `gateway`, saves that stopped state, and
queues an alert. Only an intentional resume re-enables them:

```bash
python3 /srv/anj-cloud/release/current/deploy/prod.py resume
```

Return to the [quick start](quickstart.md) or continue with [accounts and pairing](accounts-and-pairing.md).
