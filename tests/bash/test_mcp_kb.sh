#!/usr/bin/env bash
# file: tests/test_mcp_kb.sh
# give the agent/expert keys access to the kb MCP server
# source ./tests/lab.sh first (or run this script directly)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

for K in "$AGENT_KEY_BASIC" "$AGENT_KEY_PRO" "$EXPERT_KEY"; do
  invoke_lab /key/update "$(jq -nc --arg k "$K" \
    '{key:$k, object_permission:{mcp_servers:["kb"]}}')" | jq -r '.key_alias'
done
