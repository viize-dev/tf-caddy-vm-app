/**
 * ตัวอย่างจริง: property-llm-wiki (MCP server + cron refresh)
 *
 * เกาะ VM fastagent-prod ที่มี Caddy อยู่แล้ว โดยไม่แตะ resource ของ fastagent
 */
terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    bucket = "taladbaanteedin-tfstate"
    prefix = "property-wiki" # คนละ prefix กับแอปอื่น = state แยกเด็ดขาด
  }
}

provider "google" {
  project = var.project_id
  region  = "asia-southeast1"
}

module "app" {
  source = "github.com/viize-dev/tf-caddy-vm-app"

  project_id = var.project_id
  zone       = var.zone
  vm_name    = var.vm_name

  app_name     = var.app_name
  source_dir   = var.source_dir
  compose_file = var.compose_file
  source_paths = var.source_paths

  domain    = var.domain
  host_port = var.host_port

  # MCP streamable-http เป็น long-lived stream — ถ้าไม่ปิด timeout จะโดนตัดกลางคัน
  long_lived_stream = true

  # /mcp ตอบ 4xx เมื่อ request ไม่ครบตาม spec ซึ่งแปลว่ามันฟังอยู่แล้ว
  health_path = "/mcp"

  env_keys = var.env_keys

  cron_schedule = var.cron_schedule
  cron_command  = var.cron_command

  auth_token = var.auth_token
}
