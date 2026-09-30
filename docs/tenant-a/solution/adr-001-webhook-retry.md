# ADR-001 Webhook retry ของ payment service

ตัดสินใจใช้ exponential backoff 5 ครั้ง (1, 2, 4, 8, 16 นาที) พร้อม idempotency key ใน header X-Idempotency-Key

ถ้าครบ 5 ครั้งแล้วยังล้ม ให้ส่งเข้า dead-letter queue ชื่อ payment-webhook-dlq และแจ้งทีม on-call