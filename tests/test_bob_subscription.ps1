Send-Billing @{ user_id = 'bob'; plan = 'pro' }                            # customer -> plan-pro
foreach ($i in 1..8) { Test-ChatCode $env:AGENT_KEY_BASIC chat-fast bob }   # ไม่โดน 429 แล้ว (rpm 60)

# plan ใน agent-api มาจาก claim ของ IdP → lab อัปเดต Keycloak เอง (production: subscription-service ทำ)
$BID = (kc get users -r lab -q username=bob --fields id --format csv --noquotes | Select-Object -First 1).Trim()
kc update "users/$BID" -r lab -s 'attributes.tenant_id=["tenant-b"]' -s 'attributes.plan=["pro"]'
$TB = Get-LabToken bob
Get-HttpCode http://api.localhost/v1/chat/completions -Method Post -Headers @{ Authorization = "Bearer $TB" } `
  -Body @{ model = 'agent/assistant-pro'; messages = @(@{ role = 'user'; content = 'hi' }) }   # 200

Send-Billing @{ user_id = 'bob'; plan = 'pro'; status = 'cancelled' }     # customer blocked
Test-ChatCode $env:AGENT_KEY_BASIC chat-fast bob                            # 4xx (blocked)

# คืน bob เป็น free ทั้ง 2 ฝั่ง (จำเป็นสำหรับ test suite ใน Step 9)
Send-Billing @{ user_id = 'bob'; plan = 'free' }
kc update "users/$BID" -r lab -s 'attributes.tenant_id=["tenant-b"]' -s 'attributes.plan=["free"]'