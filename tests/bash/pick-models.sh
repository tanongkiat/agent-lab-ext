#!/usr/bin/env bash
# file: tests/pick-models.sh
# interactive: pick a model per alias, test it against the endpoint, write litellm/config.yaml
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"
# shellcheck source=./lab.sh
source "$HERE/lab.sh"

cfg='litellm/config.yaml'
sql='db/init-vector.sql'
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'; C_OFF=$'\033[0m'

# 1) read the models of every endpoint
EP_N=(); EP_URL=(); EP_KEY=()
CH_N=(); CH_MODEL=()
for n in $(seq 1 50); do
  eval "url=\${OPENAI_COMPATIBLE_${n}_BASE_URL:-}"
  [ -n "$url" ] || continue
  eval "key=\${OPENAI_COMPATIBLE_${n}_API_KEY:-}"
  if ! resp="$(curl -sS --max-time 60 "$url/models" -H "Authorization: Bearer $key" 2>&1)" \
     || ! ids="$(printf '%s' "$resp" | jq -r '.data[].id' 2>/dev/null | sort)" || [ -z "$ids" ]; then
    echo "${C_RED}endpoint $n  $url  ERROR: ${resp}${C_OFF}"
    continue
  fi
  echo "endpoint $n  $url  ($(printf '%s\n' "$ids" | wc -l | tr -d ' ') models)"
  EP_N+=("$n"); EP_URL+=("$url"); EP_KEY+=("$key")
  while IFS= read -r m; do CH_N+=("$n"); CH_MODEL+=("$m"); done <<< "$ids"
done
if [ "${#EP_N[@]}" -eq 0 ]; then
  echo 'ไม่พบ endpoint ที่ใช้ได้ใน .env (OPENAI_COMPATIBLE_<n>_BASE_URL)' >&2; exit 1
fi

ep_field() { # $1 = n, $2 = url|key
  local i
  for i in "${!EP_N[@]}"; do
    if [ "${EP_N[$i]}" = "$1" ]; then
      [ "$2" = url ] && printf '%s' "${EP_URL[$i]}" || printf '%s' "${EP_KEY[$i]}"
      return
    fi
  done
}

# 2) selection menu (filterable, in case an endpoint has many models)
PICK_N=''; PICK_MODEL=''
pick() { # $1 = alias, $2 = hint, $3 = optional (1/0) -> sets PICK_N / PICK_MODEL, returns 1 when skipped
  local alias="$1" hint="$2" optional="$3" f a i n idx
  printf '\n%s== %s : %s%s\n' "$C_CYA" "$alias" "$hint" "$C_OFF"
  while true; do
    read -r -p 'คำค้นชื่อ model (Enter = แสดงทั้งหมด): ' f
    local -a sel_i=()
    for i in "${!CH_MODEL[@]}"; do
      if [ -z "$f" ] || [[ "${CH_MODEL[$i]}" == *"$f"* ]]; then sel_i+=("$i"); fi
    done
    if [ "${#sel_i[@]}" -eq 0 ]; then printf '%sไม่พบ ลองคำอื่น%s\n' "$C_YEL" "$C_OFF"; continue; fi
    for n in "${!sel_i[@]}"; do
      idx="${sel_i[$n]}"
      printf '%4d) [endpoint %s] %s\n' "$((n + 1))" "${CH_N[$idx]}" "${CH_MODEL[$idx]}"
    done
    [ "$optional" = 1 ] && echo '   0) ไม่ใช้'
    read -r -p 'เลือกหมายเลข (Enter = ค้นใหม่): ' a
    if [ "$optional" = 1 ] && [ "$a" = '0' ]; then return 1; fi
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#sel_i[@]}" ]; then
      idx="${sel_i[$((a - 1))]}"
      PICK_N="${CH_N[$idx]}"; PICK_MODEL="${CH_MODEL[$idx]}"
      return 0
    fi
  done
}

# 3) test the capabilities the lab needs, straight against the endpoint (not through LiteLLM)
invoke_ep() { # $1 = n, $2 = path, $3 = json body
  curl -sS --max-time 120 -X POST "$(ep_field "$1" url)$2" \
    -H "Authorization: Bearer $(ep_field "$1" key)" -H "Content-Type: $JSON" -d "$3"
}

TEST_OK=0; TEST_MSG=''; TEST_DIM=''
_pass() { TEST_OK=1; TEST_MSG="$1"; TEST_DIM="${2:-}"; }
_fail() { TEST_OK=0; TEST_MSG="$1"; TEST_DIM=''; }

test_model() { # $1 = kind, $2 = endpoint n, $3 = model
  local kind="$1" n="$2" model="$3" tool msgs req resp msg tc targs tname tquery txt d cnt
  TEST_OK=0; TEST_MSG=''; TEST_DIM=''
  case "$kind" in
    tools)  # agent-api / expert: the model must call a tool and then answer from the tool result
      tool='{"type":"function","function":{"name":"search_docs","description":"Search internal documents","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}'
      msgs="$(jq -nc '[{role:"system",content:"ใช้ tool search_docs ค้นเอกสารก่อนตอบทุกครั้ง"},
                       {role:"user",content:"webhook ของ payment retry กี่ครั้ง"}]')"
      req="$(jq -nc --arg m "$model" --argjson msgs "$msgs" --argjson t "$tool" \
        '{model:$m, messages:$msgs, tools:[$t], max_tokens:400}')"
      resp="$(invoke_ep "$n" '/chat/completions' "$req")"
      if ! msg="$(printf '%s' "$resp" | jq -ce '.choices[0].message' 2>/dev/null)"; then
        _fail "error: $resp"; return
      fi
      if ! tc="$(printf '%s' "$msg" | jq -ce '.tool_calls[0] // empty' 2>/dev/null)" || [ -z "$tc" ]; then
        _fail 'ไม่เรียก tool: model ไม่รองรับ tool calling หรือ server ไม่ได้เปิด (vLLM: --enable-auto-tool-choice --tool-call-parser)'
        return
      fi
      if ! targs="$(printf '%s' "$tc" | jq -r '.function.arguments' | jq -ce . 2>/dev/null)"; then
        _fail "arguments ไม่ใช่ JSON: $(printf '%s' "$tc" | jq -r '.function.arguments')"; return
      fi
      tname="$(printf '%s' "$tc" | jq -r '.function.name')"
      tquery="$(printf '%s' "$targs" | jq -r '.query // empty')"
      if [[ "$tname" != *search_docs ]] || [ -z "$tquery" ]; then
        _fail "เรียก tool ผิดรูปแบบ: $tname $(printf '%s' "$tc" | jq -r '.function.arguments')"; return
      fi
      msgs="$(jq -nc --argjson msgs "$msgs" --argjson m "$msg" --arg id "$(printf '%s' "$tc" | jq -r '.id')" \
        '$msgs + [{role:"assistant", content:$m.content, tool_calls:[$m.tool_calls[0]]},
                  {role:"tool", tool_call_id:$id,
                   content:"ADR-001: retry 5 ครั้ง (1, 2, 4, 8, 16 นาที) แล้วส่งเข้า payment-webhook-dlq"}]')"
      req="$(jq -nc --arg m "$model" --argjson msgs "$msgs" --argjson t "$tool" \
        '{model:$m, messages:$msgs, tools:[$t], max_tokens:400}')"
      resp="$(invoke_ep "$n" '/chat/completions' "$req")"
      txt="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
      if [ -z "$txt" ]; then _fail 'ส่งผลของ tool กลับไปแล้วไม่ได้คำตอบเป็นข้อความ'; return; fi
      _pass "tool calling ครบ 2 รอบ (query: $tquery)"
      ;;
    embed)  # ingest-worker sends several strings at once · pgvector hnsw takes at most 2000 dims
      resp="$(invoke_ep "$n" '/embeddings' "$(jq -nc --arg m "$model" '{model:$m, input:["ทดสอบ","hello"]}')")"
      if ! cnt="$(printf '%s' "$resp" | jq -e '.data | length' 2>/dev/null)"; then _fail "error: $resp"; return; fi
      d="$(printf '%s' "$resp" | jq -r '.data[0].embedding | length')"
      if [ "$cnt" -ne 2 ]; then _fail "ส่ง 2 ข้อความได้ $cnt vector (ต้องรองรับ batch)"; return; fi
      if [ "$d" -lt 1 ]; then _fail 'ไม่ได้ vector กลับมา'; return; fi
      if [ "$d" -gt 2000 ]; then _fail "$d มิติ เกิน 2000 ที่ index hnsw ของ pgvector รับได้"; return; fi
      _pass "$d มิติ · รองรับ batch" "$d"
      ;;
    rerank)  # mcp-kb uses results[].index
      resp="$(invoke_ep "$n" '/rerank' "$(jq -nc --arg m "$model" \
        '{model:$m, query:"ภาษาไทย", documents:["hello","สวัสดีครับ"], top_n:2}')")"
      if ! d="$(printf '%s' "$resp" | jq -e '.results[0].index' 2>/dev/null)"; then
        _fail 'ผลลัพธ์ไม่มี results[].index'; return
      fi
      _pass "อันดับแรก = index $d (ควรเป็น 1)"
      ;;
  esac
}

