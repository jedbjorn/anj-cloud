"""Media fetch end to end on a review stack with the fixture site (spec #42 acceptance).

    deploy/.local/access-venv/bin/python -m deploy.fetch_fixture --project anj-cloud-review-<tag> --port <port> \
        --evidence <dir> [--case presets,tenancy,playlist,isolation,restart,revoke,update,memory,large]

The stack must run with the worker and the fixture site:
`python3 deploy/dev.py --project anj-cloud-review-<tag> --port <port> --fetch-fixture up`.
Every case pairs its own synthetic devices for the fixture accounts, uses only fixture links
(http://fetch-fixture:8080/...), deletes the files it created and revokes its devices. Evidence
(job rows, ffprobe output of the files read back through the gateway, probe results) goes to
--evidence; nothing printed carries a credential.
"""

import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time
from urllib.parse import quote
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory

SITE = "http://fetch-fixture:8080"
TERMINAL = {"done", "rejected", "failed", "cancelled"}
CASES = ("presets", "tenancy", "playlist", "isolation", "restart", "revoke", "update", "memory", "large")
OLD_YTDLP = ("2025.10.22", "fd99687645340163094d8b21390c59102900f3e7bcdd1fc0112622bf72989d4f")
SPOOL = "/var/lib/anj-fetch"


def item(name, query=""):
    return SITE + "/item/" + name + ".html" + query


def href(relative):
    return "/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))


class Run:
    def __init__(self, stack, evidence):
        self.stack, self.evidence = stack, evidence
        self.operator = Operator(stack)
        self.actors, self.created = [], []
        self.nonce = secrets.token_hex(4)
        self.clients = stack.local / "operator/clients" / ("fetch-" + self.nonce)
        private_directory(self.clients)

    def note(self, name, value):
        (self.evidence / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def ok(self, message):
        print("PASS " + message, flush=True)
        with open(self.evidence / "pass.txt", "a") as stream:
            stream.write(message + "\n")

    async def device(self, uid, name, rights="write"):
        actor = await pair(self.stack, self.operator, uid, self.clients / name, rights=rights)
        actor.uid = uid
        self.actors.append(actor)
        return actor

    async def call(self, actor, method, path, body=None, expected=(200,)):
        data = None if body is None else json.dumps(body).encode()
        raw, headers = await actor.request(method, path, data=data, headers={"Content-Type": "application/json"} if data else None,
                                           expected=expected)
        if headers.get("Cache-Control") != "no-store":
            raise RuntimeError("Fetch route answered without Cache-Control: no-store")
        return json.loads(raw) if raw else None

    async def submit(self, actor, urls, kind, height=None, expected=(202,)):
        body = {"urls": urls, "kind": kind, **({"height": height} if height else {})}
        return await self.call(actor, "POST", "/v1/fetch/jobs", body, expected=expected)

    async def jobs(self, actor):
        return (await self.call(actor, "GET", "/v1/fetch/jobs"))["jobs"]

    async def wait(self, actor, ids, states=TERMINAL, timeout=600, seen=None):
        deadline = time.monotonic() + timeout
        while True:
            rows = {row["id"]: row for row in await self.jobs(actor)}
            if seen is not None:
                for identity in ids:
                    if identity in rows:
                        seen.setdefault(identity, []).append(rows[identity]["state"]) if not seen.get(identity) or \
                            seen[identity][-1] != rows[identity]["state"] else None
            if all(identity in rows and rows[identity]["state"] in states for identity in ids):
                return [rows[identity] for identity in ids]
            if time.monotonic() > deadline:
                raise RuntimeError("Fetch jobs did not reach %s in time: %s" % (sorted(states), [rows.get(i, {}).get("state") for i in ids]))
            await asyncio.sleep(1)

    async def readback(self, actor, path, name):
        """GET the placed file through the gateway, keep it as evidence and return ffprobe's view."""
        target = self.evidence / name
        async with actor.session.get(self.stack.origin + href(path)) as response:
            if response.status != 200:
                raise RuntimeError("Placed file not readable through the gateway: %d" % response.status)
            digest, size = hashlib.sha256(), 0
            with open(target, "wb") as stream:
                async for chunk in response.content.iter_chunked(1 << 20):
                    stream.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(target)],
                               capture_output=True, text=True, timeout=120)
        (self.evidence / (name + ".ffprobe.json")).write_text(probe.stdout)
        return json.loads(probe.stdout), size, digest.hexdigest()

    def remember(self, actor, path):
        self.created.append((actor, path))

    async def delete(self, actor, path):
        body, _ = await actor.request("PROPFIND", href(path), headers={"Depth": "0"}, expected=(207, 404))
        etag = ET.fromstring(body).findtext(".//{DAV:}getetag") if body and b"multistatus" in body else None
        if etag:
            await actor.request("DELETE", href(path), headers={"If-Match": etag}, expected=(204,))

    def compose(self, *args, data=None):
        return self.stack.compose(*args, data=data)

    def spool_count(self):
        out = self.compose("exec", "-T", "access", "python", "-I", "-c",
                           "import os;print(len(os.listdir('%s/jobs')))" % SPOOL)
        return int(out.strip())

    async def spool_empty(self, timeout=90):
        deadline = time.monotonic() + timeout
        while self.spool_count():
            if time.monotonic() > deadline:
                raise RuntimeError("The spool still holds a run directory")
            await asyncio.sleep(1)

    async def cleanup(self):
        for actor, path in reversed(self.created):
            try:
                await self.delete(actor, path)
            except Exception as error:  # noqa: BLE001 - keep cleaning
                print("cleanup: could not delete one fixture file (%s)" % type(error).__name__, flush=True)
        for actor in self.actors:
            try:
                await self.call(actor, "POST", "/v1/fetch/jobs/clear", None, expected=(204, 403, 401))
            except Exception:  # noqa: BLE001
                pass
            await actor.close()
            try:
                await asyncio.to_thread(self.operator.revoke, actor.identity)
            except Exception:  # noqa: BLE001 - already revoked by a case
                pass
        await asyncio.to_thread(self.operator.reconcile)


