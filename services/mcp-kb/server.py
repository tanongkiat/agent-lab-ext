# file: C:\lab\agent-lab-ext\services\mcp-kb\server.py
"""mcp-kb: Data MCP (INTERNAL ONLY). Scope comes from the ctx JWT, never from tool arguments."""
import os
import httpx, jwt, psycopg
from mcp.server.fastmcp import FastMCP, Context
from mcp.server.transport_security import TransportSecuritySettings

LITELLM = os.environ["LITELLM_URL"]
RKEY = os.environ["RETRIEVAL_KEY"]
SECRET = os.environ["CTX_JWT_SECRET"]
MAX_K, MAX_CHARS = 10, 1500

mcp = FastMCP("kb", host="0.0.0.0", port=8080, stateless_http=True,
              transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))


def scope(ctx: Context) -> dict:
    h = ctx.request_context.request.headers
    raw = h.get("x-mcp-kb-authorization") or h.get("authorization") or ""
    token = raw.removeprefix("Bearer ").strip()
    if not token:
        raise PermissionError("missing ctx token")
    return jwt.decode(token, SECRET, algorithms=["HS256"])  # ตรวจลายเซ็น + exp


def embed(text: str) -> list[float]:
    r = httpx.post(f"{LITELLM}/v1/embeddings", headers={"Authorization": f"Bearer {RKEY}"},
                   json={"model": "embed", "input": text}, timeout=30)
    r.raise_for_status()
    return r.json()["data"][0]["embedding"]


def rerank(query: str, docs: list[str], k: int) -> list[int]:
    try:
        r = httpx.post(f"{LITELLM}/v1/rerank", headers={"Authorization": f"Bearer {RKEY}"},
                       json={"model": "rerank", "query": query, "documents": docs, "top_n": k}, timeout=30)
        r.raise_for_status()
        return [x["index"] for x in r.json()["results"]]
    except httpx.HTTPError:  # ไม่มี rerank model → ใช้ลำดับจาก vector search
        return list(range(min(k, len(docs))))


@mcp.tool()
def search_docs(query: str, ctx: Context, top_k: int = 5) -> list[dict]:
    """Search the internal knowledge base of the caller's tenant."""
    s = scope(ctx)
    k = max(1, min(top_k, MAX_K))
    vec = str(embed(query))
    with psycopg.connect(os.environ["KB_DSN"]) as db, db.transaction():
        db.execute("SELECT set_config('app.tenant_id', %s, true)", (s["tenant_id"],))
        rows = db.execute(
            "SELECT doc_id, title, text FROM chunks WHERE domain = ANY(%s)"
            " ORDER BY embedding <=> %s::vector LIMIT %s",
            (s.get("domains", ["solution", "api"]), vec, k * 3)).fetchall()
    if not rows:
        return []
    order = rerank(query, [r[2] for r in rows], k)
    return [{"doc_id": rows[i][0], "title": rows[i][1], "text": rows[i][2][:MAX_CHARS]} for i in order]


@mcp.tool()
def get_document(doc_id: str, ctx: Context) -> dict:
    """Return the full text of one document the caller's tenant can read."""
    s = scope(ctx)
    with psycopg.connect(os.environ["KB_DSN"]) as db, db.transaction():
        db.execute("SELECT set_config('app.tenant_id', %s, true)", (s["tenant_id"],))
        rows = db.execute("SELECT title, text FROM chunks WHERE doc_id = %s AND domain = ANY(%s) ORDER BY chunk_no",
                          (doc_id, s.get("domains", ["solution", "api"]))).fetchall()
    if not rows:
        return {"error": "not found"}
    return {"doc_id": doc_id, "title": rows[0][0], "text": "\n\n".join(r[1] for r in rows)[:8000]}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")