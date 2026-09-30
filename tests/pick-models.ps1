# file: tests/pick-models.ps1
#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.ps1"
$cfg = 'litellm/config.yaml'
$sql = 'db/init-vector.sql'

# 1) อ่าน model จากทุก endpoint
$eps = foreach ($n in 1..50) {
  $url = [Environment]::GetEnvironmentVariable("OPENAI_COMPATIBLE_${n}_BASE_URL"); if (-not $url) { continue }
  $key = [Environment]::GetEnvironmentVariable("OPENAI_COMPATIBLE_${n}_API_KEY")
  try {
    $ids = @((Invoke-RestMethod "$url/models" -Headers @{ Authorization = "Bearer $key" }).data.id | Sort-Object)
    Write-Host "endpoint $n  $url  ($($ids.Count) models)"
    [pscustomobject]@{ N = $n; Url = $url; Key = $key; Models = $ids }
  } catch { Write-Host "endpoint $n  $url  ERROR: $($_.Exception.Message)" -ForegroundColor Red }
}
if (-not $eps) { throw 'ไม่พบ endpoint ที่ใช้ได้ใน .env (OPENAI_COMPATIBLE_<n>_BASE_URL)' }
$choices = @(foreach ($e in $eps) { foreach ($m in $e.Models) { [pscustomobject]@{ N = $e.N; Model = $m } } })

# 2) เมนูเลือก (กรองด้วยคำค้นได้ เผื่อ endpoint มี model เยอะ)
function Pick([string]$Alias, [string]$Hint, [bool]$Optional) {
  Write-Host "`n== $Alias : $Hint" -ForegroundColor Cyan
  while ($true) {
    $f = Read-Host 'คำค้นชื่อ model (Enter = แสดงทั้งหมด)'
    $list = @($choices | Where-Object { -not $f -or $_.Model -like "*$f*" })
    if (-not $list) { Write-Host 'ไม่พบ ลองคำอื่น' -ForegroundColor Yellow; continue }
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('{0,4}) [endpoint {1}] {2}' -f ($i + 1), $list[$i].N, $list[$i].Model) }
    if ($Optional) { Write-Host '   0) ไม่ใช้' }
    $a = Read-Host 'เลือกหมายเลข (Enter = ค้นใหม่)'
    if ($Optional -and $a -eq '0') { return $null }
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $list.Count) { return $list[[int]$a - 1] }
  }
}

