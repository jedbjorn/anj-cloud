#!/usr/bin/env python3
"""Manage only the isolated, synthetic anj-cloud Nextcloud development stack."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
FIXTURE_USERS = ("anj-fixture-alice", "anj-fixture-bob")
FIXTURE_NAMES = ("Alice", "Bob")
PROJECT = re.compile(r"anj-cloud-[a-z0-9][a-z0-9-]{0,30}")
# The in-checkout state default (deploy/.local/<project>) serves only the dev stack and
# disposable review/test projects; production and drill state need an explicit --state-root.
LOCAL_PROJECTS = re.compile(r"anj-cloud-(dev|review|test)(-[a-z0-9]+)*")
# A review stack `anj-cloud-review-<tag>` labels every container anj.owner=<tag>, the test
# lifecycle's owner label (anj_test_seats skill; anj-test-inventory --owner <tag>).
REVIEW_PROJECT = re.compile(r"anj-cloud-review-([a-z0-9][a-z0-9-]*)")
# Trust and stack profile; production passes its own values (deploy/prod.py).
DEV_PROFILE = {
    "issuer_cn": "anj-cloud Dev issuer",
    "issuer_days": 365,
    "server_cn": "localhost",
    "server_san": ("DNS:localhost", "IP:127.0.0.1"),
    "server_days": 364,
    "admin_user": "anj-dev-admin",
    "trusted_domains": ("localhost", "127.0.0.1", "nextcloud"),
}
FIXTURE_ROOT = "anj-foundation-fixture"
# How many days Nextcloud keeps deleted items before removing them for good (spec #44 T2). A deployment
# setting: ANJ_TRASH_DAYS for dev and review stacks, `trash_days` in a production stack.json.
TRASH_DAYS = 7
MAX_TRASH_DAYS = 3650


def valid_trash_days(value):
    try:
        days = int(str(value).strip())
    except ValueError:
        days = 0
    if not 1 <= days <= MAX_TRASH_DAYS:
        raise RuntimeError(f"trash_days must be a whole number of days from 1 to {MAX_TRASH_DAYS}")
    return days
PAYLOAD = b"anj-cloud synthetic foundation fixture\n" * 1024


def no_foreign_children(status, body, root):
    # SabreDAV may return the empty namespace collection instead of denying its root.
    if status in (403, 404):
        return
    if status == 207:
        hrefs = [response.findtext("{DAV:}href") for response in ET.fromstring(body).findall("{DAV:}response")]
        if hrefs == [root]:
            return
    raise RuntimeError("Foreign namespace listing exposed child entries or an unexpected response")


def private_directory(path):
    if path.is_symlink():
        raise RuntimeError(f"Refusing symlink directory: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise RuntimeError(f"Directory must be owned by this user: {path}")
    path.chmod(0o700)


def secret_file(path):
    """Create once, never rotate existing database/account passwords on setup."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError(f"Secret must be a private owned regular file: {path}") from None
        if not re.fullmatch(r"[0-9a-f]{64}\n?", path.read_text()):
            raise RuntimeError(f"Unexpected secret format: {path}")
    else:
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_hex(32) + "\n")


