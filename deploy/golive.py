#!/usr/bin/env python3
"""Go-live tooling for remote access (spec #23 rev7). Standard library only; never needs root.
Runs on the VM host or a second computer on the LAN; production lives in the anj-prod VM (decisions #84, #85).

    golive.py line-check [--router-wan <ipv4>]
        Both DDNS endpoints agree on one public IPv4 (and it equals the router's WAN address).
    golive.py fingerprint <issuer.crt>
        SHA-256 certificate fingerprint, compared on both ends before entering an invitation.
    golive.py health --host <host> --cacert <issuer.crt> [--resolver public|system]
                     [--expect-ip <ipv4>] [--no-hosts-entry] [--concurrent N [--expect some-refused]]
        Hairpin (a second computer at home: public DNS, no hosts entry), the VM host path (system resolver: the hosts
        line to 192.168.0.10, which the VM host's output DNAT sends to the VM; an address inside the VM
        network bypasses the DNAT and fails) or outside checks: /health ready with hostname
        verification against the issuer.
    golive.py source-check --source <ip> [--published <ipv4>] [--lan 192.168.0.0/24]
        Hairpin source HAProxy logged in the VM: the household LAN or the published IPv4 passes;
        an address in the VM network (10.77.10.1: the VM host applied source NAT) or anything else fails.
    golive.py scan <home ipv4> --host <host> --evidence-dir <dir>
        Full TCP scan (decision #69 (k)): `nmap -Pn -p- -T4 --max-retries 3 --host-timeout 60m`,
        then a confirming pass on every port other than 443 reported open. Pass: 443 open and
        every other port closed or filtered; a timed-out or partial first pass never passes.
        Also requires an empty AAAA answer for the host.
    golive.py stop --reason "<what was seen>" [--ssh-host anj-prod] [--ssh-config <file>]
        Non-root emergency stop (decision #68 item 9): `ssh -F <halo-vm.sh ssh_config> anj-prod
        python3 -I /srv/anj-cloud/release/current/deploy/prod.py emergency-stop --reason …` (the
        ssh_config is ~/.local/share/anj-cloud/prod-vm/ssh_config, where halo-vm.sh defines the
        anj-prod alias; plain ssh, reported in the JSON, only when that file is missing; writes the flag,
        stops PM2 apps haproxy and gateway, pm2 save, one ntfy message), then verified through
        `prod.py status`: both apps "stopped" and emergency_stop true. There is deliberately no resume or start
        command: only the operator re-enables (`prod.py resume`). Root stop (operator, sudo):
        `deploy/host/halo-vm.sh --forward off`.

Every command prints one JSON result and exits 0 only when its check passed.
"""

import argparse
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import ipaddress
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from deploy import ddns, deployment_profile  # noqa: E402
from deploy.vm import paths  # noqa: E402

# The VM host's VM network: the VM's bind address /24. A hairpin source inside it means the VM host applied
# source NAT (its gateway, 10.77.10.1); a host-path address inside it bypasses the output DNAT.
VM_NETWORK = ipaddress.ip_network(paths.DEFAULT_BIND_ADDRESS + "/24", strict=False)
HALO_LAN_ADDRESS = deployment_profile.load()["network"]["lan_addr"]   # The VM host's LAN address (profile)
SSH_HOST = "anj-prod"
# halo-vm.sh (spec #21) defines its ssh aliases (anj-prod, anj-qual) only in its own ssh_config
# under the invoking user's home; plain `ssh anj-prod` does not resolve on the VM host (SC-065).
HALO_SSH_CONFIG_RELATIVE = Path(".local", "share", "anj-cloud", "prod-vm", "ssh_config")
SSH_CONNECT_TIMEOUT = 15
# The live release's prod.py, addressed through the stable release/current symlink. It is 0644
# inside the extracted release, so it always runs through the interpreter.
PROD = ("python3", "-I", str(paths.RELEASE_CURRENT / paths.PROD_COMMAND))
ROOT_STOP = "sudo deploy/host/halo-vm.sh --forward off"
# B1's the VM host dispatcher is root-only; a narrow sudoers rule lets the operator's user run exactly this path,
# so it is invoked through `sudo -n` (never prompts).
HALO_DISPATCHER = "/usr/local/lib/anj-cloud-host/anj-alert"
PUBLIC_RESOLVERS = ("1.1.1.1", "8.8.8.8")
CONNECT_TIMEOUT = 30
REQUEST_TIMEOUT = 120
ALL_PORTS = 65535