def streams(probe):
    return [(s.get("codec_type"), s.get("codec_name"), s.get("height"), (s.get("disposition") or {}).get("attached_pic"))
            for s in probe["streams"]]


async def case_presets(run):
    alice = await run.device(FIXTURE_USERS[0], "alice-presets")
    reader = await run.device(FIXTURE_USERS[1], "bob-reader", rights="read")
    # Submit refusals: malformed, non-http, too many, read-grant device.
    for body, status in (({"urls": ["ftp://fetch-fixture/x"], "kind": "audio"}, 400), ({"urls": [], "kind": "audio"}, 400),
                         ({"urls": [item("song")], "kind": "video"}, 400), ({"urls": [item("song")], "kind": "video", "height": 480}, 400),
                         ({"urls": [item("song", "?n=%d" % n) for n in range(51)], "kind": "audio"}, 400)):
        await run.call(alice, "POST", "/v1/fetch/jobs", body, expected=(status,))
    await run.call(reader, "POST", "/v1/fetch/jobs", {"urls": [item("song")], "kind": "audio"}, expected=(403,))
    run.ok("submit refusals: non-http, empty, missing/invalid height and 51 links answer 400; a read-grant device answers 403")
    plan = [("audio", None, "song"), ("video", 1080, "song"), ("video", 720, "song"), ("video", 1080, "low"),
            ("audio", None, "vp9"), ("video", 1080, "vp9"), ("video", 1080, "fake"), ("video", 720, "long"),
            ("video", 1080, "big"), ("audio", None, "con"), ("video", 720, "escape"), ("audio", None, "private")]
    ids = []
    for kind, height, name in plan:
        url = "http://10.255.255.1/item.html" if name == "private" else item(name)
        ids.append((await run.submit(alice, [url], kind, height))["jobs"][0]["id"])
    seen = {}
    rows = await run.wait(alice, ids, timeout=900, seen=seen)
    run.note("presets-rows.json", rows)
    run.note("presets-states-seen.json", seen)
    result = dict(zip([p[2] + "-" + p[0] + str(p[1] or "") for p in plan], rows))
    for key, row in result.items():
        if row["state"] == "done":
            run.remember(alice, row["path"])
    audio = result["song-audio"]
    assert audio["state"] == "done" and audio["path"] == "Music/Fixture Song_ One.m4a", audio
    probe, _, _ = await run.readback(alice, audio["path"], "song-audio.m4a")
    tags = probe["format"].get("tags", {})
    assert "mp4" in probe["format"]["format_name"].split(",") and ("audio", "aac", None, 0) in streams(probe), streams(probe)
    assert all(s[0] == "audio" or s[3] == 1 for s in streams(probe)) and any(s[3] == 1 for s in streams(probe)), "cover art"
    assert tags.get("title") == "Fixture Song: One" and tags.get("artist") == "Fixture Artist", tags
    run.ok("audio preset: Music/Fixture Song_ One.m4a, MP4 container, one AAC stream, cover art as attached picture, "
           "title and artist tags (ffprobe in song-audio.m4a.ffprobe.json)")
    for key, height in (("song-video1080", 1080), ("song-video720", 720), ("low-video1080", 480)):
        row = result[key]
        assert row["state"] == "done" and row["path"].startswith("Videos/") and row["path"].endswith(".mp4") and row["height"] == height, row
        probe, _, _ = await run.readback(alice, row["path"], key + ".mp4")
        kinds = streams(probe)
        assert ("video", "h264", height, 0) in kinds and ("audio", "aac", None, 0) in kinds and len(kinds) == 2, kinds
    assert "at 480p; 1080p was not available" in result["low-video1080"]["message"], result["low-video1080"]
    run.ok("video presets: 1080p and 720p jobs give MP4 with H.264 at 1080/720 lines plus AAC; a source topping out at 480p "
           "gives 480p and the row says so (ffprobe in *-video*.mp4.ffprobe.json)")
    unsupported = "This link has no format the Downloader supports yet."
    for key in ("vp9-audio", "vp9-video1080"):
        assert result[key]["state"] == "rejected" and result[key]["message"] == unsupported and not result[key]["path"], result[key]
    assert result["fake-video1080"]["state"] == "rejected" and "promised format" in result["fake-video1080"]["message"]
    assert result["long-video720"]["state"] == "rejected" and "4 hours" in result["long-video720"]["message"]
    assert result["big-video1080"]["state"] == "rejected" and "8 GiB" in result["big-video1080"]["message"]
    assert result["private-audio"]["state"] == "rejected" and "private" in result["private-audio"]["message"]
    for key in ("vp9-audio", "vp9-video1080", "fake-video1080", "long-video720", "big-video1080", "private-audio"):
        assert "downloading" not in seen.get(result[key]["id"], []) or key == "fake-video1080", (key, seen.get(result[key]["id"]))
    run.ok("no fitting stream (VP9/Opus only) ends rejected with the stated sentence and no file; a source that lies about "
           "its codec fails the ffprobe check; 5-hour and ~11 GB metadata and a private address are rejected before download")
    assert result["con-audio"]["path"] == "Music/CON_.m4a", result["con-audio"]
    escape = result["escape-video720"]["path"]
    assert escape.count("/") == 1 and escape.startswith("Videos/") and ".." not in escape.split("/")[1][:2], escape
    run.ok("naming: a Windows device name becomes %s; a title built to escape becomes the single name %s"
           % (result["con-audio"]["path"], escape))
    await run.spool_empty()
    run.ok("spool holds no run directory after every job is terminal")