# alias table (kept in order)
AL_NAME=(chat-fast chat-smart chat-smart-alt embed rerank)
AL_HINT=(
  'model เล็ก เร็ว · ต้องรองรับ tool calling'
  'model ใหญ่ · ต้องรองรับ tool calling'
  'fallback ของ chat-smart · ควรคนละ endpoint · ต้องรองรับ tool calling'
  'embedding model · batch ได้ · ไม่เกิน 2000 มิติ'
  'rerank model (vLLM/Infinity) · 0 = ไม่ใช้'
)
AL_GROUPS=('tier-basic, tier-pro' 'tier-pro' 'tier-pro' 'retrieval, tier-basic, tier-pro' 'retrieval, tier-basic, tier-pro')
AL_PREFIX=(openai openai openai openai hosted_vllm)
AL_OPTIONAL=(0 0 0 0 1)
AL_TEST=(tools tools tools embed rerank)

PICKED_NAME=(); PICKED_N=(); PICKED_MODEL=()
dim=''
picked_index() { # $1 = alias -> echoes its index in PICKED_*, or nothing
  local i
  for i in "${!PICKED_NAME[@]}"; do [ "${PICKED_NAME[$i]}" = "$1" ] && { printf '%s' "$i"; return; }; done
}

for ai in "${!AL_NAME[@]}"; do
  a="${AL_NAME[$ai]}"
  while true; do
    pick "$a" "${AL_HINT[$ai]}" "${AL_OPTIONAL[$ai]}" || break
    echo "  กำลังทดสอบ $PICK_MODEL ..."
    test_model "${AL_TEST[$ai]}" "$PICK_N" "$PICK_MODEL"
    if [ "$TEST_OK" = 1 ]; then
      printf '  %sPASS %s%s\n' "$C_GRN" "$TEST_MSG" "$C_OFF"
    else
      printf '  %sFAIL %s%s\n' "$C_RED" "$TEST_MSG" "$C_OFF"
      read -r -p '  ใช้ตัวนี้ต่อทั้งที่ไม่ผ่าน? (y = ใช้, Enter = เลือกใหม่): ' ans
      [ "$ans" = 'y' ] || continue
    fi
    if [ "$a" = 'chat-smart-alt' ]; then
      si="$(picked_index chat-smart)"
      if [ -n "$si" ] && [ "${PICKED_N[$si]}" = "$PICK_N" ]; then
        printf '  %sWARN อยู่ endpoint เดียวกับ chat-smart: ถ้า endpoint นี้ล่ม fallback จะล่มด้วย%s\n' "$C_YEL" "$C_OFF"
      fi
    fi
    [ -n "$TEST_DIM" ] && dim="$TEST_DIM"
    PICKED_NAME+=("$a"); PICKED_N+=("$PICK_N"); PICKED_MODEL+=("$PICK_MODEL")
    break
  done
