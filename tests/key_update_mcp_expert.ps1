Set-Location C:\lab\agent-lab-ext
. .\tests\lab.ps1                       # loads LITELLM_MASTER_KEY, DEV_KEY_* and Invoke-Lab

# 1) allow expert_solution on both dev teams
foreach ($T in 'team-dev-basic', 'team-dev-pro') {
  $null = Invoke-Lab /team/update @{ team_id = $T; object_permission = @{ mcp_servers = @('expert_solution') } }
  "team $T : ok"
}

# 2) now the keys
foreach ($K in $env:DEV_KEY_BASIC, $env:DEV_KEY_PRO) {
  (Invoke-Lab /key/update @{ key = $K; object_permission = @{ mcp_servers = @('expert_solution') } }).key_alias
}

python tests/mcp_call.py "$LAB/mcp/expert_solution" $env:DEV_KEY_PRO - list     # should list ask_solution


# give both developer keys access to the expert_solution MCP server
foreach ($K in $env:DEV_KEY_BASIC, $env:DEV_KEY_PRO) {
  (Invoke-Lab /key/update @{ key = $K; object_permission = @{ mcp_servers = @('expert_solution') } }).key_alias
}