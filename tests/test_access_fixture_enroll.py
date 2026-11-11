"""deploy/access_fixture.enroll_post: fixtures honour a short Retry-After once and never wait out a block.

Fixture code only (flag #91, #33): the gateway's limits are unchanged and nothing in it knows about tests.
"""

import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from deploy.access_fixture import ENROLL_MAX_WAIT, enroll_post


class EnrollPostTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.answers, self.calls, self.slept = [], 0, []
        app = web.Application()
        app.router.add_post("/v1/enroll", self.handle)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()

    async def handle(self, request):
        self.calls += 1
        status, headers = self.answers.pop(0)
        return web.json_response({"state": "pending"}, status=status, headers=headers)

    async def sleep(self, seconds):
        self.slept.append(seconds)

    async def post(self):
        return await enroll_post(self.client.session, str(self.client.make_url("/v1/enroll")), {"code": "x"}, sleep=self.sleep)

    async def test_a_plain_success_does_not_wait(self):
        self.answers = [(200, {})]
        self.assertEqual((200, {"state": "pending"}), await self.post())
        self.assertEqual(([], 1), (self.slept, self.calls))

    async def test_a_short_rate_limit_waits_the_stated_time_and_retries_once(self):
        self.answers = [(429, {"Retry-After": "37"}), (200, {})]
        self.assertEqual((200, {"state": "pending"}), await self.post())
        self.assertEqual(([37], 2), (self.slept, self.calls))

    async def test_a_second_429_is_returned_not_retried_again(self):
        self.answers = [(429, {"Retry-After": "5"}), (429, {"Retry-After": "5"})]
        self.assertEqual(429, (await self.post())[0])
        self.assertEqual(([5], 2), (self.slept, self.calls))

    async def test_a_block_is_not_waited_out(self):
        self.answers = [(429, {"Retry-After": "900"})]
        self.assertEqual(429, (await self.post())[0])
        self.assertEqual(([], 1), (self.slept, self.calls))
        self.assertLess(ENROLL_MAX_WAIT, 900)

    async def test_a_429_without_a_wait_is_not_retried(self):
        self.answers = [(429, {})]
        self.assertEqual(429, (await self.post())[0])
        self.assertEqual(([], 1), (self.slept, self.calls))
