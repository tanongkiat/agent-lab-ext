-- file: C:\lab\agent-lab-ext\db\init-vector.sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE chunks (
  id         bigserial PRIMARY KEY,
  tenant_id  text NOT NULL,
  domain     text NOT NULL,           -- solution | api
  doc_id     text NOT NULL,
  title      text NOT NULL,
  chunk_no   int  NOT NULL,
  text       text NOT NULL,
  embedding  vector(1024) NOT NULL,   -- = EMBED_DIM ใน .env (pick-models.ps1 แก้ให้) เช่น bge-m3 = 1024 · สูงสุด 2000
  UNIQUE (doc_id, chunk_no)
);
CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX chunks_tenant_domain ON chunks (tenant_id, domain);

-- users แยกอ่าน/เขียน (lab password: เปลี่ยนก่อนใช้จริง)
CREATE ROLE kb_reader LOGIN PASSWORD 'kb_reader_pw';
CREATE ROLE kb_writer LOGIN PASSWORD 'kb_writer_pw';
GRANT SELECT ON chunks TO kb_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON chunks TO kb_writer;
GRANT USAGE ON SEQUENCE chunks_id_seq TO kb_writer;

-- Row-Level Security: reader เห็นเฉพาะ tenant ที่ตั้งใน session
ALTER TABLE chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE chunks FORCE ROW LEVEL SECURITY;
CREATE POLICY reader_tenant ON chunks FOR SELECT TO kb_reader
  USING (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY writer_all ON chunks FOR ALL TO kb_writer
  USING (true) WITH CHECK (true);