done

# 4) write the new model_list into config.yaml (replace only model_list: up to router_settings:)
block="$(mktemp)"
{
  echo 'model_list:'
  for i in "${!PICKED_NAME[@]}"; do
    a="${PICKED_NAME[$i]}"
    for ai in "${!AL_NAME[@]}"; do [ "${AL_NAME[$ai]}" = "$a" ] && break; done
    echo "  - model_name: $a"
    echo '    litellm_params:'
    echo "      model: ${AL_PREFIX[$ai]}/${PICKED_MODEL[$i]}"
    echo "      api_base: os.environ/OPENAI_COMPATIBLE_${PICKED_N[$i]}_BASE_URL"
    echo "      api_key: os.environ/OPENAI_COMPATIBLE_${PICKED_N[$i]}_API_KEY"
    echo '    model_info:'
    echo "      access_groups: [${AL_GROUPS[$ai]}]"
  done
  echo ''
} > "$block"

if ! grep -qE '^model_list:' "$cfg" || ! grep -qE '^router_settings:' "$cfg"; then
  echo "$cfg ต้องมีทั้ง model_list: และ router_settings:" >&2; rm -f "$block"; exit 1
fi
bak="$cfg.bak-$(date +%Y%m%d-%H%M%S)"; cp "$cfg" "$bak"
awk -v blockfile="$block" '
  /^router_settings:/ { inblock = 0 }
  /^model_list:/ && !seen { seen = 1; inblock = 1; while ((getline l < blockfile) > 0) print l; next }
  inblock { next }
  { print }
