"""Loopback stand-in for ntfy.sh used by the host-routine tests (spec #21). Never a real topic.

    python3 tests/host_mock_ntfy.py <port-file> <log.jsonl>

Binds 127.0.0.1 on an ephemeral port, writes the port to <port-file>, and appends one JSON line per
POST (path, title, priority, body) to <log.jsonl>. Also serves canned JSON for GET paths found in
the optional ANJ_MOCK_ROUTES file ({"/path?query": {...}}) so the image check can be exercised
offline (Docker Hub and OSV stand-ins).
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sys


class Handler(BaseHTTPRequestHandler):
    routes = {}
    log_path = None

    def log_message(self, *args):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in self.routes:
            self._send(200, self.routes[self.path])
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        if self.path in self.routes:
            self._send(200, self.routes[self.path])
            return
        with open(self.log_path, "a") as stream:
            stream.write(json.dumps({"path": self.path, "title": self.headers.get("Title"),
                                     "priority": self.headers.get("Priority"), "body": body}) + "\n")
        self._send(200, {"id": "mock", "event": "message"})


def main():
    port_file, log_path = sys.argv[1], sys.argv[2]
    Handler.log_path = log_path
    if os.environ.get("ANJ_MOCK_ROUTES"):
        with open(os.environ["ANJ_MOCK_ROUTES"]) as stream:
            Handler.routes = json.load(stream)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file + ".tmp", "w") as stream:
        stream.write(str(server.server_address[1]))
    os.replace(port_file + ".tmp", port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