class CheckFailed(Exception):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Line check -------------------------------------------------------------------------------

def line_check(router_wan=None, http=None, endpoints=ddns.ENDPOINTS):
    address = ddns.discover(http or ddns.Http(), endpoints)  # raises unless both agree and public
    result = {"check": "line", "endpoints_agree": True, "public_ipv4": address, "cgnat_or_rfc1918": False}
    if router_wan is not None:
        result["router_wan"] = router_wan
        result["router_matches"] = router_wan == address
        if not result["router_matches"]:
            raise CheckFailed(json.dumps(result))
    result["pass"] = True
    result["pending"] = "operator confirms the ISP allows inbound 443"
    return result


# Trust anchor -----------------------------------------------------------------------------

def fingerprint(path):
    text = Path(path).read_text()
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", text, re.S)
    if len(blocks) != 1:
        raise CheckFailed("expected exactly one PEM certificate")
    der = ssl.PEM_cert_to_DER_cert(blocks[0])
    digest = hashlib.sha256(der).hexdigest().upper()
    return {"check": "fingerprint", "sha256": ":".join(digest[i:i + 2] for i in range(0, 64, 2)), "pass": True}


# Name resolution and health ---------------------------------------------------------------

DIG_STATUS = re.compile(r"^;; ->>HEADER<<- opcode: QUERY, status: ([A-Z]+),", re.M)


def dig(host, record, resolver, runner=subprocess.run):
    """Answers of `record` type. An empty list only for a NOERROR reply with no such record;
    a timeout, SERVFAIL, NXDOMAIN or other failure raises (never read as "empty")."""
    try:
        result = runner(["dig", "+noall", "+comments", "+answer", "+time=10", "+tries=2", record, host, "@" + resolver],
                        capture_output=True, text=True, timeout=60, check=False)
    except subprocess.SubprocessError:
        raise CheckFailed(f"dig {record} @{resolver} timed out") from None
    status = DIG_STATUS.search(result.stdout or "")
    if result.returncode != 0 or status is None:
        raise CheckFailed(f"dig {record} @{resolver} got no reply")
    if status.group(1) != "NOERROR":
        raise CheckFailed(f"dig {record} @{resolver} answered {status.group(1)}")
    answers = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if line.startswith(";") or len(fields) < 5 or fields[3] != record:
            continue
        answers.append(fields[4])
    return sorted(answers)


def hosts_entry(host, hosts=Path("/etc/hosts")):
    for line in hosts.read_text().splitlines():
        fields = line.split("#", 1)[0].split()
        if host in fields[1:]:
            return True
    return False


def tls_context(cacert):
    context = ssl.create_default_context(cafile=str(cacert))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def open_tls(address, host, context, port=443, timeout=CONNECT_TIMEOUT):
    raw = socket.create_connection((address, port), timeout=timeout)
    try:
        return context.wrap_socket(raw, server_hostname=host)
    except BaseException:
        raw.close()
        raise


