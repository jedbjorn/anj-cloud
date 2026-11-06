"""Filename data remains distinct from URI delimiters at each protocol layer."""

import unittest
from urllib.parse import unquote
from xml.etree import ElementTree as ET

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

from services.access.protocol import (Rejection, backend_root, canonical_path,
                                      encode_filename_path, gateway_reference,
                                      move_destination, rewrite_multistatus)

ORIGIN = "https://127.0.0.1:8834"
BACKEND = "http://nextcloud"


class FilenameTests(unittest.TestCase):
    def test_encoded_filename_characters_roundtrip_without_uri_delimiters(self):
        cases = {
            "Documents/report #1?.txt": "Documents/report%20%231%3F.txt",
            "Documents/雪 #? %.txt": "Documents/%E9%9B%AA%20%23%3F%20%25.txt",
            "Documents/100% done.txt": "Documents/100%25%20done.txt",
            "Documents/100%.txt": "Documents/100%25.txt",
            "Documents/hash#?/child.txt": "Documents/hash%23%3F/child.txt",
        }
        for decoded, encoded in cases.items():
            with self.subTest(filename=decoded):
                self.assertEqual(encoded, encode_filename_path(decoded))
                self.assertEqual(encoded, canonical_path(encoded))
                self.assertEqual(decoded, unquote(canonical_path(encoded)))
                self.assertEqual(encoded, move_destination(ORIGIN + "/dav/" + encoded, ORIGIN))
                self.assertEqual(ORIGIN + "/dav/" + encoded, gateway_reference(backend_root("alice") + encoded, "alice", ORIGIN, BACKEND))

    def test_raw_delimiters_separators_and_traversal_stay_rejected(self):
        for raw in ("a?x=1", "a?", "a#fragment", "a#", "../secret", "%2e%2E/secret", "a%2fb", "a%5Cb", "a%00", "a//b", "/absolute", "a%", "a%FF"):
            with self.subTest(raw=raw), self.assertRaises((ValueError, UnicodeError)):
                canonical_path(raw)
        for suffix in ("?", "?x=1", "#", "#fragment"):
            with self.subTest(suffix=suffix):
                with self.assertRaises(Rejection):
                    move_destination(ORIGIN + "/dav/a" + suffix, ORIGIN)
                with self.assertRaises(Rejection):
                    gateway_reference(backend_root("alice") + "a" + suffix, "alice", ORIGIN, BACKEND)
        for decoded in ("../secret", "a/../secret", "a\\b", "a\x00", "a\n"):
            with self.subTest(decoded=decoded), self.assertRaises(Rejection):
                encode_filename_path(decoded)

    def test_literal_percent_hex_is_filename_data_after_exactly_one_decode(self):
        for literal in ("a%20.txt", "%2e%2e", "%2f.txt", "%5c.txt", "%00.txt", "%23.txt", "%3f.txt", "%25.txt", "%FF.txt", "%252e.txt"):
            with self.subTest(literal=literal):
                encoded = "Documents/" + literal.replace("%", "%25")
                self.assertEqual(encoded, encode_filename_path("Documents/" + literal))
                self.assertEqual(encoded, canonical_path(encoded))
                self.assertEqual("Documents/" + literal, unquote(canonical_path(encoded)))
                self.assertEqual(encoded, move_destination(ORIGIN + "/dav/" + encoded, ORIGIN))
                self.assertEqual(ORIGIN + "/dav/" + encoded, gateway_reference(backend_root("alice") + encoded, "alice", ORIGIN, BACKEND))

    def test_multistatus_rewrites_encoded_data_and_preserves_confinement(self):
        href = backend_root("alice") + "Documents/a%23b%3Fc%252f.txt"
        body = f'<d:multistatus xmlns:d="DAV:"><d:response><d:href>{href}</d:href></d:response></d:multistatus>'.encode()
        result = ET.fromstring(rewrite_multistatus(body, "alice", ORIGIN, BACKEND))
        self.assertEqual(ORIGIN + "/dav/Documents/a%23b%3Fc%252f.txt", result.findtext(".//{DAV:}href"))
        for foreign in (href.replace("/alice/", "/bob/"), href.replace("/anj-cloud/", "/outside/"), "https://foreign.invalid" + href):
            with self.subTest(foreign=foreign), self.assertRaises(Rejection):
                gateway_reference(foreign, "alice", ORIGIN, BACKEND)


class FilenameWireTests(unittest.IsolatedAsyncioTestCase):
    async def test_aiohttp_backend_wire_keeps_encoded_names_out_of_query_and_destination(self):
        captured = []
        async def backend(request):
            captured.append((request.raw_path, request.path, request.query_string, request.headers.get("Destination")))
            return web.Response(status=204)
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", backend)
        server = TestServer(app)
        await server.start_server()
        try:
            relative = canonical_path("Documents/a%23b%3Fc%252f.txt")
            destination = move_destination(ORIGIN + "/dav/Documents/new%3F%23%25.txt", ORIGIN)
            async with ClientSession() as session:
                async with session.request("MOVE", str(server.make_url(backend_root("alice") + relative)),
                                           headers={"Destination": str(server.make_url(backend_root("alice") + destination))}) as response:
                    self.assertEqual(204, response.status)
                    await response.read()
            self.assertEqual(1, len(captured))
            raw, decoded, query, target = captured[0]
            self.assertEqual(backend_root("alice") + relative, raw)
            self.assertEqual(backend_root("alice") + "Documents/a#b?c%2f.txt", decoded)
            self.assertEqual("", query)
            self.assertEqual(str(server.make_url(backend_root("alice") + destination)), target)
        finally:
            await server.close()
