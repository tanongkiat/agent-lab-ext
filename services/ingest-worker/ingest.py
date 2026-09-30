# file: C:\lab\agent-lab-ext\services\ingest-worker\ingest.py
"""Ingest markdown under /docs/<tenant>/<domain>/*.md into vector-db."""
import os, pathlib, re
import psycopg
from openai import OpenAI

DOCS = pathlib.Path(os.environ.get("DOCS_DIR", "/docs"))
llm = OpenAI(base_url=os.environ["LITELLM_URL"] + "/v1", api_key=os.environ["INGEST_KEY"])
CHUNK = 800  # ตัวอักษรต่อ chunk (lab)


def chunks(text: str):
    paras, buf = re.split(r"\n\s*\n", text), ""
    for p in paras:
        if len(buf) + len(p) > CHUNK and buf:
            yield buf.strip(); buf = ""
        buf += p + "\n\n"
    if buf.strip():
        yield buf.strip()


def main():
    with psycopg.connect(os.environ["KB_DSN"], autocommit=True) as db:
        for f in sorted(DOCS.glob("*/*/*.md")):
            tenant, domain = f.parts[-3], f.parts[-2]
            doc_id = f"{tenant}/{domain}/{f.stem}"
            text = f.read_text(encoding="utf-8")
            title = text.splitlines()[0].lstrip("# ").strip()
            parts = list(chunks(text))
            vecs = llm.embeddings.create(model="embed", input=parts).data
            db.execute("DELETE FROM chunks WHERE doc_id = %s", (doc_id,))
            for i, (t, v) in enumerate(zip(parts, vecs)):
                db.execute(
                    "INSERT INTO chunks (tenant_id, domain, doc_id, title, chunk_no, text, embedding)"
                    " VALUES (%s,%s,%s,%s,%s,%s,%s::vector)",
                    (tenant, domain, doc_id, title, i, t, str(v.embedding)))
            print(f"ingested {doc_id}: {len(parts)} chunks")


if __name__ == "__main__":
    main()