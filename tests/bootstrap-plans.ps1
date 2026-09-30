# file: tests/bootstrap-plans.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)   # ทำงานที่ root ของ agent-lab-ext เสมอ
. "$PSScriptRoot\lab.ps1"
function k($Body) { (Invoke-Lab /key/generate $Body).key }

Write-Host '== budgets ต่อ plan (ค่าต่ำเพื่อทดสอบการตัด)'
$null = Invoke-Lab /budget/new @{ budget_id = 'plan-free'; max_budget = 0.02; budget_duration = '30d'; rpm_limit = 5; tpm_limit = 20000 }
$null = Invoke-Lab /budget/new @{ budget_id = 'plan-pro'; max_budget = 1; budget_duration = '30d'; rpm_limit = 60; tpm_limit = 200000 }

Write-Host '== end-users (customers)'
$null = Invoke-Lab /customer/new @{ user_id = 'alice'; budget_id = 'plan-pro' }
$null = Invoke-Lab /customer/new @{ user_id = 'bob'; budget_id = 'plan-free' }

Write-Host '== teams ของ Dev plans'
$null = Invoke-Lab /team/new @{ team_id = 'team-dev-basic'; team_alias = 'team-dev-basic'; models = @('tier-basic'); rpm_limit = 300 }
$null = Invoke-Lab /team/new @{ team_id = 'team-dev-pro'; team_alias = 'team-dev-pro'; models = @('tier-pro'); rpm_limit = 1000 }

Write-Host '== service keys'
Set-DotEnv AGENT_KEY_BASIC (k @{ key_alias = 'agent-api-basic'; models = @('tier-basic') })
Set-DotEnv AGENT_KEY_PRO   (k @{ key_alias = 'agent-api-pro'; models = @('tier-pro') })
Set-DotEnv EXPERT_KEY      (k @{ key_alias = 'expert-mcp'; models = @('tier-pro') })
Set-DotEnv RETRIEVAL_KEY   (k @{ key_alias = 'retrieval'; models = @('retrieval') })
Set-DotEnv INGEST_KEY      (k @{ key_alias = 'ingest'; models = @('embed') })

Write-Host '== developers + keys ใต้ team'
$null = Invoke-Lab /user/new @{ user_id = 'dev-basic-user'; user_role = 'internal_user' }
$null = Invoke-Lab /user/new @{ user_id = 'dev-pro-user'; user_role = 'internal_user' }
$null = Invoke-Lab /team/member_add @{ team_id = 'team-dev-basic'; member = @{ user_id = 'dev-basic-user'; role = 'user' }; max_budget_in_team = 0.05 }
$null = Invoke-Lab /team/member_add @{ team_id = 'team-dev-pro'; member = @{ user_id = 'dev-pro-user'; role = 'user' }; max_budget_in_team = 1 }
Set-DotEnv DEV_KEY_BASIC (k @{ key_alias = 'dev-basic'; team_id = 'team-dev-basic'; user_id = 'dev-basic-user'; rpm_limit = 30 })
Set-DotEnv DEV_KEY_PRO   (k @{ key_alias = 'dev-pro'; team_id = 'team-dev-pro'; user_id = 'dev-pro-user'; rpm_limit = 120 })

Write-Host '== admin key ของ subscription-service (แยกจาก master key)'
$null = Invoke-Lab /user/new @{ user_id = 'subscription-service'; user_role = 'proxy_admin' }
Set-DotEnv SUB_ADMIN_KEY (k @{ key_alias = 'subscription-admin'; user_id = 'subscription-service' })

Write-Host 'done'
Select-String -Path .env -Pattern '^(AGENT|EXPERT|RETRIEVAL|INGEST|DEV|SUB)_' |
  ForEach-Object { $_.Line.Substring(0, [Math]::Min(28, $_.Line.Length)) }