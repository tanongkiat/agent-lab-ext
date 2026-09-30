#!/usr/bin/env bash
# file: tests/bootstrap-plans.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"          # always run from the agent-lab-ext root
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

k() { invoke_lab /key/generate "$1" | jq -r '.key'; }

echo '== budgets per plan (low values so the cutoff is testable)'
invoke_lab /budget/new '{"budget_id":"plan-free","max_budget":0.02,"budget_duration":"30d","rpm_limit":5,"tpm_limit":20000}' >/dev/null
invoke_lab /budget/new '{"budget_id":"plan-pro","max_budget":1,"budget_duration":"30d","rpm_limit":60,"tpm_limit":200000}' >/dev/null

echo '== end-users (customers)'
invoke_lab /customer/new '{"user_id":"alice","budget_id":"plan-pro"}' >/dev/null
invoke_lab /customer/new '{"user_id":"bob","budget_id":"plan-free"}' >/dev/null

echo '== teams for the Dev plans'
invoke_lab /team/new '{"team_id":"team-dev-basic","team_alias":"team-dev-basic","models":["tier-basic"],"rpm_limit":300}' >/dev/null
invoke_lab /team/new '{"team_id":"team-dev-pro","team_alias":"team-dev-pro","models":["tier-pro"],"rpm_limit":1000}' >/dev/null

echo '== service keys'
set_dotenv AGENT_KEY_BASIC "$(k '{"key_alias":"agent-api-basic","models":["tier-basic"]}')"
set_dotenv AGENT_KEY_PRO   "$(k '{"key_alias":"agent-api-pro","models":["tier-pro"]}')"
set_dotenv EXPERT_KEY      "$(k '{"key_alias":"expert-mcp","models":["tier-pro"]}')"
set_dotenv RETRIEVAL_KEY   "$(k '{"key_alias":"retrieval","models":["retrieval"]}')"
set_dotenv INGEST_KEY      "$(k '{"key_alias":"ingest","models":["embed"]}')"

echo '== developers + keys under a team'
invoke_lab /user/new '{"user_id":"dev-basic-user","user_role":"internal_user"}' >/dev/null
invoke_lab /user/new '{"user_id":"dev-pro-user","user_role":"internal_user"}' >/dev/null
invoke_lab /team/member_add '{"team_id":"team-dev-basic","member":{"user_id":"dev-basic-user","role":"user"},"max_budget_in_team":0.05}' >/dev/null
invoke_lab /team/member_add '{"team_id":"team-dev-pro","member":{"user_id":"dev-pro-user","role":"user"},"max_budget_in_team":1}' >/dev/null
set_dotenv DEV_KEY_BASIC "$(k '{"key_alias":"dev-basic","team_id":"team-dev-basic","user_id":"dev-basic-user","rpm_limit":30}')"
set_dotenv DEV_KEY_PRO   "$(k '{"key_alias":"dev-pro","team_id":"team-dev-pro","user_id":"dev-pro-user","rpm_limit":120}')"

echo '== admin key for subscription-service (separate from the master key)'
invoke_lab /user/new '{"user_id":"subscription-service","user_role":"proxy_admin"}' >/dev/null
set_dotenv SUB_ADMIN_KEY "$(k '{"key_alias":"subscription-admin","user_id":"subscription-service"}')"

echo 'done'
grep -E '^(AGENT|EXPERT|RETRIEVAL|INGEST|DEV|SUB)_' .env | cut -c1-28
