# file: C:\lab\agent-lab-ext\services\mcp-expert-solution\server.py
"""mcp-expert-solution: Expert MCP for developers. Returns answers + references, never raw chunks."""
import json, os, re, time
import jwt
from openai import AsyncOpenAI
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

LITELLM = os.environ["LITELLM_URL"]
KEY = os.environ["EXPERT_KEY"]
SECRET = os.environ["CTX_JWT_SECRET"]
MAX_ANSWER = 3000
llm = AsyncOpenAI(base_url=f"{LITELLM}/v1", api_key=KEY)
mcp = FastMCP("expert-solution", host="0.0.0.0", port=8080, stateless_http=True,
              transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))

SYSTEM = ("คุณคือ Solution Architect ของบริษัท ตอบเฉพาะเรื่อง solution design, architecture, integration pattern "
          "โดยอิงเอกสารที่ให้เท่านั้น ห้ามคัดลอกเอกสารยาวเกิน 1 ประโยค ให้สรุปเป็นขั้นตอนและตัวอย่างสั้นๆ "
          "ถ้าเอกสารไม่พอให้บอกตรงๆ")


async def in_domain(question: str) -> bool:  # domain_guard
    r = await llm.chat.completions.create(model="chat-fast", max_tokens=3, messages=[
        {"role": "system", "content": "ตอบ YES ถ้าคำถามเกี่ยวกับ software architecture, solution design, "
                                      "integration หรือ platform engineering มิฉะนั้นตอบ NO"},
        {"role": "user", "content": question}])
    return "YES" in (r.choices[0].message.content or "").upper()


async def retrieve(question: str) -> list[dict]:  # retriever: kb ผ่าน litellm-proxy
    ctx = jwt.encode({"sub": "expert-solution", "tenant_id": "internal", "domains": ["solution"],
                      "exp": int(time.time()) + 120}, SECRET, algorithm="HS256")
    headers = {"x-litellm-api-key": f"Bearer {KEY}", "x-mcp-kb-authorization": f"Bearer {ctx}"}
    async with streamablehttp_client(f"{LITELLM}/mcp/kb", headers=headers) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            name = next(t.name for t in (await s.list_tools()).tools if t.name.endswith("search_docs"))
            res = await s.call_tool(name, {"query": question, "top_k": 5})
    hits = []
    for c in res.content:
        try:
            v = json.loads(getattr(c, "text", "") or "null")
        except json.JSONDecodeError:
            continue
        hits += v if isinstance(v, list) else [v] if isinstance(v, dict) else []
    return hits


def output_filter(answer: str, hits: list[dict]) -> str:
    for h in hits:  # ตัดประโยคที่ยกมาจากเอกสารยาวเกิน 80 ตัวอักษร
        for sent in re.split(r"(?<=[.!?\n])", h.get("text", "")):
            s = sent.strip()
            if len(s) > 80 and s in answer:
                answer = answer.replace(s, "[สรุปจากเอกสาร — ดู references]")
    return answer[:MAX_ANSWER]


@mcp.tool()
async def ask_solution(question: str, context: str | None = None, language: str = "th") -> dict:
    """Ask the Solution Architect expert. Returns an answer with references (no raw documents)."""
    if not await in_domain(question):
        return {"answer": "คำถามนี้อยู่นอกขอบเขตของ expert-solution — ลอง expert อื่น เช่น expert-api",
                "references": [], "confidence": "low"}
    hits = await retrieve(question)
    docs = "\n\n".join(f"[{h['doc_id']}] {h['title']}\n{h['text']}" for h in hits)
    user = f"คำถาม: {question}\n\nบริบทจาก developer:\n{(context or '')[:4000]}\n\nเอกสาร:\n{docs}\n\nตอบเป็นภาษา {language}"
    r = await llm.chat.completions.create(model="chat-smart", messages=[
        {"role": "system", "content": SYSTEM}, {"role": "user", "content": user}])
    refs = [{"id": h["doc_id"], "title": h["title"]} for h in hits]
    conf = "high" if len(hits) >= 2 else "medium" if hits else "low"
    return {"answer": output_filter(r.choices[0].message.content or "", hits), "references": refs, "confidence": conf}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")