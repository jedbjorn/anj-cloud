"""Network guard for the fetch worker (spec #42 Worker isolation): run by the `fetch-net` service.

`fetch-net` owns the network namespace the worker joins (`network_mode: service:fetch-net`). As
root holding only CAP_NET_ADMIN it loads one nftables table into that namespace, then sleeps;
the worker itself holds no capability and cannot change it. Every packet the namespace sends to a
loopback, private, link-local, carrier-grade NAT, multicast or reserved address is dropped, which
covers Nextcloud, the database, Redis, the gateway, the Docker host and the household network
whatever their addresses. Two exceptions only:

- loopback inside the namespace, where Docker's resolver (127.0.0.11) answers;
- DNS (port 53) to the host's own resolvers when Docker forwards the container's queries to them
  from the container's namespace (Docker 26, Debian 13's docker.io; Docker 28 and later send them
  from the host's namespace instead). Docker names them in the container's resolv.conf
  (`# ExtServers: [...]`, `host(...)` marking those it reaches from the host). Only those
  addresses, only port 53.

`ANJ_FETCH_FIXTURE_HOST` (dev and review stacks only; never in compose.prod.json) also accepts the
one fixture site's address.

    guard.py           apply, then wait for SIGTERM
    guard.py check     exit 0 when the table is loaded (the healthcheck)
"""

import ipaddress
import os
import signal
import socket
import subprocess
import sys

TABLE = "anj_fetch_guard"
PRIVATE4 = ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
            "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
            "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4")
PRIVATE6 = ("::/127", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/23", "2001:db8::/32",
            "2002::/16", "fc00::/7", "fe80::/10", "ff00::/8")


def fixture_addresses(host, resolve=socket.getaddrinfo):
    if not host:
        return []
    return sorted({row[4][0] for row in resolve(host, None, socket.AF_INET)})


def resolvers(text):
    """The resolvers Docker queries from this namespace (not wrapped in host(...))."""
    found = []
    for line in text.splitlines():
        if line.startswith("# ExtServers:"):
            for entry in line.split(":", 1)[1].strip().strip("[]").split():
                if entry.startswith("host("):
                    continue
                try:
                    address = ipaddress.ip_address(entry)
                except ValueError:
                    continue
                if address.version == 4:
                    found.append(str(address))
    return sorted(set(found))


def ruleset(fixture=(), dns=()):
    allow = "".join("\t\tip daddr %s accept\n" % address for address in fixture)
    allow += "".join("\t\tip daddr %s meta l4proto { tcp, udp } th dport 53 accept\n" % address for address in dns)
    return ("table inet %s {}\ndelete table inet %s\n" % (TABLE, TABLE) +
            "table inet %s {\n" % TABLE +
            "\tset private4 { type ipv4_addr; flags interval; elements = { %s } }\n" % ", ".join(PRIVATE4) +
            "\tset private6 { type ipv6_addr; flags interval; elements = { %s } }\n" % ", ".join(PRIVATE6) +
            "\tchain output {\n\t\ttype filter hook output priority filter; policy accept;\n"
            "\t\toifname \"lo\" accept\n" + allow +
            "\t\tip daddr @private4 drop\n"
            "\t\tip6 daddr @private6 drop\n"
            "\t}\n}\n")


def apply(rules):
    subprocess.run(["nft", "-f", "-"], input=rules.encode(), check=True, timeout=30)


def check():
    return subprocess.run(["nft", "list", "table", "inet", TABLE], capture_output=True, timeout=10).returncode == 0


def main(argv):
    if argv[1:] == ["check"]:
        return 0 if check() else 1
    if argv[1:]:
        print("usage: guard.py [check]", file=sys.stderr)
        return 2
    try:
        dns = resolvers(open("/etc/resolv.conf").read())
    except OSError:
        dns = []
    apply(ruleset(fixture_addresses(os.environ.get("ANJ_FETCH_FIXTURE_HOST", "")), dns))
    print("fetch network guard loaded", flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        signal.pause()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
