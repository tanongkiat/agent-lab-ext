. .\tests\lab.ps1
Write-Lf .env @"
# --- compose ---
COMPOSE_PROFILES=core
LITELLM_TAG=main-stable            # แนะนำให้เปลี่ยนเป็น tag เดียวกับ LiteLLM ที่ใช้อยู่
# --- secrets (สุ่มให้อัตโนมัติ) ---
LITELLM_MASTER_KEY=sk-master-$(New-RandHex 16)
LITELLM_SALT_KEY=sk-salt-$(New-RandHex 16)   # ห้ามเปลี่ยนหลังเริ่มใช้
LITELLM_DB_PASSWORD=$(New-RandHex 12)
VECTOR_DB_PASSWORD=$(New-RandHex 12)
CTX_JWT_SECRET=$(New-RandHex 32)
# --- OpenAI-compatible endpoints: ใช้เลขต่อกัน _1, _2, _3, ... เพิ่มได้ไม่จำกัด ---
# BASE_URL ต้องลงท้าย /v1 · server ในเครื่องนี้ใช้ http://host.docker.internal:<port>/v1 · server ที่ไม่ใช้ key ใส่ none
# model ของแต่ละ alias เลือกทีหลังด้วย tests/pick-models.ps1 (Step 1.2b)
OPENAI_COMPATIBLE_1_BASE_URL=https://ark.ap-southeast.bytepluses.com/api/coding/v3
OPENAI_COMPATIBLE_1_API_KEY=<your-api-key>
OPENAI_COMPATIBLE_1_MODEL=ark-code-latest
OPENAI_COMPATIBLE_2_BASE_URL=https://api.z.ai/api/coding/paas/v4
OPENAI_COMPATIBLE_2_API_KEY=<your-api-key>
OPENAI_COMPATIBLE_2_MODEL=glm-5.3-flash
OPENAI_COMPATIBLE_3_BASE_URL=http://host.docker.internal:8788/v1
OPENAI_COMPATIBLE_3_API_KEY=<your-api-key>
OPENAI_COMPATIBLE_3_MODEL=gpt-5.6-sol
OPENAI_COMPATIBLE_4_BASE_URL=http://host.docker.internal:8788/v1
OPENAI_COMPATIBLE_4_API_KEY=<your-api-key>
OPENAI_COMPATIBLE_4_MODEL=claude-opus-5

# --- Elastic inference (model elastic-chat) ---
ELASTICSEARCH_URL=https://<cluster>.es.<region>.aws.found.io
ES_USER=<elastic-user>
ES_PASS=<elastic-password>

# --- Langfuse (litellm_settings.callbacks) ---
LANGFUSE_PUBLIC_KEY=<pk>
LANGFUSE_SECRET_KEY=<sk>
LANGFUSE_HOST=https://cloud.langfuse.com

# --- Keycloak ---
KC_ISSUERS=http://localhost:8080/realms/lab

# --- จะเติมใน Step 2 ---
AGENT_KEY_BASIC=
AGENT_KEY_PRO=
EXPERT_KEY=
RETRIEVAL_KEY=
INGEST_KEY=
DEV_KEY_BASIC=
DEV_KEY_PRO=
SUB_ADMIN_KEY=
"@