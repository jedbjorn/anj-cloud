"""Bounded synthetic filename qualification on the owned Nextcloud/gateway stack."""

import argparse
import asyncio
import os
from pathlib import Path
import secrets
import tempfile
from urllib.parse import quote, unquote
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair, resolved_share_path, share_hrefs
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack

NAMES = ["a#b?c%.txt", "a%20.txt", "%2e%2e", "%2f.txt", "%5c.txt", "%00.txt",
         "%23.txt", "%3f.txt", "%25.txt", "%FF.txt", "%252e.txt", "%2E%2E", "a b.txt", "雪.txt"]


def payload(index):
    return ("exact-name-" + str(index)).encode()


async def raw_get_status(actor, target):
    # General URI libraries discard an empty ?/# delimiter before transmission.
    reader, writer = await asyncio.open_connection("127.0.0.1", actor.stack.port, ssl=actor.context())
    try:
        writer.write(("GET " + target + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").encode())
        await writer.drain()
        status = int((await asyncio.wait_for(reader.readline(), 10)).split()[1])
        await asyncio.wait_for(reader.read(), 10)
        return status
    finally:
        writer.close()
        await writer.wait_closed()


async def gateway_proof(stack, operator):
    actors, shares = [], []
    created = False
    root = "filename-proof-" + secrets.token_hex(6)
    with tempfile.TemporaryDirectory(prefix="filename-clients-", dir=stack.local) as local:
        try:
            owner = await pair(stack, operator, FIXTURE_USERS[0], Path(local) / "alice")
            actors.append(owner)
            recipient = await pair(stack, operator, FIXTURE_USERS[1], Path(local) / "bob")
            actors.append(recipient)
            await owner.request("MKCOL", "/dav/" + root, headers={"If-None-Match": "*"}, expected=(201,))
            created = True
            folder = root + "/dir#?%2e%2e"
            await owner.request("MKCOL", "/dav/" + quote(folder, safe="/"), headers={"If-None-Match": "*"}, expected=(201,))
            for index, name in enumerate(NAMES):
                path = quote(folder + "/" + name, safe="/")
                await owner.request("PUT", "/dav/" + path, data=payload(index), headers={"If-None-Match": "*"}, expected=(201,))
                assert (await owner.request("GET", "/dav/" + path))[0] == payload(index)
                await recipient.request("GET", "/dav/" + path, expected=(404,))
            body, _ = await owner.request("PROPFIND", "/dav/" + quote(folder, safe="/") + "/", headers={"Depth": "1"}, expected=(207,))
            names = {unquote(node.text).rsplit("/", 1)[-1] for node in ET.fromstring(body).iter("{DAV:}href") if not node.text.endswith("/")}
            assert names == set(NAMES)
            for index, name in enumerate(NAMES):
                path = quote(folder + "/" + name, safe="/")
                target = quote(folder + "/moved-" + name, safe="/")
                await owner.request("MOVE", "/dav/" + path, headers={"If-Match": await owner.etag(path), "Overwrite": "F",
                                    "Destination": stack.origin + "/dav/" + target}, expected=(201,))
                assert (await owner.request("GET", "/dav/" + target))[0] == payload(index)
                await owner.request("GET", "/dav/" + path, expected=(404,))
            print(f"PASS gateway exact PUT/GET/Depth1/MOVE and account isolation: {len(NAMES)} names", flush=True)
            for name in (NAMES[0], NAMES[1], NAMES[3]):
                before = await share_hrefs(recipient)
                share = await asyncio.to_thread(operator.call, "share", device_id=owner.identity,
                                                path=folder + "/moved-" + name, recipient=FIXTURE_USERS[1])
                shares.append(share["share_id"])
                target = await resolved_share_path(recipient, before)
                assert (await recipient.request("GET", target))[0] == payload(NAMES.index(name))
                await asyncio.to_thread(operator.call, "unshare", device_id=owner.identity, share_id=share["share_id"])
                shares.remove(share["share_id"])
                await recipient.request("GET", target, expected=(404,))
            print("PASS decoded share paths and confined incoming hrefs for #/?/percent/percent-hex", flush=True)
            for bad in ("%2e%2e/x", "a%2fb", "a%5cb", "a%00", "a?x=1", "a%FF", "a%"):
                await owner.request("GET", "/dav/" + root + "/" + bad, expected=(400,))
            for raw in ("a?", "a#", "a#fragment"):
                assert await raw_get_status(owner, "/dav/" + root + "/" + raw) == 400
            path = quote(folder + "/moved-" + NAMES[0], safe="/")
            for target in (stack.origin + "/dav/a?", stack.origin + "/dav/%2e%2e/outside",
                           stack.origin + "/dav/a%2fb", "https://foreign.invalid/dav/a"):
                await owner.request("MOVE", "/dav/" + path, headers={"If-Match": await owner.etag(path), "Overwrite": "F",
                                    "Destination": target}, expected=(400,))
            assert (await owner.request("GET", "/dav/" + path))[0] == payload(0)
            print("PASS raw queries/separators/traversal and foreign MOVE denied; sentinel unchanged", flush=True)
        finally:
            try:
                for share in shares:
                    await asyncio.to_thread(operator.call, "unshare", device_id=actors[0].identity, share_id=share)
                if created:
                    await actors[0].request("DELETE", "/dav/" + root, headers={"If-Match": await actors[0].etag(root)}, expected=(204,))
            finally:
                for actor in actors:
                    try:
                        await actor.close()
                    finally:
                        await asyncio.to_thread(operator.revoke, actor.identity)
    stack.check()
    assert operator.call("activity")["write_fence"] == "clear"
    print("PASS nonce folder/shares removed; two device tokens revoked; fence clear", flush=True)


def backend_proof(stack, operator):
    """Resolve URI ambiguity against the pinned backend while gateway writes are fenced."""
    uid = FIXTURE_USERS[0]
    stack.check()
    operator.quiesce()
    root = "anj-cloud/filename-backend-" + secrets.token_hex(6)
    created = False
    try:
        stack.dav("MKCOL", uid, root, expected=(201,))
        created = True
        for index, name in enumerate(NAMES):
            path = root + "/" + name
            stack.dav("PUT", uid, path, data=payload(index), headers={"If-None-Match": "*", "Content-Type": "application/octet-stream"}, expected=(201,))
            assert stack.dav("GET", uid, path) == payload(index)
        body = stack.dav("PROPFIND", uid, root + "/", headers={"Depth": "1"}, expected=(207,))
        hrefs = {unquote(node.text) for node in ET.fromstring(body).iter("{DAV:}href")}
        prefix = "/remote.php/dav/files/" + uid + "/" + root + "/"
        assert hrefs == {prefix + name for name in NAMES} | {prefix}
        for index, name in enumerate(NAMES):
            target = root + "/moved-" + name
            destination = "http://nextcloud/remote.php/dav/files/" + uid + "/" + quote(target, safe="/")
            stack.dav("MOVE", uid, root + "/" + name, headers={"Destination": destination, "Overwrite": "F"}, expected=(201,))
            assert stack.dav("GET", uid, target) == payload(index)
        print(f"PASS pinned backend distinct names, exact bytes/listing/MOVE: {len(NAMES)} names", flush=True)
    finally:
        if created:
            stack.dav("DELETE", uid, root, expected=(204,))
        # A cleanup failure deliberately leaves writes fenced for scoped recovery.
        operator.recover_writes()
        stack.check()
        print("PASS backend nonce folder removed and write fence clear", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="anj-cloud-dev")
    parser.add_argument("--port", type=int, default=os.environ.get("SC_DEV_PORT", "8834"))
    parser.add_argument("--backend-only", action="store_true", help="Qualify pinned backend before relaxing gateway URI rules")
    args = parser.parse_args()
    stack = Stack(args.project, args.port)
    operator = Operator(stack)
    backend_proof(stack, operator)
    if not args.backend_only:
        asyncio.run(gateway_proof(stack, operator))


if __name__ == "__main__":
    main()
