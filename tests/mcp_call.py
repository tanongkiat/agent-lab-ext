"""usage: python tests/mcp_call.py <url> <litellm_key> <tenant|-> <list|tool_name> ['<json args>'] [domains]"""
import asyncio, json, os, sys, time
from contextlib import asynccontextmanager

import jwt
from mcp import ClientSession

try:  # mcp >= 2.0: headers move onto the httpx client, transport yields 2 streams
    from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

    @asynccontextmanager
    async def connect(url, headers):
        async with create_mcp_http_client(headers=headers) as http:
            async with streamable_http_client(url, http_client=http) as streams:
                yield streams[0], streams[1]

except ImportError:  # mcp 1.8-1.x
    from mcp.client.streamable_http import streamablehttp_client

    @asynccontextmanager
    async def connect(url, headers):
        async with streamablehttp_client(url, headers=headers) as (read, write, _):
            yield read, write


url, key, tenant, tool = sys.argv[1:5]
args = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
domains = sys.argv[6].split(",") if len(sys.argv) > 6 else ["solution", "api"]
headers = {"x-litellm-api-key": f"Bearer {key}"}
if tenant != "-":
    tok = jwt.encode({"tenant_id": tenant, "domains": domains, "exp": int(time.time()) + 120},
                     os.environ["CTX_JWT_SECRET"], algorithm="HS256")
    headers["x-mcp-kb-authorization"] = f"Bearer {tok}"


async def main():
    async with connect(url, headers) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            if tool == "list":
                print([t.name for t in (await s.list_tools()).tools])
                return
            res = await s.call_tool(tool, args)
            for c in res.content:
                print(getattr(c, "text", c))

asyncio.run(main())
