"""Stand-ins for the bootstrap's machine access (spec #21 B2 tests and the pty driver).

FakeSystem never runs a changing command: `change` records it, `write`/`mkdir`/`symlink` record
(dry) or write under a test directory. `read` answers from canned responses; only the pure
renderers of the release (ddns.py pm2-app, backup.py units) really run.
"""

import json
import os
from pathlib import Path
import pwd
import subprocess

from deploy.vm import bootstrap


class FakeSystem(bootstrap.System):
    def __init__(self, *, dry=True, responses=None, out=None):
        super().__init__(dry=dry, out=out)
        self.responses = responses or {}
        self.reads = []
        self.executed = []
        self.events = []            # writes and changes, in order

    def read(self, argv, *, user=None, timeout=120, data=None, cwd=None, umask=-1):
        argv = [str(a) for a in argv]
        self.reads.append(argv)
        if argv[0] == "python3" and any(part.endswith(("deploy/ddns.py", "deploy/backup.py")) for part in argv) \
                and ("pm2-app" in argv or "units" in argv):
            result = subprocess.run(argv, capture_output=True, text=True, timeout=120, cwd=cwd, check=False, input=data)
            return result.returncode, result.stdout, result.stderr
        for prefix, answer in self.responses.items():
            if " ".join(argv).startswith(prefix):
                return answer(argv, data) if callable(answer) else answer
        return 1, "", "not modelled"

    def change(self, argv, **options):
        self.executed.append([str(a) for a in argv]) if not self.dry else None
        self.commands.append({"argv": [str(a) for a in argv]})
        self.events.append(("run", " ".join(str(a) for a in argv)))
        return 0, "", ""

    def attended(self, argv, *, user=None, timeout=3600):
        argv = [str(a) for a in argv]
        self.commands.append({"argv": argv, **({"user": user} if user else {})})
        self.events.append(("attended", " ".join(argv)))
        for prefix, answer in self.responses.items():
            if " ".join(argv).startswith(prefix):
                return answer(argv, None) if callable(answer) else answer
        return 1, "", "not modelled"

    def write(self, path, data, *, mode=0o644, owner=None, secret=False):
        data = data.encode() if isinstance(data, str) else data
        self.files.append({"path": str(path), "sha256": "secret" if secret else bootstrap.sha256(data), "mode": oct(mode)})
        self.events.append(("write", str(path)))
        if self.dry:
            return
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        os.fchmod(fd, mode)
        os.write(fd, data)
        os.close(fd)

    def mkdir(self, path, *, mode, owner=None, group=None):
        self.files.append({"path": str(path) + "/", "mode": oct(mode)})

    def remove(self, path):
        self.files.append({"path": str(path), "removed": True})
        if not self.dry:
            Path(path).unlink(missing_ok=True)

    def symlink(self, target, link):
        self.files.append({"path": str(link), "symlink": str(target)})


DEBIAN = {"ID": "debian", "VERSION_CODENAME": "trixie", "PRETTY_NAME": "Debian GNU/Linux 13 (trixie)"}


class FakeFacts(bootstrap.Facts):
    """A fresh Debian 13 VM like anj-qual: 4 GiB, 4 CPUs, vda OS, blank vdb, nothing on 443."""

    def __init__(self, system, **overrides):
        super().__init__(system)
        self.values = {"os": dict(DEBIAN), "arch": "amd64", "memory": 4013452, "cpus": 4, "free": 15 * 1024 ** 3,
                       "route": ("10.77.11.10", "10.77.11.1"), "timezone": "Europe/Paris", "synced": True,
                       "user": pwd.getpwuid(os.getuid()), "listeners": [], "haproxy": False, "published": [],
                       "disks": [{"path": "/dev/vda", "size": 20 << 30, "mounts": ["/", "/boot/efi"], "children": 3,
                                  "fstype": None, "label": None, "uuid": None},
                                 {"path": "/dev/vdb", "size": 200 << 30, "mounts": [], "children": 0, "fstype": None,
                                  "label": None, "uuid": None}],
                       "signatures": {"/dev/vdb": []}, "mounted": {}, "installed": {}, "candidate": {},
                       "ssh_client": None, "ssh_live": True}
        self.values.update(overrides)

    def os_release(self):
        return self.values["os"]

    def architecture(self):
        return self.values["arch"]

    def memory_kib(self):
        return self.values["memory"]

    def cpus(self):
        return self.values["cpus"]

    def free_bytes(self, path="/"):
        return self.values["free"]

    def default_route(self):
        return self.values["route"]

    def timezone(self):
        return self.values["timezone"]

    def ssh_client(self):
        return self.values["ssh_client"]

    def ssh_client_live(self):
        return self.values["ssh_live"]

    def time_synchronized(self):
        return self.values["synced"]

    def user(self, name=None):
        return self.values["user"]

    def disks(self):
        return self.values["disks"]

    def signatures(self, device):
        return self.values["signatures"].get(device, ["unknown"])

    def mount_source(self, target):
        return self.values["mounted"].get(str(target))

    def listeners_443(self):
        return self.values["listeners"]

    def our_haproxy_running(self):
        return self.values["haproxy"]

    def docker_published(self):
        return self.values["published"]

    def installed(self, package):
        return self.values["installed"].get(package)

    def candidate(self, package):
        return self.values["candidate"].get(package)


def git_archive(directory):
    """A release tar of this checkout's HEAD, as `git archive` makes it (pax comment = commit)."""
    root = Path(bootstrap.__file__).resolve().parent.parent.parent
    path = Path(directory) / "source.tar"
    with open(path, "wb") as stream:
        subprocess.run(["git", "-C", str(root), "archive", "--format=tar", "HEAD"], stdout=stream, check=True)
    commit = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True,
                            check=True).stdout.strip()
    return path, commit


def write_answers(directory, text):
    path = Path(directory) / "answers.toml"
    path.write_text(text)
    return path


def no_network(*_args, **_kwargs):
    return True


def json_dump(value):
    return json.dumps(value)
