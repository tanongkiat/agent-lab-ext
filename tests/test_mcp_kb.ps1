foreach ($K in $env:AGENT_KEY_BASIC, $env:AGENT_KEY_PRO, $env:EXPERT_KEY) {
  (Invoke-Lab /key/update @{ key = $K; object_permission = @{ mcp_servers = @('kb') } }).key_alias
}