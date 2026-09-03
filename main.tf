data "google_compute_instance" "vm" {
  name    = var.vm_name
  zone    = var.zone
  project = var.project_id
}

locals {
  gcloud_target = "--zone=${var.zone} --project=${var.project_id} --tunnel-through-iap --quiet"
  ssh           = "gcloud compute ssh ${var.vm_name} ${local.gcloud_target} --command"

  remote_dir = var.remote_dir != "" ? var.remote_dir : "/opt/${var.app_name}"
  vhost_path = "${var.caddy_conf_dir}/${var.app_name}.caddy"
  cron_path  = "/etc/cron.d/${var.app_name}"

  excludes = join(" ", [for e in var.source_excludes : "--exclude='${e}'"])
  paths    = join(" ", concat(var.source_paths, [var.compose_file]))

  # hash ของทุกไฟล์ที่ส่งขึ้นไป — เปลี่ยนเมื่อไหร่ redeploy เมื่อนั้น
  src_hash = sha256(join("", [
    for f in sort(concat([var.compose_file], flatten([
      for p in var.source_paths : fileexists("${var.source_dir}/${p}")
      ? [p]
      : [for sub in fileset("${var.source_dir}/${p}", "**") : "${p}/${sub}"]
    ]))) : filesha256("${var.source_dir}/${f}")
  ]))

  auth_block = var.auth_token == "" ? "" : <<-EOT
    @unauthorized not header Authorization "Bearer ${var.auth_token}"
    respond @unauthorized 401
  EOT

  # SSE / websocket ต้องปิด timeout ไม่งั้น proxy ตัดกลางคัน
  stream_block = var.long_lived_stream ? join("\n", [
    "        transport http {",
    "          read_timeout 0",
    "          write_timeout 0",
    "        }",
  ]) : ""

  caddy_vhost = <<-EOT
    # ${var.app_name} — จัดการโดย terraform (tf-caddy-vm-app)
    # อย่าแก้ไฟล์นี้บนเครื่อง มันจะถูกเขียนทับตอน apply ครั้งถัดไป
    ${var.domain} {
      encode gzip zstd
    ${local.auth_block}
      reverse_proxy 127.0.0.1:${var.host_port} {
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    ${local.stream_block}  }
    }
  EOT
}

# ── ส่ง source ขึ้น VM ────────────────────────────────────────────────────
# ใช้ tar ผ่าน stdin แทน gcloud scp รายไฟล์ เพราะ scp จัดการชื่อไฟล์ที่ไม่ใช่ ASCII
# ได้ไม่แน่นอน และช้ากว่ามากเมื่อไฟล์เยอะ
resource "null_resource" "source" {
  triggers = {
    src = local.src_hash
    vm  = data.google_compute_instance.vm.instance_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      cd ${var.source_dir}

      ${local.ssh} "sudo mkdir -p ${local.remote_dir} && sudo chown \$(whoami) ${local.remote_dir}"

      # COPYFILE_DISABLE=1 : กัน bsdtar บน macOS แนบ AppleDouble (._xxx) ที่ไม่ใช่ UTF-8
      COPYFILE_DISABLE=1 tar czf - ${local.excludes} ${local.paths} \
      | ${local.ssh} "tar xzf - -C ${local.remote_dir}"

      ${local.ssh} "cd ${local.remote_dir} && [ '${var.compose_file}' = 'docker-compose.yml' ] || mv -f ${var.compose_file} docker-compose.yml"
    EOT
  }
}

# ── .env: สร้างโครงเปล่าครั้งเดียว แล้วหยุดให้คนไปกรอก ─────────────────────
resource "null_resource" "env" {
  count = length(var.env_keys) == 0 ? 0 : 1

  triggers = { vm = data.google_compute_instance.vm.instance_id }

  depends_on = [null_resource.source]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.ssh} "
        set -e
        if [ ! -f ${local.remote_dir}/.env ]; then
          cat > ${local.remote_dir}/.env <<'ENVEOF'
