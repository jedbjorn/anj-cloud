"""Stage a release source into a fresh VM before its first bootstrap (spec #21; the VM host side).

A fresh anj-prod or anj-qual has no data disk yet, so /srv/anj-cloud/release/current does not
exist. This copies `git archive <commit>` of a the VM host checkout to the VM's
/var/lib/anj-cloud-setup/source.tar and extracts it to /var/lib/anj-cloud-setup/src/, from where
`sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup` installs that release (it takes the
staged tar as its default --source). Nothing secret is copied, and it prints the exact `ssh -t`
command that opens the guided setup.

    python3 deploy/vm/stage.py anj-prod [--commit HEAD] [--checkout DIR]
    python3 deploy/vm/stage.py anj-prod --with-secrets [-- SETUP-ARGS…]       operator only (decision #109)

    python3 deploy/vm/stage.py anj-prod --commit <sha> --upgrade                 update production (decision #122)
    python3 deploy/vm/stage.py anj-qual --commit <sha> --upgrade                 the same on the qualification VM

--upgrade updates an installed VM to a reviewed release: from a clean the VM host checkout it stages
`git archive <sha>` exactly as above, then runs `sudo <staged copy>/anj-cloud-setup upgrade` over
`ssh -t`, which (after a backup when backups are set up and none succeeded in 24 h; --no-backup
skips it) installs it as release/<commit12> and switches to it through prod.py redeploy's
health-checked path (nothing switches on a failed check; the old release is kept for
`sudo anj-cloud-setup upgrade --rollback`). anj-prod takes only a commit merged into origin/main
(fetch first); every target needs the fixes prod.py requires. The operator is told before a production
update.

--with-secrets stages the release, then starts the guided setup itself and hands it the VM host's two
existing secrets so they are never typed: the Cloudflare DNS token file
(~/.local/state/anj-cloud-prod/secrets/cloudflare-dns-token) and the VM host's ntfy topic
(/etc/anj-cloud-host/ntfy-topic, read with sudo). They are read into this process's memory and
served once over a private Unix socket that ssh forwards into the VM (`ssh -R`), where setup reads
them into its own memory and stores them only in its 0600 state. They are never an argument, never
written to a file, a log, the evidence or the terminal. Agents never run it with the real files;
--token-file and --topic-file (read without sudo) exist for throwaway test values.

The default commit is this checkout's HEAD (a PR head before its merge, main after it), never an
unfetched origin/main. ssh goes through halo-vm.sh's ssh_config
(`ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config`).
"""

import argparse
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from deploy.vm import paths  # noqa: E402
from deploy.vm.bootstrap import STAGE_DIR, STAGE_SRC, STAGE_TAR  # noqa: E402

SSH_CONFIG = Path.home() / ".local" / "share" / "anj-cloud" / "prod-vm" / "ssh_config"
SETUP = STAGE_SRC / "deploy" / "vm" / "anj-cloud-setup"
CHECKOUT = Path(__file__).resolve().parent.parent.parent
TOKEN_FILE = Path.home() / ".local" / "state" / "anj-cloud-prod" / "secrets" / "cloudflare-dns-token"
HALO_TOPIC = Path("/etc/anj-cloud-host/ntfy-topic")
# Replaces the staged copy atomically enough for a single operator: the new tar is written beside
# the old one, then src/ is rebuilt from it.
UNPACK = (f"sudo install -d -m 0755 -o root -g root {STAGE_DIR} && "
          f"sudo tee {STAGE_TAR}.part >/dev/null && sudo mv -f {STAGE_TAR}.part {STAGE_TAR} && "
          f"sudo rm -rf {STAGE_SRC}.new && sudo install -d -m 0755 {STAGE_SRC}.new && "
          f"sudo tar --no-same-owner -C {STAGE_SRC}.new -xf {STAGE_TAR} && "
          f"sudo rm -rf {STAGE_SRC} && sudo mv {STAGE_SRC}.new {STAGE_SRC}")


QUAL_TARGET = "anj-qual"      # the throwaway qualification VM: may take an unmerged (PR head) commit


def ssh_argv(target, command, ssh_config=SSH_CONFIG):
    return ["ssh", "-F", str(ssh_config), "-T", "-o", "BatchMode=yes", target, command]