async def case_tenancy(run):
    alice = await run.device(FIXTURE_USERS[0], "alice-tenancy")
    bob = await run.device(FIXTURE_USERS[1], "bob-tenancy")
    first = (await run.submit(alice, [item("song")], "audio"))["jobs"][0]
    a1 = (await run.wait(alice, [first["id"]]))[0]
    second = (await run.submit(alice, [item("song", "?again=1")], "audio"))["jobs"][0]
    a2 = (await run.wait(alice, [second["id"]]))[0]
    theirs = (await run.submit(bob, [item("song")], "audio"))["jobs"][0]
    b1 = (await run.wait(bob, [theirs["id"]]))[0]
    for actor, row in ((alice, a1), (alice, a2), (bob, b1)):
        run.remember(actor, row["path"])
    run.note("tenancy-rows.json", {"alice": await run.jobs(alice), "bob": await run.jobs(bob)})
    assert (a1["path"], a2["path"], b1["path"]) == ("Music/Fixture Song_ One.m4a", "Music/Fixture Song_ One (2).m4a",
                                                    "Music/Fixture Song_ One.m4a"), (a1["path"], a2["path"], b1["path"])
    bob_ids = {row["id"] for row in await run.jobs(bob)}
    assert first["id"] not in bob_ids and second["id"] not in bob_ids and theirs["id"] in bob_ids
    await run.call(bob, "DELETE", "/v1/fetch/jobs/" + first["id"], expected=(404,))
    # Bob's Music holds his file only; Alice's two are in her own account.
    body, _ = await bob.request("PROPFIND", "/dav/Music/", headers={"Depth": "1"}, expected=(207,))
    names = {node.text.rstrip("/").rsplit("/", 1)[-1] for node in ET.fromstring(body).iter("{DAV:}href")}
    assert "Fixture%20Song_%20One%20%282%29.m4a" not in names and "Fixture%20Song_%20One%20(2).m4a" not in names, names
    run.ok("tenancy: each account sees only its own rows (another account's id answers 404) and files; a repeat gets ' (2)'; "
           "the other account's same title is its own 'Fixture Song_ One.m4a'")