def get_health(address, host, context, port=443):
    """GET /health over TLS to `address`, verifying the certificate for `host`. One retry."""
    last = None
    for _ in range(2):
        try:
            with open_tls(address, host, context, port) as connection:
                connection.settimeout(REQUEST_TIMEOUT)
                version = connection.version()
                connection.sendall(f"GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                data = b""
                while len(data) < 65536:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                head, _, body = data.partition(b"\r\n\r\n")
                status = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/1.") else 0
                return {"status": status, "tls": version, "body": body.decode("utf-8", "replace")[:200],
                        "server_header": any(line.lower().startswith(b"server:") for line in head.split(b"\r\n"))}
        except (OSError, ssl.SSLError, ValueError, IndexError) as error:
            last = error
    raise CheckFailed(f"/health unreachable on {address}: {type(last).__name__}: {last}")


def concurrent_connections(address, host, context, count, port=443):
    """Open `count` TLS connections at once and hold them; count those refused or failed."""
    held, refused = [], 0

    def attempt(_):
        try:
            connection = open_tls(address, host, context, port)
            connection.settimeout(2)
            try:  # A connection the limiter rejects after accept closes at once.
                if connection.recv(1) == b"":
                    connection.close()
                    return None
            except (TimeoutError, socket.timeout, ssl.SSLWantReadError):
                pass
            return connection
        except (OSError, ssl.SSLError):
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
        for connection in pool.map(attempt, range(count)):
            if connection is None:
                refused += 1
            else:
                held.append(connection)
    for connection in held:
        connection.close()
    return {"opened": count, "accepted": len(held), "refused": refused}


def health(host, cacert, *, resolver="public", expect_ip=None, no_hosts_entry=False, concurrent=0,
           expect="all-accepted", runner=subprocess.run, hosts=Path("/etc/hosts"), port=443):
    result = {"check": "health", "host": host, "resolver": resolver}
    if no_hosts_entry:
        result["hosts_entry"] = hosts_entry(host, hosts)
        if result["hosts_entry"]:
            raise CheckFailed(json.dumps(dict(result, reason="a hosts entry for the host exists on this device")))
    if not expect_ip:
        raise CheckFailed("--expect-ip is required: the home IPv4 with the public resolver (hairpin and outside "
                          f"rows), {HALO_LAN_ADDRESS} with the system resolver (The VM host path via the output DNAT)")
    if resolver == "public":
        answers = {server: dig(host, "A", server, runner) for server in PUBLIC_RESOLVERS}
        result["public_dns"] = answers
        values = {tuple(value) for value in answers.values()}
        if len(values) != 1 or len(next(iter(values))) != 1:
            raise CheckFailed(json.dumps(dict(result, reason="public resolvers disagree or return no single A record")))
        address = next(iter(values))[0]
    else:
        address = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        if ipaddress.ip_address(address) in VM_NETWORK:
            raise CheckFailed(json.dumps(dict(result, address=address,
                                              reason="resolves into the VM network, bypassing the VM host's output DNAT")))
        result["path"] = f"hosts line -> {address} -> the VM host output DNAT -> anj-prod"
    result["address"] = address
    if expect_ip and address != expect_ip:
        raise CheckFailed(json.dumps(dict(result, reason=f"resolved {address}, expected {expect_ip}")))
    context = tls_context(cacert)
    response = get_health(address, host, context, port)
    result["health"] = response
    ready = response["status"] == 200 and json.loads(response["body"] or "{}") == {"status": "ready"}
    result["ready"] = ready
    if concurrent:
        result["concurrent"] = concurrent_connections(address, host, context, concurrent, port)
        refused = result["concurrent"]["refused"]
        result["concurrent_pass"] = refused == 0 if expect == "all-accepted" else refused > 0
    result["pass"] = ready and result.get("concurrent_pass", True)
    if not result["pass"]:
        raise CheckFailed(json.dumps(result))
    return result


# Full TCP scan ----------------------------------------------------------------------------

def parse_nmap(path):
    """Ports by state, plus whether the scan covered its whole range and finished. A missing or
    truncated file reads as an unfinished scan."""
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError):
        return {"finished": False, "timed_out": False, "ports": {}, "extra": {}, "covered": 0}
    finished = root.find("runstats/finished")
    hosts = root.findall("host")
    report = {"finished": finished is not None and finished.get("exit") == "success", "timed_out": False,
              "ports": {}, "extra": {}, "covered": 0}
    if len(hosts) != 1:
        report["finished"] = False
        return report
    host = hosts[0]
    report["timed_out"] = host.get("timedout") == "true"
    ports = host.find("ports")
    if ports is None:
        return report
    for port in ports.findall("port"):
        if port.get("protocol") == "tcp":
            report["ports"][int(port.get("portid"))] = port.find("state").get("state")
    for extra in ports.findall("extraports"):
        report["extra"][extra.get("state")] = report["extra"].get(extra.get("state"), 0) + int(extra.get("count"))
    report["covered"] = len(report["ports"]) + sum(report["extra"].values())
    return report


