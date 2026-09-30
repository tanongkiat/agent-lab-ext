# Installation

A LiteLLM-based multi-tenant agent lab: one gateway in front of several
OpenAI-compatible model endpoints, with per-tenant RAG, PII guardrails, JWT auth,
and budget/rate tiers.

## 1. Requirements

| Tool | Notes |
| --- | --- |
| Docker Engine + Compose v2 | `docker compose version` must report v2.x |
| `bash`, `curl`, `jq`, `python3`, `openssl` | for the `tests/bash/*.sh` scripts |
| PowerShell 7+ | only if you use the `tests/*.ps1` scripts instead |
| `kcadm` (Keycloak CLI) | only for `tests/bash/create_realm.sh` |
| RAM | ~6 GB free — presidio-analyzer alone loads a spaCy model |

You also need at least one **OpenAI-compatible** chat endpoint and one embedding
endpoint. Anything that speaks `/v1/chat/completions` works.

## 2. Configure

```bash
git clone <your-repo-url> agent-lab-ext
cd agent-lab-ext

cp .env.example .env
```

Edit `.env` and set, at minimum:

- `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_DB_PASSWORD`,
  `VECTOR_DB_PASSWORD`, `CTX_JWT_SECRET` — generate each with `openssl rand -hex 16`.
  **`LITELLM_SALT_KEY` can never be changed once the database holds data.**
- `OPENAI_COMPATIBLE_1..4_BASE_URL` / `_API_KEY` — your endpoints. A URL must end
  in `/v1`. For a server on the Docker host use `http://host.docker.internal:<port>/v1`.

On Windows, `.\env-setup.ps1` writes a `.env` with the random secrets already
generated; you still fill in the endpoint URLs and keys.

Then map the model aliases to real model ids in
[`litellm/config.yaml`](litellm/config.yaml). The alias names are contractual —
every service and test calls `chat-fast`, `chat-smart`, `chat-smart-alt`, `embed`
by name, so change the `model:` lines, not the `model_name:` lines:

```yaml
  - model_name: chat-fast
    litellm_params:
      model: openai/<your-model-id>        # <- change this
      api_base: os.environ/OPENAI_COMPATIBLE_2_BASE_URL
      api_key: os.environ/OPENAI_COMPATIBLE_2_API_KEY
    model_info:
      access_groups: [tier-basic, tier-pro]  # <- who may use it
```

`tests/pick-models.sh` (or `.ps1`) probes your endpoints and rewrites the
`model_list` block for you.

### Optional integrations — turn off what you don't use

Both are enabled in the shipped config and will break startup or every request if
left unconfigured:

- **Langfuse** — remove `"langfuse"` from `litellm_settings.callbacks`, or set
  `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST`.
- **Elastic inference** (`elastic-chat`) — delete that `model_list` entry and the
  `custom_provider_map` block, or set `ELASTICSEARCH_URL` / `ES_USER` / `ES_PASS`.

### Embedding dimensions must match the schema

`db/init-vector.sql` declares `vector(1024)`. If your embedding model emits a
different size, change that number **before** the first start, and keep it under
2000 — a pgvector HNSW index rejects anything larger. The `embed` entry pins
`extra_body: {dimensions: 1024}` for models that default higher.

## 3. Start

Profiles let you bring up only part of the stack:

| Profile | Services |
| --- | --- |
| `core` | litellm-proxy, litellm-db, cache-redis, edge-gateway, presidio |
| `data` | vector-db, mcp-kb |
| `apps` | keycloak (idp), agent-api, mcp-expert-solution |
| `guard` | presidio only |
| `tools` | ingest-worker |
| `billing` | subscription-service |

```bash
export COMPOSE_PROFILES=core,data,apps      # or set it in .env
docker compose up -d
docker compose ps                            # every healthcheck must read (healthy)
```