async def case_playlist(run):
    alice = await run.device(FIXTURE_USERS[0], "alice-playlist")
    row = (await run.submit(alice, [SITE + "/list/3.rss"], "audio"))["jobs"][0]
    parent = (await run.wait(alice, [row["id"]]))[0]
    assert parent["state"] == "done" and parent["message"] == "Added 3 items from this playlist.", parent
    rows = await run.jobs(alice)
    children = [r for r in rows if r["id"] != row["id"] and r["submitted"] >= row["submitted"] and r["url"].startswith(SITE + "/item/song.html?i=")]
    done = await run.wait(alice, [r["id"] for r in children], timeout=600)
    paths = sorted(r["path"] for r in done)
    for path in paths:
        run.remember(alice, path)
    run.remember(alice, "Music/Fixture Mix_ Vol_1")
    assert paths == ["Music/Fixture Mix_ Vol_1/Fixture Song_ One (2).m4a", "Music/Fixture Mix_ Vol_1/Fixture Song_ One (3).m4a",
                     "Music/Fixture Mix_ Vol_1/Fixture Song_ One.m4a"], paths
    run.ok("playlist: a 3-item feed lands in Music/Fixture Mix_ Vol_1/ with ' (2)' and ' (3)' for its repeated title")
    big = (await run.submit(alice, [SITE + "/list/205.rss"], "audio"))["jobs"][0]
    parent = (await run.wait(alice, [big["id"]]))[0]
    queued = [r for r in await run.jobs(alice) if r["url"].startswith(SITE + "/item/song.html?i=") and r["state"] in ("waiting", "checking", "downloading", "placing")]
    run.note("playlist-cap.json", {"parent": parent, "unfinished_items": len(queued)})
    assert parent["message"] == "Added 200 items from this playlist; the rest were not added (at most 200).", parent
    assert 195 <= len(queued) <= 200, len(queued)
    for r in queued:
        await run.call(alice, "DELETE", "/v1/fetch/jobs/" + r["id"], expected=(204, 409))
    finished = await run.wait(alice, [r["id"] for r in queued], timeout=300)
    for r in finished:
        if r["state"] == "done":
            run.remember(alice, r["path"])
    await run.spool_empty()
    run.ok("playlist cap: a 205-item feed queues 200 items and its row says the rest were not added; cancelling them "
           "leaves the spool empty")


