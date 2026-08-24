#!/usr/bin/env python3
"""伪 Mirasim，用于验证协议变动下的解析容忍度与降级路径。

  python3 scripts/fake-mirasim.py renamed   # 换嵌套层级、换键名、占比用 0–1 小数、时间用毫秒
  python3 scripts/fake-mirasim.py garbage   # 声明是 relay 帧但无可识别窗口，应触发「协议不符」

配合 `MiraQuota --port 4979 --once` 使用。
"""
import asyncio, json, sys, time
from websockets.asyncio.server import serve
from websockets.http11 import Response
from websockets.datastructures import Headers

MODE = sys.argv[1] if len(sys.argv) > 1 else "renamed"
PORT = 4979
RESET = int(time.time()) + 3600


def process_request(conn, request):
    if request.path.startswith("/api/health"):
        body = b'{"name":"mirasim","version":"9.9.9"}'
        return Response(200, "OK", Headers([
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
        ]), body)
    return None


def frame():
    if MODE == "garbage":
        relay = {"host": "fake", "mode": "cloud", "status": "ok", "blob": {"nothing": 1}}
    else:
        # 相对真实协议：多一层嵌套、键名全换、占比用小数、时间用毫秒。
        relay = {
            "host": "fake.relay", "mode": "cloud", "status": "ok",
            "limits": {"entries": [
                {"name": "5h", "utilization": 0.615, "resetsAt": RESET * 1000},
                {"name": "7d", "utilization": 0.042, "resetsAt": (RESET + 500000) * 1000},
            ]},
        }
    return json.dumps({"type": "host", "payload": {"type": "relay", "relay": relay}})


async def handler(ws):
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        if msg.get("payload", {}).get("type") == "getRelay":
            await ws.send(frame())


async def main():
    async with serve(handler, "127.0.0.1", PORT, process_request=process_request):
        print(f"伪 Mirasim 监听 127.0.0.1:{PORT}  模式 {MODE}", flush=True)
        await asyncio.Future()


asyncio.run(main())
