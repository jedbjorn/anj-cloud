"""SC-041 F1: admin calls and the production ingress's idle limit, tied together.

Production HAProxy relays TLS untouched (TCP mode; decision #45): it closes a connection idle in
both directions for `timeout client`/`timeout server` and cannot see the path, so admin routes
cannot get a longer limit there than DAV. The gateway therefore answers every admin request within
OPERATION_HOLD (a longer action answers 202 and is polled), and the client's limits sit between:
hold < one request's limit < the ingress idle limit, and the whole action's deadline past the
gateway's wait on the console backend (BACKEND_TIMEOUT).
"""

from pathlib import Path
import re
import unittest

from services.access import console

ROOT = Path(__file__).resolve().parent.parent
HAPROXY = ROOT / "deploy" / "prod" / "haproxy.cfg.tmpl"
ADMIN_API = ROOT / "apps" / "client" / "lib" / "core" / "gateway" / "admin_api.dart"


def seconds(text):
    match = re.fullmatch(r"(\d+)(ms|s|m)?", text)
    value = int(match.group(1))
    return {"ms": value / 1000, "s": value, None: value / 1000, "m": value * 60}[match.group(2)]


def haproxy_timeouts():
    """{name: seconds} of every `timeout` line, and the section each is in."""
    found, section = {}, None
    for line in HAPROXY.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        words = line.split()
        if words[0] in ("global", "defaults", "frontend", "backend", "listen"):
            section = words[0]
            continue
        if words[0] == "timeout":
            found.setdefault(words[1], []).append((section, seconds(words[2])))
    return found


def dart_seconds(name):
    match = re.search(r"^const %s = Duration\(seconds: (\d+)\);" % name, ADMIN_API.read_text(), re.M)
    assert match, name
    return int(match.group(1))


class AdminTimeoutTests(unittest.TestCase):
    def test_every_route_keeps_the_one_ingress_idle_limit(self):
        timeouts = haproxy_timeouts()
        self.assertEqual([("defaults", 120)], timeouts["client"])
        self.assertEqual([("defaults", 120)], timeouts["server"])
        # No tunnel or per-backend override: in TCP mode it would replace both for every route.
        self.assertNotIn("tunnel", timeouts)
        self.assertEqual({"connect", "client", "server", "queue"}, set(timeouts))

    def test_admin_requests_are_answered_well_inside_it_and_actions_outlast_the_backend(self):
        idle = min(value for _section, value in haproxy_timeouts()["client"] + haproxy_timeouts()["server"])
        hold, backend = console.OPERATION_HOLD, console.BACKEND_TIMEOUT
        request, reply, deadline = (dart_seconds("adminRequestTimeout"), dart_seconds("adminReplyTimeout"),
                                    dart_seconds("adminActionDeadline"))
        self.assertLessEqual(2 * hold, idle, "a held request answers with a margin for TLS, queueing and slow links")
        self.assertLess(hold, request)
        self.assertLess(request, idle, "the client's own limit fires before the ingress would cut")
        self.assertLess(request, reply, "the worker's message arrives before the app gives up")
        self.assertGreater(deadline, backend + hold, "a backend call that ends at its limit is still collected")
        self.assertGreater(console.OPERATION_KEEP, deadline, "a result waits for the slowest client poll")


if __name__ == "__main__":
    unittest.main()