' "$bak" | tr -d '\r' > "$cfg"
rm -f "$block"

# 5) dimension count -> .env and db/init-vector.sql
if [ -n "$dim" ]; then
  set_dotenv EMBED_DIM "$dim"
  if [ -f "$sql" ]; then
    if grep -qE 'vector\([0-9]+\)' "$sql" && ! grep -qE "vector\($dim\)" "$sql"; then
      sed -E -i '' "s/vector\([0-9]+\)/vector($dim)/g" "$sql"
      printf '%sแก้ %s เป็น vector(%s) แล้ว · ถ้า vector-db เคยเปิดแล้วต้อง reset (Troubleshooting)%s\n' "$C_YEL" "$sql" "$dim" "$C_OFF"
    fi
  elif [ "$dim" != 1536 ]; then
    printf '%sตอนทำ Step 4.1 ให้ใช้ vector(%s) แทน vector(1536)%s\n' "$C_YEL" "$dim" "$C_OFF"
  fi
elif [ -n "$(picked_index embed)" ]; then
  printf '%sไม่รู้จำนวนมิติของ embed (ทดสอบไม่ผ่าน) · ตรวจเองใน Step 1.4 ก่อนทำ Step 4.1%s\n' "$C_YEL" "$C_OFF"
fi

printf '\n%sเขียน model_list ลง %s แล้ว (ไฟล์เดิมสำรองที่ %s)%s\n' "$C_GRN" "$cfg" "$bak" "$C_OFF"
for i in "${!PICKED_NAME[@]}"; do
  printf '%-15s endpoint %s  %s\n' "${PICKED_NAME[$i]}" "${PICKED_N[$i]}" "${PICKED_MODEL[$i]}"
done
echo 'ต่อไป: docker compose up -d litellm-proxy แล้วทำ Step 1.4'
