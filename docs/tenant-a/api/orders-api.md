# Orders API (Tenant A)

เรียกด้วย OAuth2 client credentials scope orders.read และ orders.write

GET /v2/orders/{id} คืนสถานะ order · POST /v2/orders ต้องส่ง X-Idempotency-Key ทุกครั้ง