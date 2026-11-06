"""Private socket client invoked through the local operator's Compose authority."""

import asyncio
import json
import sys

from aiohttp import ClientSession, UnixConnector

from .privileges import drop


async def main():
    drop()
    body = sys.stdin.read(16385)
    if len(body) > 16384:
        raise ValueError("Operator envelope too large")
    async with ClientSession(connector=UnixConnector(path="/var/lib/anj/operator.sock")) as session:
        async with session.post("http://operator/operator", json=json.loads(body)) as response:
            result = await response.json()
            if response.status != 200:
                print(json.dumps(result))
                return 1
            print(json.dumps(result))
            return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception:
        print('{"error":"Operator connection failed"}')
        sys.exit(1)