class Stack:
    compose_file = ROOT / "compose.json"
    # The media fetch fixture site (spec #42): a dev/review-only override that adds `fetch-fixture`
    # and names it as the one host the worker may reach on a private address. Never in production.
    fetch_fixture_file = ROOT / "compose.fetch-fixture.json"

    def __init__(self, project, port):
        if not PROJECT.fullmatch(project):
            raise ValueError("Project must start anj-cloud- and contain lowercase letters/digits/hyphens")
        if not LOCAL_PROJECTS.fullmatch(project):
            raise ValueError(f"{project} needs an explicit --state-root outside any git worktree; "
                             "the in-checkout default serves only anj-cloud-dev and review/test projects")
        if not 1024 <= port <= 65535:
            raise ValueError("SC_DEV_PORT/--port must be between 1024 and 65535")
        self.project, self.port = project, port
        self.profile = dict(DEV_PROFILE)
        self.local = ROOT / ".local" / project
        self.secret_dir = self.local / "secrets"
        self.base = f"http://127.0.0.1:{port}"
        self.origin = f"https://127.0.0.1:{port}"
        self.venv_python = ROOT / ".local" / "access-venv" / "bin" / "python"
        self.environment = os.environ.copy()
        self.environment.update(SC_DEV_PORT=str(port), ANJ_SECRETS_DIR=str(self.secret_dir),
                                ANJ_OPERATOR_DIR=str(self.local / "operator"),
                                # Console backend socket directory (spec #27), bind-mounted at /run/anj-console.
                                ANJ_CONSOLE_DIR=str(self.local / "console"),
                                ANJ_ADMIN_USER=self.profile["admin_user"],
                                ANJ_TRUSTED_DOMAINS=" ".join(self.profile["trusted_domains"]),
                                ANJ_FETCH_FIXTURE_DIR=str(self.local / "fetch-fixture"))

    @property
    def fetch_fixture(self):
        """Whether this project runs the fetch fixture site (chosen once with --fetch-fixture)."""
        return (self.local / "fetch-fixture.enabled").exists()

    def enable_fetch_fixture(self):
        if self.profile.get("production"):
            raise RuntimeError("The fetch fixture site is for dev and review stacks only")
        for path in (ROOT / ".local", self.local, self.local / "fetch-fixture"):
            private_directory(path)
        (self.local / "fetch-fixture.enabled").touch(mode=0o600)

    def services(self):
        files = [self.compose_file] + ([self.fetch_fixture_file] if self.fetch_fixture else [])
        return sorted({name for path in files for name in json.loads(Path(path).read_text())["services"]})

    def setup(self):
        for path in (ROOT / ".local", self.local, self.secret_dir, self.local / "console"):
            private_directory(path)
        for name in ("database", "admin", *FIXTURE_USERS):
            secret_file(self.secret_dir / name)
        if not self.venv_python.exists():
            raise RuntimeError("Run python3 deploy/dev.py deps for isolated pinned dependencies")
        self.run([str(self.venv_python), "-m", "deploy.access_operator", "--project", self.project, "--port", str(self.port), "trust"])
        print(f"Private synthetic credentials ready: {self.secret_dir} (values withheld)")

    def deps(self):
        self.run([sys.executable, "-m", "venv", str(self.venv_python.parent.parent)])
        self.run([str(self.venv_python), "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
                  "--index-url", "https://pypi.org/simple", "-r", str(ROOT.parent / "services/access/requirements.txt")])
        print("PASS isolated pinned access dependencies installed")

    def run(self, argv, *, data=None):
        result = subprocess.run(argv, input=data, text=True, capture_output=True,
                                env=self.environment, cwd=ROOT.parent, timeout=600, check=False)
        if result.returncode:
            # Subprocess diagnostics can contain configuration/credentials. Never echo them.
            error = RuntimeError(f"Command failed (exit {result.returncode}); output withheld: {argv[0]}")
            error.captured_stdout = result.stdout  # Private caller may parse a known redacted protocol envelope.
            raise error
        return result.stdout

    def owner_labels(self):
        """For a review stack, a Compose override labelling every service anj.owner=<tag>; else None."""
        match = REVIEW_PROJECT.fullmatch(self.project)
        if match is None:
            return None
        content = json.dumps({"services": {name: {"labels": {"anj.owner": match.group(1)}} for name in self.services()}},
                             indent=2) + "\n"
        private_directory(self.local)
        path = self.local / "owner-labels.json"
        if not path.exists() or path.read_text() != content:
            path.write_text(content)
            path.chmod(0o600)
        return path

    def compose_argv(self, *args):
        console = Path(self.environment.get("ANJ_CONSOLE_DIR", ""))
        if console.name == "console" and console.parent.is_dir() and not console.exists():
            private_directory(console)
        labels = self.owner_labels()
        fixture = ["--file", str(self.fetch_fixture_file)] if self.fetch_fixture else []
        return ["docker", "compose", "--env-file", "/dev/null", "--project-name", self.project,
                "--file", str(self.compose_file), *fixture, *(["--file", str(labels)] if labels else []), *args]

    def compose(self, *args, data=None):
        return self.run(self.compose_argv(*args), data=data)

    def compose_stream(self, *args, source, timeout=1800):
        """`compose` with a binary file as stdin, streamed, never read into memory (spec #28 G1)."""
        result = subprocess.run(self.compose_argv(*args), stdin=source, capture_output=True,
                                env=self.environment, cwd=ROOT.parent, timeout=timeout, check=False)
        stdout = result.stdout.decode("utf-8", "replace")
        if result.returncode:
            error = RuntimeError(f"Command failed (exit {result.returncode}); output withheld: docker")
            error.captured_stdout = stdout
            raise error
        return stdout

    def occ(self, *args):
        return self.compose("exec", "-T", "--user", "www-data", "nextcloud", "php", "occ", *args)

    def destroy(self):
        """Delete this project's containers, networks and volumes, then its operator journals.

        The journals (operator/journals/, reissue/ included, and reconciliation-token.json)
        describe pairings, app tokens and leaves in the registry and Nextcloud volumes just
        deleted. Left behind, they make every later `reconcile` on the recreated stack fail
        "Unknown pairing" (SC-055). They are removed, not kept aside: a minted journal holds an
        app token and a signed leaf for state that no longer exists. Only after `down --volumes`
        succeeded, under the operator lock, and only this project's own directory: the issuer,
        server certificate and secrets stay, as before.
        """
        if self.profile.get("production"):
            raise RuntimeError("destroy is for dev and review stacks only")
        self.compose("down", "--volumes", "--timeout", "30")
        self.forget_operator_journals()

    def forget_operator_journals(self):
        operator = self.local / "operator"
        if operator.is_symlink():
            raise RuntimeError("Refusing a symlinked operator directory; journals kept")
        if not operator.is_dir():
            return
        fd = os.open(operator / "operation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            journals = operator / "journals"
            if journals.is_symlink():
                raise RuntimeError("Refusing a symlinked journals directory; journals kept")
            if journals.is_dir():
                shutil.rmtree(journals)
            (operator / "reconciliation-token.json").unlink(missing_ok=True)
        finally:
            os.close(fd)

    def up(self):
        self.setup()
        self.compose("up", "--detach", "--wait", "--wait-timeout", "420", "db", "redis", "nextcloud", "cron")
        self.trusted_domains()
        self.compose("up", "--detach", "--build", "--wait", "--wait-timeout", "420")
        self.occ("background:cron")
        self.occ("config:system:set", "shareapi_allow_links", "--type=boolean", "--value=false")
        self.occ("config:system:set", "share_folder", "--value=/anj-cloud/Shared")
        self.occ("config:system:set", "sharing.allow_custom_share_folder", "--type=boolean", "--value=false")
        self.advertise_trash(self.apply_trash())
        self.check()
        if not self.profile.get("production"):
            self.accounts()

    def trash_days(self):
        """Days deleted items stay in the trash (spec #44 T2): ANJ_TRASH_DAYS, else 7."""
        return valid_trash_days(self.environment.get("ANJ_TRASH_DAYS", TRASH_DAYS))

    def apply_trash(self):
        """Sets Nextcloud's trash retention to exactly `trash_days` (minimum and maximum, `7, 7`) and
        returns the days read back. Expiry is Nextcloud's own background job in the cron container."""
        days = self.trash_days()
        self.occ("config:system:set", "trashbin_retention_obligation", f"--value={days}, {days}")
        current = self.occ("config:system:get", "trashbin_retention_obligation").strip()
        if current != f"{days}, {days}":
            raise RuntimeError("Nextcloud did not keep the trash retention setting")
        return days

    def advertise_trash(self, days=None):
        """The gateway advertises the retention read back from Nextcloud to every client. Best effort: a
        gateway from before spec #44 (a rollback) refuses the action and advertises nothing, a current one
        that misses it advertises 7 until the next setup or upgrade; neither stops the deployment."""
        days = self.apply_trash() if days is None else days
        try:
            self.compose("exec", "-T", "access", "python", "-m", "access.admin",
                         data=json.dumps({"action": "trash-days", "days": days}))
        except RuntimeError:
            print("WARNING: the gateway did not take trash_days; it advertises its default (7 days)", file=sys.stderr)
            return None
        return days

    def trusted_domains(self):
        domains = self.profile["trusted_domains"]
        for index, domain in enumerate(domains):
            self.occ("config:system:set", "trusted_domains", str(index), "--value=" + domain)
        current = json.loads(self.occ("config:system:get", "trusted_domains", "--output=json") or "[]")
        for index in range(len(domains), len(current) if isinstance(current, list) else 0):
            self.occ("config:system:delete", "trusted_domains", str(index))

    def check(self):
        self.validate_ports()
        old_base, self.base = self.base, self.origin
        try:
            status, body = self.http("GET", "/health")
        finally:
            self.base = old_base
        state = json.loads(body)
        if status != 200 or state.get("status") != "ready":
            raise RuntimeError("TLS access gateway is not available")
        if self.occ("config:system:get", "dbtype").strip() != "pgsql":
            raise RuntimeError("Nextcloud is not configured for PostgreSQL")
        if self.occ("config:system:get", "memcache.locking").strip() != "\\OC\\Memcache\\Redis":
            raise RuntimeError("Nextcloud Redis file locking is not configured")
        print(f"PASS TLS gateway and Nextcloud with PostgreSQL/Redis at {self.origin}")

    def redeploy_access(self):
        """Rebuild and recreate only the access gateway; backend services, volumes and state stay."""
        self.compose("up", "--detach", "--build", "--no-deps", "--wait", "--wait-timeout", "180", "access")
        self.check()

    def validate_ports(self):
        ids = self.compose("ps", "--all", "--quiet").split()
        if not ids:
            raise RuntimeError("No containers for this development project")
        containers = json.loads(self.run(["docker", "inspect", *ids]))
        services = set()
        for container in containers:
            labels = container["Config"]["Labels"]
            if labels.get("com.docker.compose.project") != self.project:
                raise RuntimeError("Unexpected container project")
            service = labels["com.docker.compose.service"]
            services.add(service)
            ports = container["NetworkSettings"]["Ports"] or {}
            bindings = [(port, binding) for port, values in ports.items() for binding in (values or [])]
            expected = [("8443/tcp", {"HostIp": "127.0.0.1", "HostPort": str(self.port)})]
            if bindings != (expected if service == "access" else []):
                raise RuntimeError(f"Unexpected published ports for {service}")
            if not container["State"]["Running"]:
                raise RuntimeError(f"Service is not running: {service}")
        if services != set(self.services()):
            raise RuntimeError("Development service set is incomplete")

    def http(self, method, path, user=None, data=None, headers=None):
        headers = dict(headers or {})
        if user:
            password = (self.secret_dir / user).read_text().strip()
            token = base64.b64encode(f"{user}:{password}".encode()).decode()
            headers["Authorization"] = "Basic " + token
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        # Do not send fixture credentials through proxies or redirects.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, hdrs, newurl):
                return None
        handlers = [urllib.request.ProxyHandler({}), NoRedirect()]
        if self.base.startswith("https:"):
            context = ssl.create_default_context(cafile=str(self.local / "operator/issuer.crt"))
            handlers.append(urllib.request.HTTPSHandler(context=context))
        opener = urllib.request.build_opener(*handlers)
        try:
            with opener.open(request, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as response:
            with response:
                return response.code, response.read()

    def backend_http(self, method, path, user=None, data=None, headers=None):
        """Privileged fixture helper runs inside Nextcloud, never a published bypass.

        Account passwords stay in host operator tooling and the Nextcloud process;
        they are not sent into the access service/container.
        """
        headers = dict(headers or {})
        if user:
            password = (self.secret_dir / user).read_text().strip()
            headers["Authorization"] = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        if not path.startswith("/") or path.startswith("//") or any(c in path for c in "\r\n"):
            raise RuntimeError("Invalid local backend fixture path")
        php = r'''$r=json_decode(stream_get_contents(STDIN),true);$h=[];foreach($r['headers'] as $k=>$v){$h[]=$k.': '.$v;}$o=['http'=>['method'=>$r['method'],'header'=>implode("\r\n",$h),'content'=>base64_decode($r['body']),'ignore_errors'=>true,'follow_location'=>0,'timeout'=>30]];$f=fopen('http://127.0.0.1'.$r['path'],'r',false,stream_context_create($o));if(!$f){exit(1);}$b=stream_get_contents($f);$m=stream_get_meta_data($f);fclose($f);preg_match('/^HTTP\/[^ ]+ ([0-9]+)/',$m['wrapper_data'][0],$s);echo json_encode(['status'=>(int)$s[1],'body'=>base64_encode($b)]);'''
        envelope = json.dumps({"method": method, "path": path, "headers": headers,
                               "body": base64.b64encode(data or b"").decode()})
        output = self.compose("exec", "-T", "--user", "www-data", "nextcloud", "php", "-r", php, data=envelope)
        result = json.loads(output)
        return result["status"], base64.b64decode(result["body"])

    def dav(self, method, user, path="", data=None, headers=None, expected=(200,)):
        url = "/remote.php/dav/files/" + user + "/" + urllib.parse.quote(path, safe="/")
        status, body = self.backend_http(method, url, user, data, headers)
        if status not in expected:
            raise RuntimeError(f"Fixture {method} returned {status}, expected {expected}")
        return body

    def accounts(self):
        existing = json.loads(self.occ("user:list", "--output=json"))
        for user in FIXTURE_USERS:
            if user not in existing:
                # Only these fixed synthetic account IDs are created; password travels over stdin.
                password = (self.secret_dir / user).read_text().strip()
                script = 'read -r OC_PASS; export OC_PASS; exec php occ user:add --password-from-env -- "$1"'
                self.compose("exec", "-T", "--user", "www-data", "nextcloud", "sh", "-c", script,
                             "fixture-account", user, data=password + "\n")
        # The household user list (spec #26): fixtures are registered as "Alice" and "Bob".
        for user, name in zip(FIXTURE_USERS, FIXTURE_NAMES):
            self.compose("exec", "-T", "access", "python", "-m", "access.admin",
                         data=json.dumps({"action": "account-set", "uid": user, "display_name": name}))

    def fixture(self):
        self.run([str(self.venv_python), "-m", "deploy.access_fixture", "--project", self.project, "--port", str(self.port)])
        print("PASS paired access fixture (see explicit fixture output for detailed results)")

    def cleanup_fixtures(self):
        # Deleting the owner fixture folder also removes its shares. No account or other path is deleted.
        for user in FIXTURE_USERS:
            self.dav("DELETE", user, FIXTURE_ROOT, expected=(204, 404))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="anj-cloud-dev")
    parser.add_argument("--port", type=int, default=os.environ.get("SC_DEV_PORT", "8834"))
    parser.add_argument("command", choices=("deps", "setup", "doctor", "up", "stop", "check", "redeploy-access", "fixture", "cleanup-fixtures", "destroy"))
    parser.add_argument("--confirm-delete-project", help="Required exact project name for destroy")
    parser.add_argument("--fetch-fixture", action="store_true",
                        help="Add the media fetch fixture site to this dev/review project (remembered)")
    args = parser.parse_args()
    try:
        stack = Stack(args.project, args.port)
        if args.fetch_fixture:
            stack.enable_fetch_fixture()
        if args.command == "doctor":
            stack.run(["docker", "compose", "version"])
            stack.run(["docker", "info", "--format", "{{.ServerVersion}}"])
            stack.run(["openssl", "version"])
            stack.run([str(stack.venv_python), "-c", "import aiohttp,cryptography,defusedxml"])
            print("PASS Python, pinned access dependencies, OpenSSL, Docker Compose and daemon access")
        elif args.command == "stop":
            stack.compose("down", "--timeout", "30")
            print("Stopped this project; durable volumes and local credentials retained")
        elif args.command == "destroy":
            if args.confirm_delete_project != args.project:
                raise RuntimeError("destroy requires --confirm-delete-project with the exact project name")
            stack.destroy()
            print("Deleted this project's containers/networks/volumes and operator journals; "
                  "private credential files retained")
        else:
            getattr(stack, args.command.replace("-", "_"))()
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired, ET.ParseError) as error:
        # Never include arbitrary upstream response bodies or subprocess output in errors.
        if isinstance(error, (RuntimeError, ValueError)):
            print(f"ERROR: {error}", file=sys.stderr)
        else:
            print(f"ERROR: {type(error).__name__}; diagnostic content withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
