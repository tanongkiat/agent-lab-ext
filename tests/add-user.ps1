# file: tests/add-user.ps1
# Onboard one person to Channel A (Keycloak end user), Channel B (LiteLLM dev key), or both,
# then print everything that has to be handed over.
#   . .\tests\lab.ps1
#   .\tests\add-user.ps1 -Name somchai -Channel Both -Tenant tenant-a -Plan pro -Tier pro
#Requires -Version 7.4
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Name,
  [ValidateSet('A', 'B', 'Both')][string]$Channel = 'Both',

  # --- Channel A (end user) ---
  [string]$Tenant = 'tenant-a',
  [ValidateSet('free', 'pro')][string]$Plan = 'pro',
  [string]$Password,                       # default: = username, the lab convention Get-LabToken relies on
  [switch]$RandomPassword,                 # override with a generated one (Get-LabToken stops working)

  # --- Channel B (developer) ---
  [ValidateSet('basic', 'pro')][string]$Tier = 'pro',
  [string[]]$McpServers = @('expert_solution'),
  [int]$Rpm = 120,
  [double]$Budget = 1,

  # --- where the lab lives ---
  [string]$LabHost = 'localhost',
  [int]$GatewayPort = 80,
  [int]$IdpPort = 8080
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)   # always run from the agent-lab-ext root
. "$PSScriptRoot\lab.ps1"

# lab.ps1 pins $LAB to localhost:4000; admin calls must follow -LabHost.
# Port 4000 is the master-key door and is deliberately not exposed through the gateway,
# so with a remote -LabHost it has to be reachable (ssh tunnel, or run this on the lab host).
if ($LabHost -ne 'localhost') { $LAB = "http://${LabHost}:4000" }

$suffix  = if ($GatewayPort -eq 80) { '' } else { ":$GatewayPort" }
$ApiBase = "http://api.localhost$suffix"          # Caddy routes by Host name, so the name stays
$LlmBase = "http://llm.localhost$suffix"
$IdpUrl  = "http://${LabHost}:$IdpPort"

$doA = $Channel -in 'A', 'Both'
$doB = $Channel -in 'B', 'Both'
$out = [ordered]@{ name = $Name }

# ------------------------------------------------------------------ Channel A
if ($doA) {
  Write-Host "== Channel A: Keycloak user '$Name' ($Tenant / $Plan)" -ForegroundColor Cyan
  if (-not $Password) { $Password = if ($RandomPassword) { New-RandHex 12 } else { $Name } }

  kc config credentials --server "http://localhost:$IdpPort" --realm master --user admin --password admin | Out-Null

  $existing = kc get users -r lab -q "username=$Name" --fields id --format csv --noquotes
  if ($existing) {
    Write-Host "   user already exists - updating attributes and password" -ForegroundColor Yellow
    $id = ($existing | Select-Object -First 1).Trim()
    kc update "users/$id" -r lab -s "attributes.tenant_id=[`"$Tenant`"]" -s "attributes.plan=[`"$Plan`"]" | Out-Null
  }
  else {
    kc create users -r lab -s "username=$Name" -s enabled=true -s "email=$Name@lab.local" -s emailVerified=true `
      -s "firstName=$Name" -s lastName=lab `
      -s "attributes.tenant_id=[`"$Tenant`"]" -s "attributes.plan=[`"$Plan`"]" | Out-Null
  }
  kc set-password -r lab --username $Name --new-password $Password | Out-Null

  # budget for the end user, so LiteLLM can cut them off (plan-free / plan-pro from bootstrap-plans.ps1)
  try { $null = Invoke-Lab /customer/new @{ user_id = $Name; budget_id = "plan-$Plan" } }
  catch { Write-Host "   customer already in LiteLLM - leaving the budget as it is" -ForegroundColor Yellow }

  # verify: the password grant must return a token carrying the right claims
  $tok = (Invoke-RestMethod "$IdpUrl/realms/lab/protocol/openid-connect/token" -Method Post -Body @{
      grant_type = 'password'; client_id = 'lab-app'; username = $Name; password = $Password }).access_token
  $p64 = $tok.Split('.')[1].Replace('-', '+').Replace('_', '/')
  $claims = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($p64.PadRight([int][Math]::Ceiling($p64.Length / 4) * 4, '='))
  ) | ConvertFrom-Json
  Write-Host "   token ok - tenant_id=$($claims.tenant_id) plan=$($claims.plan)" -ForegroundColor Green

  $out.channelA = [ordered]@{
    username   = $Name
    password   = $Password
    tenant     = $Tenant
    plan       = $Plan
    baseUrl    = "$ApiBase/v1"
    tokenUrl   = "$IdpUrl/realms/lab/protocol/openid-connect/token"
    clientId   = 'lab-app'
    agents     = if ($Plan -eq 'pro') { @('agent/assistant', 'agent/assistant-pro') } else { @('agent/assistant') }
  }
}