First start pulls several GB. `presidio-analyzer` needs 40–60 s to load its model;
`litellm-proxy` waits for it, because the `pii-mark` guardrail is `default_on` and
the proxy returns 500 on every request while presidio is unreachable.

```bash
curl -s localhost:4000/health/liveliness
```

## 4. Provision plans, teams and keys

This creates the budgets, customers, teams and service keys, and writes the
generated keys back into `.env`:

```bash
source tests/bash/lab.sh
./tests/bash/bootstrap-plans.sh
```

It produces two developer tiers driven by **access groups**, not model names:

- `team-dev-basic` → `models: ["tier-basic"]`
- `team-dev-pro` → `models: ["tier-pro"]`

A model becomes available to a tier by listing that group in its
`model_info.access_groups`. Nothing else needs changing.

Recreate the containers that read those keys:

```bash
docker compose up -d --force-recreate agent-api mcp-kb mcp-expert-solution
```

## 5. Keycloak realm (only with the `apps` profile)

```bash
./tests/bash/create_realm.sh      # realm "lab", client "lab-app", users alice/bob
# more users: tests/add-user.ps1 (PowerShell only — no bash port yet)
```

Test users get `tenant_id` and `plan` claims; `agent-api` reads them to scope
retrieval and pick the tier. Password equals the username.

## 6. Ingest the sample documents

```bash
COMPOSE_PROFILES=tools docker compose run --rm ingest-worker
```

Chunks and embeds everything under `docs/` into the `chunks` table, tagged by
tenant. Row-Level Security then keeps `tenant-a` from ever reading `tenant-b`.

## 7. Verify

```bash
./tests/bash/test_health.sh       # liveness, model list, one call per alias, embeddings
./tests/bash/run_all.sh           # full suite: isolation, guardrails, budgets, rate limits
```

`run_all.sh` prints `PASS=… FAIL=…`. T10 and T12 are manual and always skip.

## Endpoints

| URL | Purpose |
| --- | --- |
| `http://localhost:4000` | litellm-proxy, direct (admin + `/key/generate`) |
| `http://llm.localhost` | developer channel via Caddy — allowlisted paths only |
| `http://api.localhost` | application channel → agent-api |
| `http://localhost:8080` | Keycloak (`admin` / `admin`) |
| `http://localhost:8090` | subscription-service (`billing` profile) |

Caddy deliberately 404s everything not on its allowlist, so the LiteLLM admin UI
and `/key/generate` are unreachable through `llm.localhost` — reach them on
port 4000.

## Troubleshooting

**`500 Presidio PII analysis failed: ClientConnectorDNSError`**
The presidio containers aren't running, so their hostname doesn't resolve. Start
them (`docker compose up -d presidio-analyzer presidio-anonymizer`) or set
`default_on: false` on the `pii-mark` guardrail to fail open instead.

**Model missing from `/v1/models`**
`store_model_in_db` is `false`, so `litellm/config.yaml` is the only source of
truth — `docker compose restart litellm-proxy` after every edit. If one model is
absent while others load, check the startup log: a bad `custom_provider_map`
import drops just that entry.

**`401` / `403` from a key that should work**
The key's `models` list holds *access group* names, not model names. Confirm the
model declares that group in `model_info.access_groups`.

**`429` during tests**
Expected — T11 and T14 assert the rate limits. Outside the suite, raise
`rpm_limit` on the key or team.

**pgvector rejects the index at first start**
The embedding dimension doesn't match `vector(N)`. Fix `db/init-vector.sql`, then
`docker compose rm -sfv vector-db` to rebuild — the init script only runs on an
empty volume.

## Security before you deploy this anywhere real

This is a lab. It ships with `admin`/`admin` Keycloak credentials, fixed
`kb_reader_pw` / `kb_writer_pw` database passwords in `db/init-vector.sql`,
`auto_https off` in the Caddyfile, and Keycloak in `start-dev`. Change all of
them, and keep `.env` out of git — `.gitignore` already covers it.
