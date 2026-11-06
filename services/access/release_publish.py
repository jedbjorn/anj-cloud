"""Private socket client for a release publish (spec #28 G1), run through the operator's Compose
authority: `python -m access.release_publish TARGET MANIFEST_JSON < package`.

The package is streamed from stdin to the gateway in chunks; it is never held in memory. The
gateway checks it against the manifest and stores it; this helper only relays.
"""

import asyncio
import json
import sys

from aiohttp import ClientSession, ClientTimeout, UnixConnector

from .privileges import drop
from .releases import CHUNK, MANIFEST_HEADER

SOCKET = "/var/lib/anj/operator.sock"


async def publish(target, manifest, source, socket=SOCKET):
    loop = asyncio.get_running_loop()

    async def body():
        while chunk := await loop.run_in_executor(None, source.read, CHUNK):
            yield chunk

    async with ClientSession(connector=UnixConnector(path=socket), timeout=ClientTimeout(total=None, sock_read=300)) as session:
        async with session.put("http://operator/operator/release/" + target, data=body(),
                               headers={MANIFEST_HEADER: json.dumps(manifest, separators=(",", ":"))}) as response:
            return response.status, await response.json()


async def main(argv):
    drop()
    if len(argv) != 2 or len(argv[1]) > 4096:
        raise ValueError("usage: release_publish TARGET MANIFEST_JSON < package")
    status, result = await publish(argv[0], json.loads(argv[1]), sys.stdin.buffer)
    print(json.dumps(result))
    return 0 if status == 200 else 1


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main(sys.argv[1:])))
    except Exception:
        print('{"error":"Operator connection failed"}')
        sys.exit(1)
