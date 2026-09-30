# agent-lab-ext

A self-hosted lab for **multi-tenant LLM serving**: a [LiteLLM](https://github.com/BerriAI/litellm)
gateway in front of arbitrary OpenAI-compatible endpoints, with per-tenant RAG,
PII redaction, OIDC auth, and plan-based budgets and rate limits.

Built to answer one question end to end: *how do you let several tenants and
several developer tiers share one set of model endpoints without leaking data,
blowing the budget, or trusting the client?*

## What's in it

| Concern | How |
| --- | --- |
| Model routing + fallback | LiteLLM `model_list` with alias names, `simple-shuffle`, per-model fallbacks |
| Tiering | LiteLLM **access groups** (`tier-basic`, `tier-pro`, `retrieval`) bound to teams and keys |
| Budgets & rate limits | LiteLLM budgets per plan, `rpm_limit` / `tpm_limit` per key, team and end user |
| Tenant isolation | Postgres **Row-Level Security** on the `chunks` table, tenant taken from a signed JWT |
| Retrieval | pgvector + HNSW, exposed to models as the `kb` **MCP server** |
| PII | Presidio guardrail with Thai-specific recognizers (national ID, mobile) |
| Auth | Keycloak OIDC → `agent-api` validates JWTs and re-signs a scoped context token |
| Edge | Caddy with a strict path allowlist — two separate channels, app and developer |
| Tracing | Langfuse callback |

## Layout

```
compose.yaml              profiles: core / data / apps / guard / tools / billing
litellm/
  config.yaml             model_list, access groups, MCP servers, guardrails
  elastic_handler.py      custom provider for Elastic inference endpoints
  presidio-th.json        Thai national-ID and mobile recognizers
services/
  agent-api/              OIDC entry point; mints the per-request context token
  mcp-kb/                 MCP retrieval server, enforces tenant RLS
  mcp-expert-solution/    MCP server over the internal solution docs
  ingest-worker/          chunks + embeds docs/ into pgvector
  subscription-service/   plan changes via webhook
db/init-vector.sql        schema, split reader/writer roles, RLS policies
caddy/Caddyfile           the two allowlisted channels
tests/                    PowerShell suite; tests/bash/ is the bash port
docs/                     sample tenant corpora (tenant-a, tenant-b, internal)
```

## Quick start

```bash
cp .env.example .env      # then fill in secrets + your model endpoints
export COMPOSE_PROFILES=core,data,apps
docker compose up -d
source tests/bash/lab.sh && ./tests/bash/bootstrap-plans.sh
./tests/bash/test_health.sh
```

Full walkthrough, profile table, and troubleshooting: **[INSTALL.md](INSTALL.md)**.

## The one thing to know

Access is granted by **group**, never by model name. A key or team carries
`models: ["tier-pro"]`; a model joins that tier by declaring it:

```yaml
  - model_name: chat-smart
    litellm_params:
      model: openai/<model-id>
    model_info:
      access_groups: [tier-pro]
```

Adding a model to a tier is a one-line config change and a proxy restart — no key
or team edits. `store_model_in_db` is `false`, so `litellm/config.yaml` is the only
source of truth.

## Status

Lab-grade. Keycloak runs in `start-dev`, Caddy has `auto_https off`, and
`db/init-vector.sql` uses fixed development passwords. See the security note at the
end of [INSTALL.md](INSTALL.md) before putting this anywhere real.
