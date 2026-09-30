#!/usr/bin/env bash
# file: tests/test_health.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

curl -sS "$LAB/health/liveliness"; echo
models="$(curl -sS "$LAB/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq -r '.data[].id')"
echo "$models"

for m in chat-fast chat-smart chat-smart-alt; do
  invoke_chat "$LAB/v1/chat/completions" "$LITELLM_MASTER_KEY" "$m" 'ตอบคำเดียว: สวัสดี' \
    | jq -r '.choices[0].message.content'
done

invoke_lab /v1/embeddings '{"model":"embed","input":"ทดสอบ"}' | jq '.data[0].embedding | length'

# rerank is optional: with no rerank server it is absent from the config (mcp-kb falls back to the vector order)
if printf '%s\n' "$models" | grep -qx 'rerank'; then
  invoke_lab /v1/rerank '{"model":"rerank","query":"ภาษาไทย","documents":["hello","สวัสดีครับ"]}' | jq '.results[0]'
else
  echo 'rerank: skipped (not configured)'
fi
