# ── ปลายทาง ─────────────────────────────────────────────────────────────────
variable "project_id" {
  description = "GCP project ที่ VM อยู่"
  type        = string
}

variable "zone" {
  description = "zone ของ VM"
  type        = string
}

variable "vm_name" {
  description = "ชื่อ VM ที่มีอยู่แล้ว (module นี้ไม่สร้าง VM)"
  type        = string
}

# ── ตัวแอป ──────────────────────────────────────────────────────────────────
variable "app_name" {
  description = "slug ของแอป (a-z0-9-) ใช้ตั้งชื่อไฟล์ vhost, cron, โฟลเดอร์"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,39}$", var.app_name))
    error_message = "app_name ต้องเป็น a-z 0-9 - ยาวไม่เกิน 40 ตัว"
  }
}

variable "source_dir" {
  description = "โฟลเดอร์ในเครื่องที่จะส่งขึ้น VM (ต้องมี compose file อยู่ข้างใน)"
  type        = string
}

variable "compose_file" {
  description = "ชื่อ compose file ใน source_dir — จะถูกส่งไปเป็น docker-compose.yml บน VM"
  type        = string
  default     = "docker-compose.prod.yml"
}

variable "source_paths" {
  description = "path (relative กับ source_dir) ที่จะส่งขึ้น VM — ใส่เฉพาะที่จำเป็น"
  type        = list(string)
}

variable "source_excludes" {
  description = <<-EOT
    pattern ที่จะไม่ส่งขึ้น VM

    ค่าเริ่มต้นครอบ `._*` ไว้แล้ว: bsdtar บน macOS แนบ AppleDouble (ไฟล์ ._xxx
    ที่เก็บ extended attribute) มาด้วยทุกไฟล์ ซึ่งไม่ใช่ UTF-8 แล้วแอปที่ไล่อ่าน
    ไฟล์ทั้งโฟลเดอร์จะพังด้วย UnicodeDecodeError
  EOT
  type        = list(string)
  default     = ["._*", "__pycache__", ".venv", ".git", "node_modules"]
}

variable "remote_dir" {
  description = "ที่วางไฟล์บน VM — ปล่อยว่าง = /opt/<app_name>"
  type        = string
  default     = ""
}

# ── เครือข่าย ───────────────────────────────────────────────────────────────
variable "domain" {
  description = "โดเมนของแอป — ต้องชี้มาที่ VM ก่อน apply"
  type        = string
}

variable "host_port" {
  description = <<-EOT
    พอร์ตบนโฮสต์ที่คอนเทนเนอร์ publish (ต้อง bind 127.0.0.1 ใน compose)
    ⚠️ ห้ามชนกับแอปอื่นบนเครื่องเดียวกัน — deploy.sh ตรวจให้ก่อน apply
  EOT
  type        = number
}

variable "caddy_conf_dir" {
  description = "โฟลเดอร์ vhost ของ Caddy บนโฮสต์ (ที่ Caddyfile หลัก import)"
  type        = string
  default     = "/mnt/data/caddy/conf.d"
}

variable "caddy_container" {
  description = "ชื่อคอนเทนเนอร์ Caddy บน VM (ใช้สั่ง reload)"
  type        = string
  default     = "caddy"
}

variable "long_lived_stream" {
  description = <<-EOT
    true = ตั้ง read/write timeout ของ reverse_proxy เป็น 0

    เปิดเมื่อแอปใช้ SSE / streamable-http / websocket ไม่งั้น proxy
    จะตัด connection กลางคันโดยที่ log ฝั่งแอปไม่เห็นอะไรผิดปกติเลย
  EOT
  type        = bool
  default     = false
}

variable "auth_token" {
  description = <<-EOT
    Bearer token ที่ Caddy บังคับก่อน proxy — ปล่อยว่าง = เปิดสาธารณะ

    ⚠️ deploy.sh อ่านค่าเดิมจาก vhost บน VM ให้อัตโนมัติ ถ้า apply ตรง ๆ
       โดยไม่ส่งค่านี้ vhost จะถูกเขียนทับเป็นแบบไม่มี auth แล้ว client เดิมจะ 401
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# ── env / health / cron ─────────────────────────────────────────────────────
variable "env_keys" {
  description = <<-EOT
    รายชื่อ env ที่แอปต้องใช้ — module สร้าง .env โครงเปล่าให้ครั้งแรกแล้ว **หยุด**
    ให้ไปกรอกค่าจริงบน VM เอง (ค่าลับจะได้ไม่ผ่าน terraform state)

    ใส่ค่าเริ่มต้นได้ด้วยรูปแบบ "KEY=value" เช่น ["PORT=8080", "DB_PASSWORD"]
  EOT
  type        = list(string)
  default     = []
}

variable "health_path" {
  description = "path ที่ใช้เช็คว่าแอปขึ้นแล้ว (เทียบกับ 127.0.0.1:host_port) ปล่อยว่าง = ข้าม"
  type        = string
  default     = "/"
}

variable "health_ok_codes" {
  description = "regex ของ HTTP code ที่ถือว่าแอปขึ้นแล้ว (บาง endpoint ตอบ 4xx เมื่อ request ไม่ครบ แต่แปลว่ามันฟังอยู่)"
  type        = string
  default     = "2..|3..|4.."
}

variable "cron_schedule" {
  description = <<-EOT
    ตาราง cron บน VM (เวลาเครื่อง = UTC) ปล่อยว่าง = ไม่ตั้ง cron

    เลี่ยงนาที 0 และ 30 ถ้างานไม่ได้ผูกกับเวลาเป๊ะ ๆ — ทุกคนตั้ง :00 กันหมด
  EOT
  type        = string
  default     = ""
}

variable "cron_command" {
  description = "คำสั่งที่ cron รัน (รันในไดเรกทอรี remote_dir) เช่น 'docker compose exec -T app python job.py'"
  type        = string
  default     = ""
}