${join("\n", [for k in var.env_keys : (can(regex("=", k)) ? k : "${k}=")])}
ENVEOF
          chmod 600 ${local.remote_dir}/.env
          echo 'สร้าง .env ใหม่ — ยังมีค่าว่าง ต้องกรอกเองก่อนแอปจะทำงาน'
        fi
      "

      # ถ้ายังมี key ที่ค่าว่าง = ยังไม่พร้อม หยุดตรงนี้ดีกว่าปล่อยให้ container ขึ้นแล้วพัง
      EMPTY="$(${local.ssh} "grep -E '^[A-Z_]+=$' ${local.remote_dir}/.env | cut -d= -f1 | tr '\n' ' '" 2>/dev/null | tail -1 | tr -d '\r')"
      if [ -n "$${EMPTY// /}" ]; then
        cat >&2 <<MSG

.env บน VM ยังมีค่าว่าง: $${EMPTY}
กรอกก่อนแล้ว apply ใหม่:
  gcloud compute ssh ${var.vm_name} ${local.gcloud_target} --command 'sudo nano ${local.remote_dir}/.env'

MSG
        exit 1
      fi
    EOT
  }
}

# ── build + up + รอให้แอปตอบจริง ──────────────────────────────────────────
resource "null_resource" "stack" {
  triggers = {
    src = local.src_hash
    vm  = data.google_compute_instance.vm.instance_id
  }

  depends_on = [null_resource.source, null_resource.env]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.ssh} "
        set -e
        cd ${local.remote_dir}
        sudo docker compose up -d --build

        ${var.health_path == "" ? "exit 0" : ""}
        # รอให้ตอบจริงก่อนถือว่าสำเร็จ ไม่งั้น terraform เขียวแต่ของยังไม่ขึ้น
        for i in \$(seq 1 20); do
          code=\$(curl -fsS -o /dev/null -w '%%{http_code}' http://127.0.0.1:${var.host_port}${var.health_path} 2>/dev/null || echo 000)
          if echo \"\$code\" | grep -qE '^(${var.health_ok_codes})$'; then
            echo \"แอปตอบแล้ว (HTTP \$code)\"; exit 0
          fi
          sleep 3
        done
        echo 'แอปไม่ตอบใน 60 วินาที:' >&2
        sudo docker compose logs --tail=30 >&2
        exit 1
      "
    EOT
  }
}

# ── Caddy vhost ───────────────────────────────────────────────────────────
# เขียนเป็นไฟล์ local แล้ว scp — ห้าม inline ผ่าน ssh --command เพราะ vhost มี `"`
# อยู่ข้างใน (Bearer "...") ซึ่งจะไปชนกับ `"` ที่ห่อ --command แล้ว gcloud แตก argument ผิด
resource "local_file" "vhost" {
  filename        = "${path.root}/.${var.app_name}.caddy"
  content         = local.caddy_vhost
  file_permission = "0600"
}

resource "null_resource" "caddy" {
  triggers = {
    vhost = sha256(local.caddy_vhost)
    vm    = data.google_compute_instance.vm.instance_id
  }

  depends_on = [null_resource.stack, local_file.vhost]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      gcloud compute scp ${local_file.vhost.filename} ${var.vm_name}:/tmp/${var.app_name}.caddy ${local.gcloud_target}

      # reload ไม่ restart — แอปอื่นบนเครื่องเดียวกันจะได้ไม่สะดุด
      ${local.ssh} 'sudo mkdir -p ${var.caddy_conf_dir} \
        && sudo mv /tmp/${var.app_name}.caddy ${local.vhost_path} \
        && sudo chmod 644 ${local.vhost_path} \
        && (sudo docker exec ${var.caddy_container} caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
            || sudo docker restart ${var.caddy_container})'
    EOT
  }
}

# ── cron (optional) ───────────────────────────────────────────────────────
resource "null_resource" "cron" {
  count = var.cron_schedule == "" ? 0 : 1

  triggers = {
    schedule = var.cron_schedule
    command  = var.cron_command
    vm       = data.google_compute_instance.vm.instance_id
  }

  depends_on = [null_resource.stack]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.ssh} "
        set -e
        sudo tee ${local.cron_path} >/dev/null <<'CRONEOF'
# ${var.app_name} — จัดการโดย terraform (tf-caddy-vm-app)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${var.cron_schedule} root cd ${local.remote_dir} && ${var.cron_command} >> /var/log/${var.app_name}-cron.log 2>&1
CRONEOF
        sudo chmod 644 ${local.cron_path}
      "
    EOT
  }
}
