#!/usr/bin/env bash
# file: tests/key_update_mcp_expert.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"          # loads LITELLM_MASTER_KEY, DEV_KEY_* and invoke_lab

# 1) allow expert_solution on both dev teams
for T in team-dev-basic team-dev-pro; do
  invoke_lab /team/update "$(jq -nc --arg t "$T" \
    '{team_id:$t, object_permission:{mcp_servers:["expert_solution"]}}')" >/dev/null
  echo "team $T : ok"
done

# 2) now the keys
for K in "$DEV_KEY_BASIC" "$DEV_KEY_PRO"; do
  invoke_lab /key/update "$(jq -nc --arg k "$K" \
    '{key:$k, object_permission:{mcp_servers:["expert_solution"]}}')" | jq -r '.key_alias'
done

python3 tests/mcp_call.py "$LAB/mcp/expert_solution" "$DEV_KEY_PRO" - list   # should list ask_solution