ISOLATION_TARGETS = ("nextcloud:80", "db:5432", "redis:6379", "access:8443")


async def case_isolation(run):
    addresses = {}
    for service in ("nextcloud", "db", "redis", "access"):
        out = run.stack.run(["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}",
                             run.stack.project + "-" + service + "-1"])
        addresses[service] = out.split()
    ports = {"nextcloud": 80, "db": 5432, "redis": 6379, "access": 8443}
    targets = list(ISOLATION_TARGETS) + ["%s:%d" % (ip, ports[s]) for s, ips in addresses.items() for ip in ips]
    gateway = run.compose("exec", "-T", "fetch", "python", "-I", "-c",
                          "import socket,struct\nfor l in open('/proc/net/route').readlines()[1:]:\n f=l.split()\n if f[1]=='00000000':"
                          "print(socket.inet_ntoa(struct.pack('<L',int(f[2],16))))").split()[0]
    hostlan = subprocess.run(["sh", "-c", "ip -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2"], capture_output=True,
                             text=True).stdout.strip()
    targets += [gateway + ":22", gateway + ":80", "10.0.2.2:22", "10.0.2.2:" + str(run.stack.port), hostlan + ":22",
                hostlan + ":" + str(run.stack.port), "192.168.0.1:80", "10.0.0.1:80", "169.254.169.254:80",
                # DNS is no exception here: Docker 29 queries the host's resolvers from the host's namespace.
                "100.100.100.100:53", "192.168.0.1:53", "10.0.2.3:53", gateway + ":53"]
    probe = ("import socket,sys,json\nout={}\nfor t in sys.argv[1:]:\n h,p=t.rsplit(':',1)\n s=socket.socket();s.settimeout(4)\n try:\n"
             "  s.connect((h,int(p)));out[t]='connected'\n except Exception as e:\n  out[t]=type(e).__name__\n finally:\n  s.close()\n"
             "print(json.dumps(out))")
    result = json.loads(run.compose("exec", "-T", "fetch", "python", "-I", "-c", probe, *targets).strip().splitlines()[-1])
    control = json.loads(run.compose("exec", "-T", "fetch", "python", "-I", "-c", probe, "fetch-fixture:8080").strip().splitlines()[-1])
    run.note("isolation-probes.json", {"targets": result, "fixture_control": control, "gateway": gateway, "host_lan": hostlan,
                                       "addresses": addresses})
    connected = sorted(target for target, outcome in result.items() if outcome == "connected")
    assert not connected, connected
    assert control["fetch-fixture:8080"] == "connected", control
    identity = run.compose("exec", "-T", "fetch", "sh", "-c", "id -u; grep CapEff /proc/self/status").split()
    assert identity[0] == "10003" and identity[-1] == "0000000000000000", identity
    run.ok("isolation: from inside the worker every connection to nextcloud, db, redis, access (by name and address), the "
           "stack host (bridge gateway, slirp host, LAN address) and private addresses fails; the fixture host connects; "
           "the worker runs as uid 10003 with no capabilities (isolation-probes.json)")


async def case_restart(run):
    alice = await run.device(FIXTURE_USERS[0], "alice-restart")
    for service in ("access", "fetch"):
        job = (await run.submit(alice, [item("slow", "?restart=" + service)], "video", 720))["jobs"][0]
        await run.wait(alice, [job["id"]], states={"downloading"}, timeout=120)
        await asyncio.sleep(5)
        run.compose("restart", "--timeout", "10", service)
        run.compose("up", "--detach", "--no-deps", "--wait", "--wait-timeout", "120", service)
        seen = {}
        row = (await run.wait(alice, [job["id"]], timeout=600, seen=seen))[0]
        run.note("restart-%s.json" % service, {"row": row, "states_after_restart": seen})
        assert row["state"] == "done", row
        assert "waiting" in seen[job["id"]] or service == "access", seen
        run.remember(alice, row["path"])
        run.ok("restart %s mid-download: the job returns to waiting once and completes (%s)" % (service, row["path"]))
    await run.spool_empty()


