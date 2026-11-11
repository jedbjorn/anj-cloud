"""Overwrites inside the previous write's second (flag SC-103).

Nextcloud 33 keeps a file's ETag when it is overwritten within the whole second of its previous
write: its cache scanner reuses the stored ETag while the storage mtime is unchanged. The fake
backend here does the same, on a clock the test controls; the gateway must still hand every
overwrite a new version and refuse the stale one.
"""

from email.utils import formatdate
import tempfile
from types import SimpleNamespace
import unittest

from aiohttp import ClientSession, DummyCookieJar, web
from aiohttp.test_utils import TestServer

from services.access.mutations import SETTLE_MARGIN, Mutations, http_seconds, settle_delay
from services.access.registry import Registry
from test_files_added import activate

START = 1_800_000_000.25


class SameSecondNextcloud:
    """One-second mtimes; an overwrite in the stored mtime's second keeps the stored ETag."""

    def __init__(self):
        self.now = START
        self.items = {}  # path -> [etag, mtime second, bytes]
        self.serial = 0
        self.report_modified = True
        self.report_date = True
        self.server = None

    def headers(self):
        return {"Date": formatdate(int(self.now), usegmt=True)} if self.report_date else {"Date": "unreadable"}

    async def handle(self, request):
        path = request.path.split("/anj-cloud/", 1)[1]
        item = self.items.get(path)
        if request.method == "PROPFIND":
            if item is None:
                return web.Response(status=404, headers=self.headers())
            modified = ("<d:getlastmodified>" + formatdate(item[1], usegmt=True) + "</d:getlastmodified>"
                        if self.report_modified else "")
            body = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response>'
                    '<d:href>/x</d:href><d:propstat><d:prop><d:getetag>' + item[0] + '</d:getetag>' + modified +
                    '<d:resourcetype/><oc:fileid>7</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
                    '</d:propstat></d:response></d:multistatus>')
            return web.Response(status=207, body=body.encode(), headers=self.headers())
        if request.method == "PUT":
            data = await request.read()
            second = int(self.now)
            if item is not None and request.headers.get("If-Match") != item[0]:
                return web.Response(status=412, headers=self.headers())
            if item is None or item[1] != second:
                self.serial += 1
                etag = '"v%d"' % self.serial
            else:
                etag = item[0]
            self.items[path] = [etag, second, data]
            return web.Response(status=204 if item else 201, headers={**self.headers(), "ETag": etag,
                                                                      "OC-FileId": "00000007ocinstance1"})
        return web.Response(status=405)

    async def start(self):
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.server = TestServer(app)
        await self.server.start_server()
        return str(self.server.make_url("")).rstrip("/")


class SettleDelayTests(unittest.TestCase):
    def test_only_a_write_in_the_backends_current_second_waits(self):
        self.assertEqual(0, settle_delay(99, 100))
        self.assertEqual(1 + SETTLE_MARGIN, settle_delay(100, 100))
        self.assertEqual(2 + SETTLE_MARGIN, settle_delay(101, 100))
        self.assertEqual(0, settle_delay(5000, 100))  # Dated ahead: a write now cannot share its second.

    def test_an_unreadable_time_is_treated_as_this_second(self):
        self.assertEqual(1 + SETTLE_MARGIN, settle_delay(None, 100))
        self.assertEqual(1 + SETTLE_MARGIN, settle_delay(100, None))

    def test_http_dates(self):
        self.assertEqual(1_800_000_000, http_seconds(formatdate(1_800_000_000, usegmt=True)))
        for bad in (None, "", "yesterday"):
            self.assertIsNone(http_seconds(bad), bad)


class SameSecondOverwriteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.registry = Registry(self.temporary.name, clock=lambda: 1_800_000_000.0)
        self.backend = SameSecondNextcloud()
        base = await self.backend.start()
        self.session = ClientSession(cookie_jar=DummyCookieJar())
        gateway = SimpleNamespace(registry=self.registry, session=self.session, backend=base,
                                  origin="https://127.0.0.1:8834", throttle=0)
        self.mutations = Mutations(gateway)
        self.device = activate(self.registry)
        self.waits = []

        async def sleep(seconds):
            self.waits.append(seconds)
            self.backend.now += seconds
        self.mutations.sleep = sleep

    async def asyncTearDown(self):
        await self.session.close()
        await self.backend.server.close()
        self.registry.db.close()
        self.temporary.cleanup()

    async def put(self, body, **headers):
        async def chunks(_):
            yield body
        request = SimpleNamespace(method="PUT", content_length=len(body), content=SimpleNamespace(iter_chunked=chunks),
                                  headers=headers, can_read_body=False)
        return await self.mutations.run(request, self.device, "Documents/a.txt", {**headers, "Content-Length": str(len(body))})

    async def test_two_overwrites_in_one_second_get_different_versions(self):
        created = await self.put(b"written on B", **{"If-None-Match": "*"})
        self.assertEqual((201, []), (created.status, self.waits))
        first = created.headers["ETag"]
        # Same second, as two devices saving one after the other do.
        second = await self.put(b"edited on A", **{"If-Match": first})
        self.assertEqual(204, second.status)
        self.assertNotEqual(first, second.headers["ETag"])
        self.assertEqual(b"edited on A", self.backend.items["Documents/a.txt"][2])
        third = await self.put(b"edited again", **{"If-Match": second.headers["ETag"]})
        self.assertEqual(3, len({first, second.headers["ETag"], third.headers["ETag"]}))
        self.assertEqual([1 + SETTLE_MARGIN] * 2, self.waits)
        self.assertEqual(0, self.mutations.unchanged_versions)
        # A device still holding the first version can no longer overwrite the later ones.
        with self.assertRaises(web.HTTPPreconditionFailed):
            await self.put(b"stale device", **{"If-Match": first})
        self.assertEqual(b"edited again", self.backend.items["Documents/a.txt"][2])
        self.assertTrue(self.registry.mutation_ready())

    async def test_an_overwrite_in_a_later_second_does_not_wait(self):
        created = await self.put(b"one", **{"If-None-Match": "*"})
        self.backend.now += 1
        changed = await self.put(b"two", **{"If-Match": created.headers["ETag"]})
        self.assertEqual((204, []), (changed.status, self.waits))
        self.assertNotEqual(created.headers["ETag"], changed.headers["ETag"])

    async def test_a_backend_that_reports_no_times_still_gets_a_new_version(self):
        for hidden in ("report_modified", "report_date"):
            with self.subTest(hidden):
                self.backend.items.clear()
                self.waits.clear()
                self.backend.report_modified = self.backend.report_date = True
                created = await self.put(b"one", **{"If-None-Match": "*"})
                setattr(self.backend, hidden, False)
                changed = await self.put(b"two", **{"If-Match": created.headers["ETag"]})
                self.assertEqual([1 + SETTLE_MARGIN], self.waits)
                self.assertNotEqual(created.headers["ETag"], changed.headers["ETag"])

    async def test_a_version_that_did_not_move_is_counted_and_logged(self):
        created = await self.put(b"one", **{"If-None-Match": "*"})

        async def no_wait(seconds):
            self.waits.append(seconds)
        self.mutations.sleep = no_wait
        with self.assertLogs("services.access.mutations", "WARNING") as logged:
            kept = await self.put(b"two", **{"If-Match": created.headers["ETag"]})
        self.assertEqual((204, created.headers["ETag"]), (kept.status, kept.headers["ETag"]))
        self.assertEqual(1, self.mutations.unchanged_versions)
        self.assertNotIn("a.txt", logged.output[0])


if __name__ == "__main__":
    unittest.main()