# 3) ทดสอบคุณสมบัติที่ lab ต้องใช้ ตรงกับ endpoint (ไม่ผ่าน LiteLLM)
function Invoke-Ep($P, [string]$Path, $Body) {
  $ep = $eps | Where-Object N -eq $P.N
  Invoke-RestMethod "$($ep.Url)$Path" -Method Post -Headers @{ Authorization = "Bearer $($ep.Key)" } `
    -ContentType $JSON -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 120
}
function Pass($Msg, $Dim) { @{ Ok = $true; Msg = $Msg; Dim = $Dim } }
function Fail($Msg) { @{ Ok = $false; Msg = $Msg } }

function Test-Model([string]$Kind, $P) {
  try {
    switch ($Kind) {
      'tools' {   # agent-api / expert: model ต้องเรียก tool แล้วตอบต่อจากผลของ tool ได้
        $tool = @{ type = 'function'; function = @{ name = 'search_docs'; description = 'Search internal documents'
            parameters = @{ type = 'object'; properties = @{ query = @{ type = 'string' } }; required = @('query') } } }
        $msgs = @(@{ role = 'system'; content = 'ใช้ tool search_docs ค้นเอกสารก่อนตอบทุกครั้ง' },
                  @{ role = 'user'; content = 'webhook ของ payment retry กี่ครั้ง' })
        $m = (Invoke-Ep $P '/chat/completions' @{ model = $P.Model; messages = $msgs; tools = @($tool); max_tokens = 400 }).choices[0].message
        if (-not $m.tool_calls) { return Fail 'ไม่เรียก tool: model ไม่รองรับ tool calling หรือ server ไม่ได้เปิด (vLLM: --enable-auto-tool-choice --tool-call-parser)' }
        $tc = $m.tool_calls[0]
        try { $targs = $tc.function.arguments | ConvertFrom-Json } catch { return Fail "arguments ไม่ใช่ JSON: $($tc.function.arguments)" }
        if ($tc.function.name -notlike '*search_docs' -or -not $targs.query) { return Fail "เรียก tool ผิดรูปแบบ: $($tc.function.name) $($tc.function.arguments)" }
        $msgs += @{ role = 'assistant'; content = $m.content; tool_calls = @($m.tool_calls) }
        $msgs += @{ role = 'tool'; tool_call_id = $tc.id; content = 'ADR-001: retry 5 ครั้ง (1, 2, 4, 8, 16 นาที) แล้วส่งเข้า payment-webhook-dlq' }
        $txt = (Invoke-Ep $P '/chat/completions' @{ model = $P.Model; messages = $msgs; tools = @($tool); max_tokens = 400 }).choices[0].message.content
        if (-not $txt) { return Fail 'ส่งผลของ tool กลับไปแล้วไม่ได้คำตอบเป็นข้อความ' }
        return Pass "tool calling ครบ 2 รอบ (query: $($targs.query))"
      }
      'embed' {   # ingest-worker ส่งหลายข้อความในครั้งเดียว · pgvector hnsw รับได้ไม่เกิน 2000 มิติ
        $r = Invoke-Ep $P '/embeddings' @{ model = $P.Model; input = @('ทดสอบ', 'hello') }
        $d = $r.data[0].embedding.Count
        if ($r.data.Count -ne 2) { return Fail "ส่ง 2 ข้อความได้ $($r.data.Count) vector (ต้องรองรับ batch)" }
        if ($d -lt 1) { return Fail 'ไม่ได้ vector กลับมา' }
        if ($d -gt 2000) { return Fail "$d มิติ เกิน 2000 ที่ index hnsw ของ pgvector รับได้" }
        return Pass "$d มิติ · รองรับ batch" $d
      }
      'rerank' {  # mcp-kb ใช้ results[].index
        $r = Invoke-Ep $P '/rerank' @{ model = $P.Model; query = 'ภาษาไทย'; documents = @('hello', 'สวัสดีครับ'); top_n = 2 }
        if (-not $r.results -or $null -eq $r.results[0].index) { return Fail 'ผลลัพธ์ไม่มี results[].index' }
        return Pass "อันดับแรก = index $($r.results[0].index) (ควรเป็น 1)"
      }
    }
  } catch { return Fail "error: $($_.ErrorDetails.Message ?? $_.Exception.Message)" }
}

$aliases = [ordered]@{
  'chat-fast'      = @{ Hint = 'model เล็ก เร็ว · ต้องรองรับ tool calling'; Groups = 'tier-basic, tier-pro'; Prefix = 'openai'; Optional = $false; Test = 'tools' }
  'chat-smart'     = @{ Hint = 'model ใหญ่ · ต้องรองรับ tool calling'; Groups = 'tier-pro'; Prefix = 'openai'; Optional = $false; Test = 'tools' }
  'chat-smart-alt' = @{ Hint = 'fallback ของ chat-smart · ควรคนละ endpoint · ต้องรองรับ tool calling'; Groups = 'tier-pro'; Prefix = 'openai'; Optional = $false; Test = 'tools' }
  'embed'          = @{ Hint = 'embedding model · batch ได้ · ไม่เกิน 2000 มิติ'; Groups = 'retrieval, tier-basic, tier-pro'; Prefix = 'openai'; Optional = $false; Test = 'embed' }
  'rerank'         = @{ Hint = 'rerank model (vLLM/Infinity) · 0 = ไม่ใช้'; Groups = 'retrieval, tier-basic, tier-pro'; Prefix = 'hosted_vllm'; Optional = $true; Test = 'rerank' }
}
$picked = [ordered]@{}; $dim = $null
foreach ($a in $aliases.Keys) {
  while ($true) {
    $p = Pick $a $aliases[$a].Hint $aliases[$a].Optional
    if (-not $p) { break }
    Write-Host "  กำลังทดสอบ $($p.Model) ..."
    $r = Test-Model $aliases[$a].Test $p
    if ($r.Ok) { Write-Host "  PASS $($r.Msg)" -ForegroundColor Green }
    else {
      Write-Host "  FAIL $($r.Msg)" -ForegroundColor Red
      if ((Read-Host '  ใช้ตัวนี้ต่อทั้งที่ไม่ผ่าน? (y = ใช้, Enter = เลือกใหม่)') -ne 'y') { continue }
    }
    if ($a -eq 'chat-smart-alt' -and $picked['chat-smart'] -and $p.N -eq $picked['chat-smart'].N) {
      Write-Host '  WARN อยู่ endpoint เดียวกับ chat-smart: ถ้า endpoint นี้ล่ม fallback จะล่มด้วย' -ForegroundColor Yellow
    }
    if ($r.Dim) { $dim = $r.Dim }
    $picked[$a] = $p; break
  }
}

# 4) เขียน model_list ใหม่ลง config.yaml (แทนเฉพาะช่วง model_list: ถึงก่อน router_settings:)
$yaml = @('model_list:')
foreach ($a in $picked.Keys) {
  $p = $picked[$a]; $s = $aliases[$a]
  $yaml += "  - model_name: $a"
  $yaml += '    litellm_params:'
  $yaml += "      model: $($s.Prefix)/$($p.Model)"
  $yaml += "      api_base: os.environ/OPENAI_COMPATIBLE_$($p.N)_BASE_URL"
  $yaml += "      api_key: os.environ/OPENAI_COMPATIBLE_$($p.N)_API_KEY"
  $yaml += '    model_info:'
  $yaml += "      access_groups: [$($s.Groups)]"
}
$block = ($yaml -join "`n") + "`n`n"
$text = Get-Content $cfg -Raw -Encoding utf8
if ($text -notmatch '(?m)^model_list:' -or $text -notmatch '(?m)^router_settings:') { throw "$cfg ต้องมีทั้ง model_list: และ router_settings:" }
$bak = "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"; Copy-Item $cfg $bak
Write-Lf $cfg ([regex]::Replace($text, '(?ms)^model_list:.*?(?=^router_settings:)', { param($m) $block }))

# 5) จำนวนมิติ → .env และ db/init-vector.sql
if ($dim) {
  Set-DotEnv EMBED_DIM $dim
  if (Test-Path $sql) {
    $old = Get-Content $sql -Raw -Encoding utf8; $new = $old -replace 'vector\(\d+\)', "vector($dim)"
    if ($new -ne $old) { Write-Lf $sql $new; Write-Host "แก้ $sql เป็น vector($dim) แล้ว · ถ้า vector-db เคยเปิดแล้วต้อง reset (Troubleshooting)" -ForegroundColor Yellow }
  } elseif ($dim -ne 1536) { Write-Host "ตอนทำ Step 4.1 ให้ใช้ vector($dim) แทน vector(1536)" -ForegroundColor Yellow }
} elseif ($picked['embed']) { Write-Host 'ไม่รู้จำนวนมิติของ embed (ทดสอบไม่ผ่าน) · ตรวจเองใน Step 1.4 ก่อนทำ Step 4.1' -ForegroundColor Yellow }

Write-Host "`nเขียน model_list ลง $cfg แล้ว (ไฟล์เดิมสำรองที่ $bak)" -ForegroundColor Green
foreach ($a in $picked.Keys) { '{0,-15} endpoint {1}  {2}' -f $a, $picked[$a].N, $picked[$a].Model }
Write-Host 'ต่อไป: docker compose up -d litellm-proxy แล้วทำ Step 1.4'