def setup_command(target, ssh_config=SSH_CONFIG):
    """M6: the runnable line for the guided setup (-t: the questions need a terminal)."""
    return f"ssh -t -F {ssh_config} {target} sudo {SETUP}"


def resolve(commit, checkout=CHECKOUT):
    result = subprocess.run(["git", "-C", str(checkout), "rev-parse", "--verify", commit + "^{commit}"],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"unknown commit {commit!r} in {checkout}")
    return result.stdout.strip()


def stage(runner, target, commit="HEAD", checkout=CHECKOUT):
    """git archive <commit> | ssh <target> unpack; runner.pipe(producer, consumer) -> bool (C's Runner)."""
    full = resolve(commit, checkout)
    producer = ["git", "-C", str(checkout), "archive", "--format=tar", full]
    if not runner.pipe(producer, ssh_argv(target, UNPACK), timeout=600):
        raise RuntimeError(f"staging {full[:12]} into {target} failed")
    return {"commit": full, "setup": str(SETUP)}


# Production release updates (decision #122) ------------------------------------------------------

def git_ok(checkout, *args, run=subprocess.run):
    return run(["git", "-C", str(checkout), *args], capture_output=True, text=True, check=False)


def check_upgrade(target, full, checkout=CHECKOUT, run=subprocess.run):
    """Refuse what must not reach a VM as an update: a checkout with changes (the reviewed tree is
    the commit, and nothing local may be mistaken for it), a commit lacking prod.py's required
    fixes, and on any target but anj-qual a commit not merged into origin/main (the VM cannot check
    either: it has no git)."""
    from deploy.prod import missing_required_commit
    status = git_ok(checkout, "status", "--porcelain", run=run)
    if status.returncode:
        raise RuntimeError(f"cannot read the state of {checkout}")
    if status.stdout.strip():
        raise RuntimeError(f"{checkout} has uncommitted or untracked changes; update from a clean checkout")
    if target != QUAL_TARGET:
        merged = git_ok(checkout, "merge-base", "--is-ancestor", full, "origin/main", run=run).returncode
        if merged:
            raise RuntimeError(f"{full[:12]} is not merged into origin/main (as fetched here); {target} takes only a "
                               "reviewed, merged release (git fetch origin main, then retry)")

    def has_commit(commit):
        return git_ok(checkout, "rev-parse", "--verify", "--quiet", commit + "^{commit}", run=run).returncode == 0

    def is_ancestor(ancestor, descendant):
        return git_ok(checkout, "merge-base", "--is-ancestor", ancestor, descendant, run=run).returncode == 0

    missing = missing_required_commit(full, has_commit, is_ancestor)
    if missing:
        required, purpose = missing
        raise RuntimeError(f"{full[:12]} does not contain {required} ({purpose})")


def upgrade_argv(target, commit, ssh_config=SSH_CONFIG, terminal=None, no_backup=False):
    """ssh -t (a terminal: the progress lines) running the staged copy's `upgrade` (the installed
    copy is the old release, which may not know the command), told which commit was staged
    (`--expect`, review L4). Ctrl-C or a dropped session stops only the waiting: the switch itself
    runs in its own session in the VM and finishes, or falls back, by itself (review H1)."""
    terminal = sys.stdin.isatty() if terminal is None else terminal
    command = f"sudo {SETUP} upgrade --expect {commit}" + (" --no-backup" if no_backup else "")
    return ["ssh", "-F", str(ssh_config), "-t" if terminal else "-T", target, command]


def run_upgrade(target, commit, ssh_config=SSH_CONFIG, popen=subprocess.Popen, no_backup=False):
    child = popen(upgrade_argv(target, commit, ssh_config, no_backup=no_backup))
    while True:
        try:
            return child.wait()
        except KeyboardInterrupt:          # ssh -t passes Ctrl-C on: the setup stops waiting and says so
            continue


class Runner:
    def pipe(self, producer, consumer, *, timeout=600):
        first = subprocess.Popen(producer, stdout=subprocess.PIPE)
        try:
            second = subprocess.run(consumer, stdin=first.stdout, timeout=timeout, check=False,
                                    stdout=subprocess.DEVNULL)
            first.stdout.close()
            return first.wait(timeout=60) == 0 and second.returncode == 0
        finally:
            if first.poll() is None:
                first.kill()
                first.wait()


