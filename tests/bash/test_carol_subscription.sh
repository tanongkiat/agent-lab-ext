#!/usr/bin/env bash
# file: tests/test_carol_subscription.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

CK="$(send_billing '{"user_id":"carol","plan":"dev-basic"}' | jq -r '.key')"
test_chat_code "$CK" chat-fast; echo          # 200
test_chat_code "$CK" chat-smart; echo         # 401/403
CK2="$(send_billing '{"user_id":"carol","plan":"dev-pro"}' | jq -r '.key')"
test_chat_code "$CK" chat-fast; echo          # 401 (the old key is blocked)
test_chat_code "$CK2" chat-smart; echo        # 200
