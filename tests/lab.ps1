# file: tests/lab.ps1
# ใช้: . .\tests\lab.ps1   (ทุกครั้งที่เปิด terminal ใหม่ หรือหลังแก้ .env)
#Requires -Version 7.4
# ถ้าขึ้น error เรื่อง version = กำลังอยู่ใน Windows PowerShell 5.1 → พิมพ์ pwsh แล้วรันใหม่
# UTF-8 without BOM: [Text.Encoding]::UTF8 emits a BOM, which native commands
# reading piped stdin (kcadm, jq, ...) reject as an invalid leading character.
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$env:PYTHONUTF8 = '1'
$LAB  = 'http://localhost:4000'
$JSON = 'application/json; charset=utf-8'

# แทน openssl rand -hex N
function New-RandHex([int]$Bytes) {
  [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes)).ToLower()
}

# เขียนไฟล์เป็น UTF-8 (ไม่มี BOM) + LF เสมอ
function Write-Lf([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path, $PWD.Path), ($Text -replace "`r`n", "`n"))
}

# แทน set -a; source .env; set +a
function Import-DotEnv([string]$Path = '.env') {
  foreach ($line in Get-Content $Path -Encoding utf8) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      Set-Item "env:$($Matches[1])" (($Matches[2] -replace '\s+#.*$', '').Trim())
    }
  }
}

# เขียน/แทนค่า NAME=VALUE ใน .env และใน session ปัจจุบัน
function Set-DotEnv([string]$Name, [string]$Value, [string]$Path = '.env') {
  $lines = @(Get-Content $Path -Encoding utf8 | Where-Object { $_ -notmatch "^$Name=" }) + "$Name=$Value"
  Write-Lf $Path (($lines -join "`n") + "`n")
  Set-Item "env:$Name" $Value
}

# POST JSON ไป LiteLLM (ค่าเริ่มต้นใช้ master key) → คืน object ที่ parse แล้ว
function Invoke-Lab([string]$Path, $Body, [string]$Key = $env:LITELLM_MASTER_KEY) {
  Invoke-RestMethod "$LAB$Path" -Method Post -Headers @{ Authorization = "Bearer $Key" } `
    -ContentType $JSON -Body ($Body | ConvertTo-Json -Depth 20 -Compress)
}

# คืนแค่ HTTP status code (แทน curl -s -o /dev/null -w "%{http_code}")
function Get-HttpCode([string]$Uri, [hashtable]$Headers = @{}, [string]$Method = 'Get', $Body) {
  $p = @{ Uri = $Uri; Method = $Method; Headers = $Headers; SkipHttpErrorCheck = $true }
  if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Depth 20 -Compress; $p.ContentType = $JSON }
  try { (Invoke-WebRequest @p).StatusCode } catch { "ERR: $($_.Exception.Message)" }
}

# = code() ของต้นฉบับ: status code ของ chat completion ผ่าน litellm-proxy
function Test-ChatCode([string]$Key, [string]$Model, [string]$User = '') {
  Get-HttpCode "$LAB/v1/chat/completions" -Method Post -Headers @{ Authorization = "Bearer $Key" } `
    -Body @{ model = $Model; user = $User; messages = @(@{ role = 'user'; content = 'hi' }) }
}

# ส่งข้อความเดียวแล้วคืน response object
function Invoke-Chat([string]$Uri, [string]$Bearer, [string]$Model, [string]$Content) {
  Invoke-RestMethod $Uri -Method Post -Headers @{ Authorization = "Bearer $Bearer" } -ContentType $JSON `
    -Body (@{ model = $Model; messages = @(@{ role = 'user'; content = $Content }) } | ConvertTo-Json -Depth 5 -Compress)
}

# = token() ของต้นฉบับ: access token จาก Keycloak (password grant)
function Get-LabToken([string]$User) {
  (Invoke-RestMethod "http://localhost:8080/realms/lab/protocol/openid-connect/token" -Method Post `
    -Body @{ grant_type = 'password'; client_id = 'lab-app'; username = $User; password = $User }).access_token
}

# = $KC ของต้นฉบับ: kcadm ใน container idp (รับ stdin ได้: ... | kc update ... -f -)
function kc { $input | docker compose exec -T idp /opt/keycloak/bin/kcadm.sh @args }

# = W ของต้นฉบับ: ส่ง billing webhook ไป subscription-service (Step 8)
function Send-Billing([hashtable]$Ev) {
  Invoke-RestMethod 'http://localhost:8090/webhook/billing' -Method Post -ContentType $JSON `
    -Headers @{ 'x-webhook-secret' = $env:WEBHOOK_SECRET } -Body ($Ev | ConvertTo-Json -Compress)
}

# พิมพ์ model_list entries ของ OPENAI_COMPATIBLE_<n>_* ทุกตัวใน .env (compat-1, compat-2, ...) → วางใน litellm/config.yaml
function Get-CompatYaml {
  Get-ChildItem env: | Where-Object Name -match '^OPENAI_COMPATIBLE_\d+_BASE_URL$' |
    Sort-Object { [int]($_.Name -replace '\D', '') } | ForEach-Object {
      $n = $_.Name -replace '\D', ''
      $m = [Environment]::GetEnvironmentVariable("OPENAI_COMPATIBLE_${n}_MODEL")
      "  - model_name: compat-$n"
      "    litellm_params:"
      "      model: openai/$m"
      "      api_base: os.environ/OPENAI_COMPATIBLE_${n}_BASE_URL"
      "      api_key: os.environ/OPENAI_COMPATIBLE_${n}_API_KEY"
      "    model_info:"
      "      access_groups: [tier-basic, tier-pro]"
    }
}

if (Test-Path .env) { Import-DotEnv }