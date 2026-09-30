$M = @{ Authorization = "Bearer $env:LITELLM_MASTER_KEY" }
Invoke-RestMethod "$LAB/health/liveliness"
($models = (Invoke-RestMethod "$LAB/v1/models" -Headers $M).data.id)

(Invoke-Chat "$LAB/v1/chat/completions" $env:LITELLM_MASTER_KEY chat-fast 'ตอบคำเดียว: สวัสดี').choices[0].message.content
(Invoke-Chat "$LAB/v1/chat/completions" $env:LITELLM_MASTER_KEY chat-smart 'ตอบคำเดียว: สวัสดี').choices[0].message.content
(Invoke-Chat "$LAB/v1/chat/completions" $env:LITELLM_MASTER_KEY chat-smart-alt 'ตอบคำเดียว: สวัสดี').choices[0].message.content
(Invoke-Lab /v1/embeddings @{ model = 'embed'; input = 'ทดสอบ' }).data[0].embedding.Count
# rerank เป็น optional: ไม่มี rerank server → ไม่มี model นี้ใน config (mcp-kb ใช้ลำดับจาก vector แทน)
if ($models -contains 'rerank') {
  (Invoke-Lab /v1/rerank @{ model = 'rerank'; query = 'ภาษาไทย'; documents = @('hello', 'สวัสดีครับ') }).results[0]
} else { 'rerank: skipped (ไม่ได้ตั้งค่า)' }
