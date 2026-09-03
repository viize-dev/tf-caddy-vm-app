/**
 * tf-caddy-vm-app — เอาแอป docker-compose ไปเกาะ VM ที่มี Caddy อยู่แล้ว
 *
 * module นี้ **ไม่สร้าง VM / network / firewall / DNS** — อ่านของเดิมด้วย data source
 * เพราะทรัพยากรพวกนั้นเป็นของ terraform ชุดที่สร้าง VM ถ้าประกาศซ้ำจะแย่งกันคุม
 *
 * เงื่อนไขของ VM ปลายทาง:
 *   1. มี Docker + docker compose
 *   2. มีคอนเทนเนอร์ Caddy ที่ Caddyfile หลัก `import <caddy_conf_dir>/*.caddy`
 *   3. เข้าถึงได้ผ่าน gcloud compute ssh --tunnel-through-iap
 *
 * ⚠️ ค่าลับไม่อยู่ใน state — env จริงกรอกครั้งเดียวที่ <remote_dir>/.env บน VM
 *    ส่วน auth_token ส่งผ่าน TF_VAR ตอน apply เท่านั้น (ยังโผล่ใน state ได้ ถ้ากังวลให้ปล่อยว่าง
 *    แล้วใส่ auth ที่ชั้นแอปแทน)
 */
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }
}