def run_quietly(runner, argv, timeout):
    """Run nmap; a timeout leaves an unfinished (or missing) XML, which never passes."""
    try:
        runner(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        pass


def scan(address, host, evidence, *, runner=subprocess.run, nmap="nmap"):
    if ddns.public_ipv4(address) is None:
        raise CheckFailed("scan target must be the home's public IPv4")
    evidence = Path(evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    first_xml = evidence / f"scan-{stamp}-pass1.xml"
    first_cmd = [nmap, "-Pn", "-p-", "-T4", "--max-retries", "3", "--host-timeout", "60m", "-oX", str(first_xml), address]
    started = time.monotonic()
    run_quietly(runner, first_cmd, 4 * 3600)
    first = parse_nmap(first_xml)
    result = {"check": "scan", "target": address, "started": now(), "pass1": {
        "command": " ".join(first_cmd[:-3] + ["-oX", first_xml.name, "<home ipv4>"]), "seconds": round(time.monotonic() - started),
        "finished": first["finished"], "timed_out": first["timed_out"], "covered": first["covered"],
        "states": first["extra"] | {"listed": {str(p): s for p, s in sorted(first["ports"].items())}}}}
    complete = first["finished"] and not first["timed_out"] and first["covered"] == ALL_PORTS
    result["pass1_complete"] = complete
    suspects = sorted(port for port, state in first["ports"].items() if port != 443 and state not in ("closed", "filtered"))
    confirmed = []
    if suspects:
        second_xml = evidence / f"scan-{stamp}-pass2.xml"
        ports = ",".join(str(port) for port in suspects)
        run_quietly(runner, [nmap, "-Pn", "-p", ports, "--max-retries", "3", "-oX", str(second_xml), address], 3600)
        second = parse_nmap(second_xml)
        confirmed = [port for port in suspects if second["ports"].get(port) == "open"]
        result["pass2"] = {"ports": suspects, "finished": second["finished"],
                           "states": {str(p): second["ports"].get(p, "missing") for p in suspects}}
        if not second["finished"]:
            confirmed = suspects  # an unconfirmed suspect is never waved through
    result["confirmed_open_other_than_443"] = confirmed
    result["open_443"] = first["ports"].get(443) == "open"
    try:
        aaaa = {server: dig(host, "AAAA", server, runner) for server in PUBLIC_RESOLVERS}
        result["aaaa_empty"] = all(not answers for answers in aaaa.values())
    except CheckFailed as error:
        result["aaaa_empty"], result["aaaa_error"] = False, str(error)
    result["pass"] = complete and result["open_443"] and not confirmed and result["aaaa_empty"]
    if not complete:
        result["note"] = "first pass timed out or was partial: rerun in another tethered window"
    (evidence / f"scan-{stamp}-summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if not result["pass"]:
        raise CheckFailed(json.dumps(result))
    return result


# Hairpin source ---------------------------------------------------------------------------

def source_check(source, published, lan=paths.DEFAULT_HOUSEHOLD_LAN):
    """Classify the source HAProxy logged for a hairpinned connection (spec #23 Hairpin row)."""
    address = ipaddress.ip_address(source)
    published = ddns.public_ipv4(published or "")
    result = {"check": "hairpin-source", "source": str(address), "published": published, "lan": lan}
    if address in VM_NETWORK:
        result.update(kind="source-nat", pass_=False,
                      reason=f"{address} is in the VM network: the VM host applied source NAT; return to the planner")
    elif address in ipaddress.ip_network(lan):
        result.update(kind="household-lan", pass_=True)
    elif published and str(address) == published:
        result.update(kind="published-ipv4", pass_=True,
                      next="confirm it in HAProxy's household ACL (show acl) and run health --concurrent 25")
    else:
        result.update(kind="other", pass_=False, reason="neither the household LAN nor the published IPv4")
    result["pass"] = result.pop("pass_")
    if not result["pass"]:
        raise CheckFailed(json.dumps(result))
    return result


# Emergency stop ---------------------------------------------------------------------------

def halo_ssh_config():
    """halo-vm.sh's ssh_config for the user running golive (resolved from the home directory)."""
    return Path.home() / HALO_SSH_CONFIG_RELATIVE


def resolve_ssh_config(ssh_config=None):
    """(path or None, note) for the ssh_config golive's ssh calls use. An explicit --ssh-config must
    exist; by default halo-vm.sh's file is used when present, else plain ssh (said in the note)."""
    if ssh_config is not None:
        path = Path(ssh_config).expanduser()
        if not path.is_file():
            raise CheckFailed(f"--ssh-config {path} does not exist")
        return path, "--ssh-config"
    path = halo_ssh_config()
    if path.is_file():
        return path, "halo-vm.sh default"
    return None, f"halo-vm.sh ssh_config not found at {path}: plain ssh (the host must resolve without it)"


def remote(ssh_host, *argv, ssh_config=None):
    """argv for one command on the VM; ssh joins its arguments into a remote shell line, so each
    argument is quoted here. ssh_config (halo-vm.sh's aliases) is passed with -F when given."""
    config = ["-F", str(ssh_config)] if ssh_config is not None else []
    return ["ssh", *config, "-o", "BatchMode=yes", "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}", ssh_host, "--",
            " ".join(shlex.quote(str(arg)) for arg in argv)]


STATUS_KEYS = {"project", "host", "release", "emergency_stop", "apps", "healthcheck"}
APP_KEYS = {"status", "restarts", "pid", "service"}
APP_STATUSES = {"online", "stopped", "stopping", "launching", "errored", "missing"}


def app_states(status):
    """{app: status} from A's `prod.py status` JSON, accepting exactly its published shape:
    {"project","host","release","emergency_stop": bool, "apps": {<each of the six stack apps>:
    {"status", "restarts", "pid", "service": {...}|null}}, "healthcheck"}. The status of gateway
    and haproxy must be one of A's statuses; other apps may report any PM2 status string
    (for example "waiting restart" or "one-launch-status"). Anything else raises CheckFailed."""
    if not isinstance(status, dict) or set(status) != STATUS_KEYS or not isinstance(status["emergency_stop"], bool):
        raise CheckFailed("prod.py status is not the published shape")
    apps = status["apps"]
    if not isinstance(apps, dict) or set(apps) != set(paths.STACK_APPS):
        raise CheckFailed("prod.py status does not list exactly the six stack apps")
    states = {}
    for name, app in apps.items():
        if (not isinstance(app, dict) or set(app) != APP_KEYS or not isinstance(app["status"], str)
                or (name in paths.EMERGENCY_APPS and app["status"] not in APP_STATUSES)
                or not (app["service"] is None or isinstance(app["service"], dict))):
            raise CheckFailed(f"prod.py status entry for {name} is not the published shape")
        states[name] = app["status"]
    return states


def emergency_stop(reason, *, ssh_host=SSH_HOST, ssh_config=None, alert_command=None, runner=subprocess.run,
                   alert_runner=None):
    """Stop public access in the VM (seconds), then verify through prod.py status. Never resumes.
    ssh_config: an explicit ssh_config file; None uses halo-vm.sh's when it exists, else plain ssh."""
    if os.geteuid() == 0:
        raise CheckFailed("the emergency stop runs as the VM host user, not root")
    if alert_command and not Path(alert_command).is_absolute():
        raise CheckFailed("--alert-command must be an absolute path")
    reason = " ".join("".join(ch if ch.isprintable() else " " for ch in (reason or "")).split())[:200]
    if not reason:
        raise CheckFailed("--reason must say what was seen")
    config, config_note = resolve_ssh_config(ssh_config)
    started = now()
    stop_argv = remote(ssh_host, *PROD, "emergency-stop", "--reason", reason, ssh_config=config)
    stop = runner(stop_argv, capture_output=True, text=True, timeout=180, check=False)
    status_run = runner(remote(ssh_host, *PROD, "status", ssh_config=config), capture_output=True, text=True,
                        timeout=120, check=False)
    states, flag, shape_error = {}, None, None
    try:
        status = json.loads(status_run.stdout or "null")
        states = app_states(status)
        flag = status["emergency_stop"]
    except (ValueError, CheckFailed) as error:
        shape_error = str(error) if isinstance(error, CheckFailed) else "prod.py status is not JSON"
    # Verified stop: gateway and haproxy both "stopped" and the flag set (spec #20 Supervision 5).
    stopped = (stop.returncode == 0 and shape_error is None and flag is True
               and all(states.get(app) == "stopped" for app in paths.EMERGENCY_APPS))
    result = {"check": "emergency-stop", "at": started, "ssh_host": ssh_host,
              "ssh_config": str(config) if config is not None else None, "ssh_config_source": config_note,
              "command": " ".join(stop_argv[-1:]), "exit": stop.returncode,
              "app_states": {app: states.get(app, "not reported") for app in paths.EMERGENCY_APPS},
              "emergency_stop_flag": flag, "status_error": shape_error, "stopped": stopped, "reason": reason,
              "alert": "prod.py emergency-stop sends the ntfy message from the VM (not observable from the VM host)",
              "re-enable": "operator only: prod.py resume",
              "root_stop": ROOT_STOP + " (operator)", "pass": stopped}
    if not stopped:
        # The VM may be unreachable: tell the operator from the VM host too, through the VM host's dispatcher (same
        # anj-alert contract, given explicitly with --alert-command; there is no other alert path).
        # B1's root-only dispatcher runs through `sudo -n`; a refused sudo is "not delivered".
        delivered = bool(alert_command) and ddns.alert(
            f"anj-cloud EMERGENCY STOP {started}: could not confirm the stop in the VM. Seen: {reason}. "
            "operator: run the root stop now.", key="emergency-stop", command=alert_command, every=0,
            title="anj-cloud emergency stop", priority="urgent", sudo=str(alert_command) == HALO_DISPATCHER,
            runner=alert_runner)
        result["alert"] = "fallback sent from the VM host" if delivered else "fallback not delivered"
    print(json.dumps({"event": "emergency-stop", **result}, sort_keys=True), file=sys.stderr, flush=True)
    if not stopped:
        raise CheckFailed(json.dumps(result))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    line = sub.add_parser("line-check")
    line.add_argument("--router-wan")
    print_fp = sub.add_parser("fingerprint")
    print_fp.add_argument("certificate")
    check = sub.add_parser("health")
    check.add_argument("--host", required=True)
    check.add_argument("--cacert", required=True)
    check.add_argument("--resolver", choices=("public", "system"), default="public")
    check.add_argument("--expect-ip")
    check.add_argument("--no-hosts-entry", action="store_true", help="Fail if /etc/hosts names the host (roaming devices)")
    check.add_argument("--concurrent", type=int, default=0)
    check.add_argument("--expect", choices=("all-accepted", "some-refused"), default="all-accepted")
    full = sub.add_parser("scan")
    full.add_argument("address")
    full.add_argument("--host", required=True)
    full.add_argument("--evidence-dir", required=True)
    source = sub.add_parser("source-check")
    source.add_argument("--source", required=True)
    source.add_argument("--published", help="Published IPv4 (default: both DDNS endpoints)")
    source.add_argument("--lan", default=paths.DEFAULT_HOUSEHOLD_LAN)
    stop = sub.add_parser("stop")
    stop.add_argument("--reason", required=True)
    stop.add_argument("--ssh-host", default=SSH_HOST)
    stop.add_argument("--ssh-config", help="ssh_config file (default: halo-vm.sh's ~/" + str(HALO_SSH_CONFIG_RELATIVE)
                      + " when it exists, else plain ssh)")
    stop.add_argument("--alert-command", help=f"The VM host's anj-alert dispatcher (absolute path; {HALO_DISPATCHER} runs "
                      "through `sudo -n`), called as `--key emergency-stop --every 0 --title T --priority urgent -- "
                      "MESSAGE` when the stop cannot be confirmed")
    args = parser.parse_args(argv)
    try:
        if args.action == "line-check":
            result = line_check(args.router_wan)
        elif args.action == "fingerprint":
            result = fingerprint(args.certificate)
        elif args.action == "health":
            if not 0 <= args.concurrent <= 64:
                raise CheckFailed("--concurrent must be 0..64")
            result = health(args.host, args.cacert, resolver=args.resolver, expect_ip=args.expect_ip,
                            no_hosts_entry=args.no_hosts_entry, concurrent=args.concurrent, expect=args.expect)
        elif args.action == "scan":
            if not shutil.which("nmap"):
                raise CheckFailed("nmap is not installed (spec #23 gate: install it on the checking computer beforehand)")
            result = scan(args.address, args.host, args.evidence_dir)
        elif args.action == "source-check":
            published = args.published or ddns.discover(ddns.Http())
            result = source_check(args.source, published, args.lan)
        else:
            result = emergency_stop(args.reason, ssh_host=args.ssh_host, ssh_config=args.ssh_config,
                                    alert_command=args.alert_command)
    except (CheckFailed, ddns.Failure, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"action": args.action, "pass": False, "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
