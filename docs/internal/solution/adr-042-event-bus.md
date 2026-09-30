# ADR-042 เลือก event bus ของ platform

เลือก Kafka สำหรับ event ระหว่าง service และใช้ outbox pattern ในทุก service ที่เขียน DB แล้วส่ง event

ห้าม publish event ตรงจาก transaction ของ DB เพราะจะเกิด dual-write · retry ใช้ exponential backoff และ idempotent consumer