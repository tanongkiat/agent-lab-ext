#!/usr/bin/env bash
# file: tests/test_bob_subscription.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

send_billing '{"user_id":"bob","plan":"pro"}'; echo           # customer -> plan-pro
for i in 1 2 3 4 5 6 7 8; do                                  # no longer hits 429 (rpm 60)
  test_chat_code "$AGENT_KEY_BASIC" chat-fast bob; echo
done

# the plan in agent-api comes from the IdP claim -> in the lab we update Keycloak ourselves
# (in production subscription-service does it)
BID="$(kc get users -r lab -q username=bob --fields id --format csv --noquotes \
  | head -1 | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
kc update "users/$BID" -r lab -s 'attributes.tenant_id=["tenant-b"]' -s 'attributes.plan=["pro"]'
TB="$(get_lab_token bob)"
http_code "http://${host}/v1/chat/completions" -X POST \
  -H "Authorization: Bearer $TB" -H "Content-Type: $JSON" \
  -d '{"model":"agent/assistant-pro","messages":[{"role":"user","content":"hi"}]}'; echo   # 200

send_billing '{"user_id":"bob","plan":"pro","status":"cancelled"}'; echo   # customer blocked
test_chat_code "$AGENT_KEY_BASIC" chat-fast bob; echo                      # 4xx (blocked)

# put bob back on free on both sides (required by the Step 9 test suite)
send_billing '{"user_id":"bob","plan":"free"}'; echo
kc update "users/$BID" -r lab -s 'attributes.tenant_id=["tenant-b"]' -s 'attributes.plan=["free"]'