# ------------------------------------------------------------------ Channel B
if ($doB) {
  $team = "team-dev-$Tier"
  Write-Host "== Channel B: LiteLLM developer '$Name' ($team)" -ForegroundColor Cyan

  try { $null = Invoke-Lab /user/new @{ user_id = $Name; user_role = 'internal_user' } }
  catch { Write-Host "   LiteLLM user already exists - reusing it" -ForegroundColor Yellow }

  try { $null = Invoke-Lab /team/member_add @{ team_id = $team; member = @{ user_id = $Name; role = 'user' }; max_budget_in_team = $Budget } }
  catch { Write-Host "   already a member of $team - leaving the budget as it is" -ForegroundColor Yellow }

  # model access comes from the team access_groups, so the key carries no models of its own
  $key = (Invoke-Lab /key/generate @{ key_alias = "dev-$Name"; team_id = $team; user_id = $Name; rpm_limit = $Rpm }).key

  # MCP is a separate grant from model access - without it the key sees no tools
  if ($McpServers) {
    $null = Invoke-Lab /key/update @{ key = $key; object_permission = @{ mcp_servers = $McpServers } }
  }

  # verify: the key must see the models its tier allows
  $models = (Invoke-RestMethod "$LlmBase/v1/models" -Headers @{ Authorization = "Bearer $key" }).data.id
  Write-Host "   key ok - models: $($models -join ', ')" -ForegroundColor Green

  $out.channelB = [ordered]@{
    key        = $key
    team       = $team
    tier       = "tier-$Tier"
    baseUrl    = "$LlmBase/v1"
    models     = $models
    mcpServers = $McpServers
    mcpUrls    = @($McpServers | ForEach-Object { "$LlmBase/mcp/$_" })
    rpm        = $Rpm
    budgetUsd  = $Budget
  }
}

# ------------------------------------------------------------------- handout
$nl = [Environment]::NewLine
$h = [Text.StringBuilder]::new()
[void]$h.AppendLine("=============== hand this to $Name ===============")

if ($doA) {
  $a = $out.channelA
  [void]$h.AppendLine(@"

--- Channel A: the Agent API (you are an end user of the app) ---
  Base URL   : $($a.baseUrl)
  Username   : $($a.username)
  Password   : $($a.password)
  Tenant     : $($a.tenant)   (you only ever see documents of this tenant)
  Plan       : $($a.plan)
  Agents     : $($a.agents -join ', ')

  Get a token first (it expires - fetch a new one per session):
    TOKEN=`$(curl -s -X POST '$($a.tokenUrl)' \
      -d grant_type=password -d client_id=$($a.clientId) \
      -d username=$($a.username) --data-urlencode 'password=$($a.password)' | jq -r .access_token)

  Then call the agent:
    curl -sS $($a.baseUrl)/chat/completions \
      -H "Authorization: Bearer `$TOKEN" -H 'Content-Type: application/json' \
      -d '{"model":"$($a.agents[0])","messages":[{"role":"user","content":"hello"}]}'

  Notes:
    - the server chooses the tools; sending your own "tools" is rejected with 400
    - asking for an agent outside your plan is rejected with 403
"@)
}

if ($doB) {
  $b = $out.channelB
  [void]$h.AppendLine(@"

--- Channel B: the model gateway (you are a developer) ---
  Base URL   : $($b.baseUrl)
  API key    : $($b.key)
  Team       : $($b.team)  ($($b.tier))
  Models     : $($b.models -join ', ')
  Rate limit : $($b.rpm) rpm     Budget: `$$($b.budgetUsd) / 30d

  OpenAI-compatible, so any SDK works:
    export OPENAI_BASE_URL=$($b.baseUrl)
    export OPENAI_API_KEY=$($b.key)

    curl -sS $($b.baseUrl)/chat/completions \
      -H "Authorization: Bearer $($b.key)" -H 'Content-Type: application/json' \
      -d '{"model":"$($b.models[0])","messages":[{"role":"user","content":"hello"}]}'

  MCP servers you may call: $($b.mcpServers -join ', ')
    $($b.mcpUrls -join "$nl    ")
    header: x-litellm-api-key: Bearer <your key>

  Allowed paths (everything else returns 404 at the gateway):
    /v1/chat/completions  /v1/responses  /v1/messages
    /v1/embeddings  /v1/rerank  /v1/models  /mcp/expert_*
"@)
}

if ($LabHost -ne 'localhost') {
  [void]$h.AppendLine(@"

--- reaching the lab from another machine ---
  The gateway routes by Host name, so keep the names and pin them to the IP:
    curl --resolve api.localhost:${GatewayPort}:${LabHost} --resolve llm.localhost:${GatewayPort}:${LabHost} ...
  Or add to /etc/hosts:
    $LabHost  api.localhost llm.localhost
"@)
}

[void]$h.AppendLine('==================================================')
Write-Host $h.ToString()

[pscustomobject]$out