async def case_revoke(run):
    alice = await run.device(FIXTURE_USERS[0], "alice-revoke")
    job = (await run.submit(alice, [item("slow", "?revoke=1")], "video", 720))["jobs"][0]
    await run.wait(alice, [job["id"]], states={"downloading"}, timeout=120)
    await asyncio.sleep(3)
    await asyncio.to_thread(run.operator.revoke, alice.identity)
    other = await run.device(FIXTURE_USERS[0], "alice-revoke-reader")
    deadline = time.monotonic() + 60
    while True:
        row = next(r for r in await run.jobs(other) if r["id"] == job["id"])
        if row["state"] in TERMINAL or time.monotonic() > deadline:
            break
        await asyncio.sleep(1)
    run.note("revoke.json", row)
    assert row["state"] == "failed" and row["message"] == "This device no longer has access." and not row["path"], row
    await run.spool_empty()
    run.ok("revoking the submitting device mid-download fails the job with 'This device no longer has access.' and the "
           "spool keeps no staged file")


async def case_update(run):
    image = run.stack.project + "-fetch:unit1"
    volume = "anj-f22-update-" + run.nonce
    old, digest = OLD_YTDLP
    common = ["docker", "run", "--rm", "--memory", "512m", "--pids-limit", "128", "--label", "anj.owner=" + run.stack.project.split("-")[-1],
              "--read-only", "--tmpfs", "/tmp:size=64m", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
              "-v", volume + ":/var/lib/anj-fetch-tools"]
    seed = ("import hashlib,shutil,sys,urllib.request\nd=urllib.request.urlopen('https://github.com/yt-dlp/yt-dlp/releases/download/%s/yt-dlp',"
            "timeout=120).read()\nassert hashlib.sha256(d).hexdigest()=='%s'\nopen('/var/lib/anj-fetch-tools/yt-dlp','wb').write(d)" % (old, digest))
    show = ("import sys;sys.path.insert(0,'/opt/anj-fetch');import worker;t=worker.Tools();print(t.version());"
            "print(t.update(sys.argv[1]));print(t.version())")
    try:
        subprocess.run(["docker", "volume", "create", "--label", "anj.owner=" + run.stack.project.split("-")[-1], volume], check=True,
                       capture_output=True, timeout=60)
        subprocess.run([*common, image, "python", "-I", "-c", seed], check=True, capture_output=True, timeout=300)
        blocked = subprocess.run([*common, "--network", "none", image, "python", "-I", "-c", show, "blocked"], capture_output=True,
                                 text=True, timeout=600).stdout.split()
        advanced = subprocess.run([*common, image, "python", "-I", "-c", show, "test"], capture_output=True, text=True,
                                  timeout=600).stdout.split()
        run.note("update.json", {"baseline_on_volume": old, "blocked": blocked, "advanced": advanced})
        assert blocked[0] == old and blocked[-1] == old, blocked
        assert advanced[0] == old and advanced[-1] > old, advanced
        run.ok("yt-dlp update: a blocked update (no network) keeps %s working; the updater (stable channel) advances the "
               "volume's copy from %s to %s" % (old, old, advanced[-1]))
    finally:
        subprocess.run(["docker", "volume", "rm", "-f", volume], capture_output=True, timeout=60)


