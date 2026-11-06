#!/usr/bin/env python3
"""Prove supported per-device Nextcloud credentials using only fixed fixture users.

No gateway, certificate authority or household account is created. Tokens stay in
memory, are never printed, and are deleted by exact newly-created token ID.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET

from deploy.dev import FIXTURE_USERS, Stack, no_foreign_children


def token_from_output(output):
    marker = "app password:\n"
    if marker not in output:
        raise RuntimeError("Token creation returned an unexpected format; values withheld")
    token = output.split(marker, 1)[1].strip()
    if not re.fullmatch(r"[A-Za-z0-9]{72}", token):
        raise RuntimeError("Token creation returned an unexpected credential; values withheld")
    return token


class Client:
    def __init__(self, stack, uid, token):
        self.stack, self.uid, self.token = stack, uid, token

    def response(self, method, path, *, body=None, headers=None):
        headers = dict(headers or {})
        headers["Authorization"] = "Basic " + base64.b64encode(f"{self.uid}:{self.token}".encode()).decode()
        return self.stack.backend_http(method, path, data=body, headers=headers)

    def request(self, method, path, *, body=None, headers=None, expected=(200,)):
        status, content = self.response(method, path, body=body, headers=headers)
        if status not in expected:
            raise RuntimeError(f"Synthetic {method} returned {status}; expected {expected}; values withheld")
        return content

    def identity(self, expected_uid):
        raw = self.request("GET", "/ocs/v2.php/cloud/user?format=json", headers={"OCS-APIRequest": "true"})
        result = json.loads(raw)["ocs"]
        if result["meta"]["statuscode"] not in (100, 200) or result["data"]["id"] != expected_uid:
            raise RuntimeError("Backend credential account does not match invitation account")

    def dav(self, method, path, *, body=None, expected=(200,), headers=None):
        return self.request(method, "/remote.php/dav/files/" + self.uid + "/" + urllib.parse.quote(path, safe="/"),
                            body=body, expected=expected, headers=headers)

    def shares(self, method, suffix="", body=None):
        raw = self.request(method, "/ocs/v2.php/apps/files_sharing/api/v1/shares" + suffix + "?format=json",
                           body=body, headers={"OCS-APIRequest": "true", "Content-Type": "application/x-www-form-urlencoded"})
        result = json.loads(raw)["ocs"]
        if result["meta"]["statuscode"] not in (100, 200):
            raise RuntimeError("Synthetic share operation failed; response withheld")
        return result["data"]


def token_rows(stack, uid):
    rows = json.loads(stack.occ("user:auth-tokens:list", "--output=json", "--", uid))
    if not isinstance(rows, list):
        raise RuntimeError("Unexpected token-list format; values withheld")
    return rows


def run(stack):
    stack.check()
    nonce = secrets.token_hex(8)
    folder = "anj-token-spike-" + nonce
    created_names = []
    clients = []
    alice, bob = FIXTURE_USERS
    try:
        for uid, device in ((alice, "alice-a"), (alice, "alice-b"), (bob, "bob-a")):
            name = f"anj-spike-{nonce}-{device}"
            created_names.append((uid, name))  # Register before issuance so parse failures still clean up.
            output = stack.occ("user:auth-tokens:add", "--no-interaction", "--name", name, "--", uid)
            client = Client(stack, uid, token_from_output(output))
            client.identity(uid)
            clients.append(client)
        a1, a2, b1 = clients
        print("PASS three uniquely named noninteractive app tokens; canonical UIDs match fixture owners", flush=True)
        try:
            b1.identity(alice)
        except RuntimeError:
            pass
        else:
            raise RuntimeError("Wrong-account credential was accepted")
        for client in (a1, b1):
            client.dav("MKCOL", folder, expected=(201,))
        payload = b"anj-cloud app-token synthetic bytes\n" * 2048
        private = folder + "/private.txt"
        shared = folder + "/read-only.txt"
        a1.dav("PUT", private, body=payload, expected=(201,))
        a1.dav("PUT", shared, body=payload, expected=(201,))
        b1.dav("PUT", private, body=b"bob-only\n", expected=(201,))
        if hashlib.sha256(a2.dav("GET", private)).digest() != hashlib.sha256(payload).digest():
            raise RuntimeError("Same-account second-device download hash differs")
        listing = a1.dav("PROPFIND", folder + "/", headers={"Depth": "1"}, expected=(207,))
        if b"private.txt" not in listing or b"read-only.txt" not in listing:
            raise RuntimeError("Owner token could not list its own fixture files")
        if b1.dav("GET", private) != b"bob-only\n":
            raise RuntimeError("Separate account namespace differs")
        foreign = "/remote.php/dav/files/" + alice + "/"
        b1.request("GET", foreign + private, expected=(403, 404))
        b1.request("PROPFIND", foreign + folder + "/", headers={"Depth": "1"}, expected=(403, 404))
        status, content = stack.backend_http("PROPFIND", foreign, headers={
            "Authorization": "Basic " + base64.b64encode(f"{bob}:{b1.token}".encode()).decode(), "Depth": "1"})
        no_foreign_children(status, content, foreign)
        b1.dav("GET", shared, expected=(404,))
        print("PASS app-token DAV create/upload/download/list; wrong-account binding and private access denied", flush=True)
        conditional = folder + "/conditional.txt"
        a1.dav("PUT", conditional, body=b"conditional baseline\n", expected=(201,))
        raw = a1.dav("PROPFIND", conditional, headers={"Depth": "0"}, expected=(207,))
        etag = ET.fromstring(raw).findtext(".//{DAV:}getetag")
        if not etag:
            raise RuntimeError("DAV did not return an ETag for conditional operations")
        a1.dav("PUT", conditional, body=b"must not replace", headers={"If-Match": '"stale-fixture-etag"'}, expected=(412,))
        a1.dav("DELETE", conditional, headers={"If-Match": '"stale-fixture-etag"'}, expected=(412,))
        a1.dav("DELETE", conditional, headers={"If-Match": etag}, expected=(204,))
        a1.dav("GET", conditional, expected=(404,))
        nested = folder + "/nested"
        a1.dav("MKCOL", nested, expected=(201,))
        a1.dav("PUT", nested + "/move-source.txt", body=b"move fixture\n", expected=(201,))
        target_path = nested + "/move-target.txt"
        a1.dav("MOVE", nested + "/move-source.txt", headers={
            "Destination": "http://127.0.0.1" + "/remote.php/dav/files/" + alice + "/" + target_path,
            "Overwrite": "F"}, expected=(201,))
        if a2.dav("GET", target_path) != b"move fixture\n":
            raise RuntimeError("Moved fixture bytes differ")
        a1.dav("DELETE", nested, expected=(204,))
        print("PASS stale conditional PUT/DELETE denied; matching DELETE, nested-folder MOVE and recursive DELETE work", flush=True)
        share = a1.shares("POST", body=urllib.parse.urlencode({
            "path": "/" + shared, "shareType": "0", "shareWith": bob, "permissions": "1"}).encode())
        target = share["file_target"].lstrip("/")
        if b1.dav("GET", target) != payload:
            raise RuntimeError("Read-only shared app-token download differs")
        b1.dav("PUT", target, body=b"must not overwrite", expected=(403,))
        if a2.dav("GET", shared) != payload:
            raise RuntimeError("Denied shared write changed owner bytes")
        a1.shares("DELETE", "/" + str(share["id"]))
        b1.dav("GET", target, expected=(404,))
        print("PASS explicit permissions=1 share reads, denies writes, preserves bytes and revokes", flush=True)
        first = next(row for row in token_rows(stack, alice) if row["name"] == created_names[0][1])
        stack.occ("user:auth-tokens:delete", "--", alice, str(first["id"]))
        start = time.monotonic()
        while True:
            status, _ = a1.response("GET", "/ocs/v2.php/cloud/user?format=json", headers={"OCS-APIRequest": "true"})
            elapsed = time.monotonic() - start
            if status == 401:
                break
            if status != 200 or elapsed >= 30:
                raise RuntimeError(f"Deleted token was not denied within spike observation window; HTTP {status}; values withheld")
            time.sleep(1)
        if a2.dav("GET", private) != payload or b1.dav("GET", private) != b"bob-only\n":
            raise RuntimeError("Deleting one device token affected another device")
        print(f"PASS deleted token denied new authentication after {elapsed:.2f}s; other same-user/cross-user tokens still work", flush=True)
    finally:
        cleanup_failed = False
        for uid in FIXTURE_USERS:
            try:
                stack.dav("DELETE", uid, folder, expected=(204, 404))
            except (RuntimeError, OSError):
                cleanup_failed = True
        for uid, name in created_names:
            try:
                for row in token_rows(stack, uid):
                    if row["name"] == name:
                        stack.occ("user:auth-tokens:delete", "--", uid, str(row["id"]))
            except (RuntimeError, OSError):
                cleanup_failed = True
        for uid, name in created_names:
            if any(row["name"] == name for row in token_rows(stack, uid)):
                cleanup_failed = True
        if cleanup_failed:
            raise RuntimeError(f"Spike cleanup needs operator attention; synthetic run ID {nonce}; credentials withheld")
        print("PASS exact new tokens and synthetic folders cleaned; fixture accounts and prior tokens preserved", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="anj-cloud-dev")
    parser.add_argument("--port", type=int, default=os.environ.get("SC_DEV_PORT", "8834"))
    args = parser.parse_args()
    try:
        run(Stack(args.project, args.port))
    except RuntimeError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    except Exception:
        print("ERROR token prerequisite spike failed; response/credential details withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