# The VM host secret hand-off (decision #109) ------------------------------------------------------------

def read_one_line(text, what):
    value = (text or "").strip()
    if not value or "\n" in value:
        raise RuntimeError(f"the {what} must be exactly one line")
    return value


def read_halo_secrets(token_file=TOKEN_FILE, topic_file=None, run=subprocess.run):
    """{"token", "topic"} in memory. The VM host's topic is root-only, so without --topic-file it is read
    with `sudo cat` (sudo may ask for the operator's password); nothing is printed. A missing token file
    is allowed (setup then asks for the token)."""
    result = {}
    token_path = Path(token_file)
    if token_path.exists():
        result["token"] = read_one_line(token_path.read_text(), "Cloudflare token file")
    if topic_file:
        result["topic"] = read_one_line(Path(topic_file).read_text(), "ntfy topic file")
    else:
        print(f"Reading the VM host's ntfy topic ({HALO_TOPIC}) with sudo; it may ask for your password.", file=sys.stderr)
        read = run(["sudo", "cat", str(HALO_TOPIC)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if read.returncode:
            raise RuntimeError(f"could not read {HALO_TOPIC} (sudo cat exit {read.returncode})")
        result["topic"] = read_one_line(read.stdout.decode("utf-8", "replace"), "ntfy topic")
    return result


class SecretServer:
    """Serves the payload once, on a Unix socket in a private (0700) directory, to one peer only:
    the process whose SO_PEERCRED pid is `allow`ed (the ssh child this script started, whose -R
    forward connects here). Any other connection is closed before a byte is sent and logged without
    a value; serving continues until the allowed peer is served or the server is closed."""

    def __init__(self, payload, directory=None, log=None):
        self.payload = json.dumps(payload).encode()
        self.log = log or (lambda text: print(text, file=sys.stderr, flush=True))
        self.directory = Path(tempfile.mkdtemp(prefix="anj-stage-", dir=directory))
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "s.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        os.chmod(self.path, 0o600)
        self.listener.listen(4)
        self.listener.settimeout(0.5)
        self.allowed = None
        self.refused = 0
        self.served = threading.Event()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def allow(self, pid):
        self.allowed = pid

    @staticmethod
    def peer_pid(connection):
        raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", raw)[0]

    def serve(self):
        while not self.stopped.is_set() and not self.served.is_set():
            try:
                connection, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return                                 # closed
            with connection:
                try:
                    pid = self.peer_pid(connection)
                except OSError:
                    pid = None
                if self.allowed is None or pid != self.allowed:
                    self.refused += 1
                    self.log(f"stage: refused a connection to the hand-off socket from pid {pid} (not the ssh this "
                             "script started); nothing was sent.")
                    continue
                try:
                    connection.sendall(self.payload)
                except OSError:
                    continue
                self.served.set()                      # before the close: the reader may finish at once
            self.payload = b""

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stopped.set()
        try:
            self.listener.close()
        except OSError:
            pass
        self.thread.join(timeout=5)
        self.payload = b""
        shutil.rmtree(self.directory, ignore_errors=True)
        return False


def remote_socket():
    return f"/home/{paths.VM_USER}/.anj-cloud-setup-{secrets.token_hex(8)}.sock"


def handoff_argv(target, local, remote, setup_args=(), ssh_config=SSH_CONFIG, terminal=None):
    """ssh with the socket forward; the setup gets only the socket's path, never a value. No
    connection sharing: the forward must be made by this very ssh process (SO_PEERCRED)."""
    terminal = sys.stdin.isatty() if terminal is None else terminal
    command = " ".join(shlex.quote(part) for part in ["sudo", str(SETUP), "--secrets-socket", remote, *setup_args])
    return ["ssh", "-F", str(ssh_config), "-t" if terminal else "-T", "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-R", f"{remote}:{local}", target, command]


def run_with_secrets(target, values, setup_args=(), ssh_config=SSH_CONFIG, popen=subprocess.Popen, run=None,
                     server_dir=None, log=None):
    """Start the VM's setup through ssh with `values` served once over the forwarded socket, to
    that ssh process only. Returns (ssh exit code, whether the setup read the secrets); the mark is
    read only after the server thread has finished. `run` (tests) is an in-process stand-in for ssh:
    its connections come from this process."""
    with SecretServer(values, server_dir, log) as server:
        values = None
        argv = handoff_argv(target, str(server.path), remote_socket(), setup_args, ssh_config)
        if run is not None:
            server.allow(os.getpid())
            code = run(argv, check=False).returncode
        else:
            child = popen(argv)
            server.allow(child.pid)
            while True:
                try:
                    code = child.wait()
                    break
                except KeyboardInterrupt:      # Ctrl-C belongs to the remote setup (ssh -t passes it on)
                    continue
    return code, server.served.is_set()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("target", help="ssh alias in halo-vm.sh's ssh_config (anj-qual, anj-prod)")
    parser.add_argument("--commit", default="HEAD", help="Commit to stage (default: this checkout's HEAD)")
    parser.add_argument("--checkout", default=str(CHECKOUT))
    parser.add_argument("--with-secrets", action="store_true",
                        help="operator only: start setup and hand it the VM host's Cloudflare token and ntfy topic (decision #109)")
    parser.add_argument("--token-file", default=str(TOKEN_FILE), help="--with-secrets: the Cloudflare token file")
    parser.add_argument("--topic-file", help="--with-secrets: a topic file read without sudo (test values only)")
    parser.add_argument("--upgrade", action="store_true",
                        help="Update the installed VM to this commit: stage it, then run `anj-cloud-setup upgrade` "
                             "(decision #122)")
    parser.add_argument("--no-backup", action="store_true",
                        help="--upgrade: skip the backup before the switch (the setup warns)")
    parser.add_argument("setup_args", nargs="*", help="after --: arguments for anj-cloud-setup (with --with-secrets)")
    args = parser.parse_args(argv)
    if args.upgrade and (args.with_secrets or args.setup_args):
        parser.error("--upgrade takes no --with-secrets and no setup arguments")
    if args.no_backup and not args.upgrade:
        parser.error("--no-backup goes with --upgrade")
    try:
        if args.upgrade:
            check_upgrade(args.target, resolve(args.commit, Path(args.checkout)), Path(args.checkout))
        result = stage(Runner(), args.target, args.commit, Path(args.checkout))
    except RuntimeError as error:
        print(f"stage: {error}", file=sys.stderr)
        return 1
    if args.upgrade:
        print(f"Staged release {result['commit'][:12]} into {args.target}; running its upgrade "
              f"(ssh {args.target} sudo {SETUP} upgrade):", file=sys.stderr, flush=True)
        return run_upgrade(args.target, result["commit"], no_backup=args.no_backup)
    if not args.with_secrets:
        print(f"Staged release {result['commit'][:12]} into {args.target}. Next, run this on the VM host "
              f"(it opens the guided setup inside the VM):\n\n  {setup_command(args.target)}\n\n"
              "Or let this script copy the VM host's Cloudflare token and ntfy topic into the setup (nothing to type):\n"
              f"  python3 {Path(__file__).resolve()} {args.target} --with-secrets")
        return 0
    try:
        values = read_halo_secrets(args.token_file, args.topic_file)
    except (OSError, RuntimeError) as error:
        print(f"stage: {error if isinstance(error, RuntimeError) else type(error).__name__}; nothing was copied",
              file=sys.stderr)
        return 1
    print(f"Staged release {result['commit'][:12]} into {args.target}. Copying two secrets from the VM host into the "
          "VM's setup (memory only), so you don't have to type them:\n"
          f"  - Cloudflare DNS token   {'from ' + str(args.token_file) if 'token' in values else '(no token file: setup asks)'}\n"
          f"  - ntfy alert topic       from {args.topic_file or HALO_TOPIC}\n"
          "They travel over SSH only, are never shown, never logged, and setup stores them only in its 0600 state.\n",
          file=sys.stderr)
    code, served = run_with_secrets(args.target, values, args.setup_args)
    values = None
    if not served:
        print("stage: the secrets were not used: the setup did not read them (it stopped before, did not need them, "
              "or the forward failed). Nothing was sent.", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