async def case_memory(run):
    """memory.peak counts page cache too; anon (process memory) is sampled once a second beside it."""
    alice = await run.device(FIXTURE_USERS[0], "alice-memory")
    run.compose("restart", "--timeout", "10", "fetch")
    run.compose("up", "--detach", "--no-deps", "--wait", "--wait-timeout", "120", "fetch")
    await asyncio.sleep(8)
    samples = []

    async def sample():
        while True:
            text = await asyncio.to_thread(run.compose, "exec", "-T", "fetch", "cat", "/sys/fs/cgroup/memory.stat")
            stat = dict(line.split() for line in text.splitlines() if line.count(" ") == 1)
            samples.append((int(stat.get("anon", 0)), int(stat.get("file", 0))))
            await asyncio.sleep(1)

    sampler = asyncio.ensure_future(sample())
    try:
        job = (await run.submit(alice, [item("long1080")], "video", 1080))["jobs"][0]
        row = (await run.wait(alice, [job["id"]], timeout=600))[0]
    finally:
        sampler.cancel()
    peak = int(run.compose("exec", "-T", "fetch", "cat", "/sys/fs/cgroup/memory.peak").strip())
    limit = run.compose("exec", "-T", "fetch", "cat", "/sys/fs/cgroup/memory.max").strip()
    anon = max(value[0] for value in samples)
    run.note("memory.json", {"row": row, "memory_peak_bytes": peak, "memory_max": limit, "anon_peak_sampled_bytes": anon,
                             "samples_anon_file": samples})
    assert row["state"] == "done", row
    run.remember(alice, row["path"])
    run.ok("memory: a 2-minute 1080p H.264+AAC download and merge: cgroup memory.peak %.1f MiB (page cache included), "
           "process memory (anon) peak %.1f MiB sampled each second; limit %s bytes" % (peak / 2 ** 20, anon / 2 ** 20, limit))


async def case_large(run, size=5 * 2 ** 30 + 123456789):
    alice = await run.device(FIXTURE_USERS[0], "alice-large")
    made = json.loads(run.compose("exec", "-T", "fetch-fixture", "python", "-I", "/site/fetch_site.py", "make-huge", str(size)).strip().splitlines()[-1])
    try:
        job = (await run.submit(alice, [item("huge")], "video", 720))["jobs"][0]
        staged = None
        deadline = time.monotonic() + 1800
        while True:
            row = next(r for r in await run.jobs(alice) if r["id"] == job["id"])
            if row["state"] == "placing" and staged is None:
                staged = run.compose("exec", "-T", "access", "sh", "-c",
                                     "for f in %s/jobs/*/media.mp4; do stat -c %%s \"$f\"; sha256sum \"$f\" | cut -c1-64; done" % SPOOL).split()
            if row["state"] in TERMINAL or time.monotonic() > deadline:
                break
            await asyncio.sleep(1)
        assert row["state"] == "done", row
        run.remember(alice, row["path"])
        _, got, sha = await run.readback(alice, row["path"], "huge.mp4")
        (run.evidence / "huge.mp4").unlink()
        await run.spool_empty()
        run.note("large.json", {"row": row, "fixture": made, "staged_while_placing": staged, "nextcloud_size": got, "nextcloud_sha256": sha})
        assert got == made["size"] and sha == made["sha256"], (got, sha, made)
        if staged:
            assert int(staged[0]) == got and staged[1] == sha, staged
        run.ok("large import: a %d-byte item reaches done; size and SHA-256 read back from Nextcloud equal the staged file%s; "
               "the spool is empty afterwards" % (got, "" if staged else " (fixture source; staged file not caught while placing)"))
    finally:
        run.compose("exec", "-T", "fetch-fixture", "rm", "-f", "/data/media/huge.mp4")


async def scenario(stack, evidence, cases):
    stack.check()
    run = Run(stack, evidence)
    try:
        for case in cases:
            await globals()["case_" + case](run)
    finally:
        await run.cleanup()
        print("Fixture files deleted and devices revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--case", default=",".join(CASES))
    args = parser.parse_args()
    cases = [case for case in args.case.split(",") if case]
    if set(cases) - set(CASES):
        parser.error("cases: " + ", ".join(CASES))
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence, cases))


if __name__ == "__main__":
    sys.exit(main())
