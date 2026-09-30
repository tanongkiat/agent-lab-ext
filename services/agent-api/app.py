# file: C:\lab\agent-lab-ext\services\agent-api\app.py
"""agent-api: public Agent API (OpenAI-compatible). Lab version: server-side loop, plan-based policy."""
import json, os, time
import jwt
from jwt import PyJWKClient
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from openai import AsyncOpenAI
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

LITELLM = os.environ["LITELLM_URL"]
JWKS = PyJWKClient(os.environ["JWKS_URL"])
#ISSUER = os.environ["JWT_ISSUER"]
ISSUERS = [s.strip() for s in os.environ["JWT_ISSUER"].split(",") if s.strip()]
SECRET = os.environ["CTX_JWT_SECRET"]
MAX_STEPS = int(os.environ.get("MAX_STEPS", "6"))
TOOLS_ALLOWED = ("search_docs", "get_document")
SYSTEM = ("คุณคือผู้ช่วยของบริษัท ใช้ tool search_docs ค้นเอกสารก่อนตอบทุกครั้ง "
          "ตอบเป็นภาษาเดียวกับผู้ใช้ และระบุชื่อเอกสารที่ใช้อ้างอิง")

# plan → key ต่อ tier + agent ที่ใช้ได้ (agent name → model alias)
PLANS = {
    "free": {"key": os.environ["AGENT_KEY_BASIC"],
             "agents": {"agent/assistant": "chat-fast"}},
    "pro": {"key": os.environ["AGENT_KEY_PRO"],
            "agents": {"agent/assistant": "chat-fast", "agent/assistant-pro": "chat-smart"}},
}

app = FastAPI(title="agent-api")


def authenticate(authz: str) -> dict:
    token = authz.removeprefix("Bearer ").strip()
    try:
        key = JWKS.get_signing_key_from_jwt(token).key
        c = jwt.decode(token, key, algorithms=["RS256"], options={"verify_aud": False})
    except Exception as e:  # noqa: BLE001
        raise HTTPException(401, f"invalid token: {e}")
    if c.get("iss") not in ISSUERS:
        raise HTTPException(401, f"invalid token: issuer {c.get('iss')} not allowed")
    return {"user": c["preferred_username"], "tenant": c.get("tenant_id"), "plan": c.get("plan", "free")}

def ctx_token(u: dict) -> str:
    claims = {"sub": u["user"], "tenant_id": u["tenant"], "domains": ["solution", "api"],
              "exp": int(time.time()) + 120}
    return jwt.encode(claims, SECRET, algorithm="HS256")


def sse(out: dict) -> StreamingResponse:
    chunk = {"id": out["id"], "object": "chat.completion.chunk", "created": out["created"], "model": out["model"],
             "choices": [{"index": 0, "finish_reason": "stop",
                          "delta": {"role": "assistant", "content": out["choices"][0]["message"]["content"]}}]}

    def gen():
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")


@app.get("/v1/models")
def models(authorization: str = Header("")):
    u = authenticate(authorization)
    agents = PLANS.get(u["plan"], PLANS["free"])["agents"]
    return {"object": "list", "data": [{"id": a, "object": "model", "owned_by": "agent-platform"} for a in agents]}


@app.post("/v1/chat/completions")
async def chat(body: dict, authorization: str = Header("")):
    u = authenticate(authorization)
    plan = PLANS.get(u["plan"], PLANS["free"])
    agent = body.get("model")
    if agent not in plan["agents"]:
        raise HTTPException(403, f"'{agent}' ไม่อยู่ใน plan {u['plan']} — อัปเกรดเพื่อใช้งาน")
    if body.get("tools"):
        raise HTTPException(400, "ไม่รองรับ tools จาก client: server เป็นผู้กำหนด tools")
    llm = AsyncOpenAI(base_url=f"{LITELLM}/v1", api_key=plan["key"])
    msgs = [{"role": "system", "content": SYSTEM}] + body["messages"]
    headers = {"x-litellm-api-key": f"Bearer {plan['key']}",
               "x-mcp-kb-authorization": f"Bearer {ctx_token(u)}"}
    async with streamablehttp_client(f"{LITELLM}/mcp/kb", headers=headers) as (r, w, _):
        async with ClientSession(r, w) as mcp:
            await mcp.initialize()
            tools = [{"type": "function", "function": {"name": t.name, "description": t.description or "",
                                                       "parameters": t.inputSchema}}
                     for t in (await mcp.list_tools()).tools if t.name.endswith(TOOLS_ALLOWED)]
            for _ in range(MAX_STEPS):
                resp = await llm.chat.completions.create(model=plan["agents"][agent], messages=msgs,
                                                         tools=tools or None, user=u["user"])
                m = resp.choices[0].message
                if not m.tool_calls:
                    out = resp.model_dump()
                    out["model"] = agent  # ซ่อนชื่อ model ภายใน
                    return sse(out) if body.get("stream") else JSONResponse(out)
                msgs.append(m.model_dump(exclude_none=True))
                for tc in m.tool_calls:
                    if not tc.function.name.endswith(TOOLS_ALLOWED):
                        result = "tool not allowed"
                    else:
                        res = await mcp.call_tool(tc.function.name, json.loads(tc.function.arguments or "{}"))
                        result = "\n".join(getattr(c, "text", "") for c in res.content)[:8000]
                    msgs.append({"role": "tool", "tool_call_id": tc.id, "content": result})
    raise HTTPException(504, f"agent หยุดที่ {MAX_STEPS} รอบ")