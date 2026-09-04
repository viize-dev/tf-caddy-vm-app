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
  #
  # source_paths มีทั้งไฟล์เดี่ยวและโฟลเดอร์ จึงรวมผลจาก fileset สองแบบ:
  #   fileset(dir, p)        -> ตรงกับกรณีที่ p เป็นไฟล์
  #   fileset(dir, "p/**")   -> ตรงกับกรณีที่ p เป็นโฟลเดอร์
  # (ห้ามใช้ fileexists แยกเคส — มัน error ใส่ directory แทนที่จะคืน false)
  src_files = sort(distinct(flatten([
    for p in concat(var.source_paths, [var.compose_file]) : concat(
      tolist(fileset(var.source_dir, p)),
      tolist(fileset(var.source_dir, "${p}/**")),
    )
  ])))

  src_hash = sha256(join("", [for f in local.src_files : filesha256("${var.source_dir}/${f}")]))

  # สร้าง vhost เป็น "รายการบรรทัด" แล้วค่อย join
  #
  # ⚠️ ห้ามใช้ heredoc ที่ interpolate ตัวแปรหลายบรรทัดเข้าไปกลางบล็อก:
  #    บล็อกว่างจะทำให้ `}` ไปต่อท้ายบรรทัดอื่นกลายเป็น `}  }` ซึ่ง Caddy
  #    ปฏิเสธทั้งไฟล์ ("unrecognized subdirective }") แล้ว **Caddy ทั้งเครื่อง
  #    crash-loop** = แอปอื่นบน VM ล่มตามไปด้วย (เจอจริงมาแล้ว)
  vhost_lines = concat(
    [
      "# ${var.app_name} — จัดการโดย terraform (tf-caddy-vm-app)",
      "# อย่าแก้ไฟล์นี้บนเครื่อง มันจะถูกเขียนทับตอน apply ครั้งถัดไป",
      "${var.domain} {",
      "  encode gzip zstd",
    ],
    var.auth_token == "" ? [] : [
      "  @unauthorized not header Authorization \"Bearer ${var.auth_token}\"",
      "  respond @unauthorized 401",
    ],
    [
      "  reverse_proxy 127.0.0.1:${var.host_port} {",
      "    header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}",
    ],
    var.long_lived_stream ? [
      "    transport http {",
      "      read_timeout 0",
      "      write_timeout 0",
      "    }",
    ] : [],
    [
      "  }",
      "}",
      "",
    ],
  )

  caddy_vhost = join("\n", local.vhost_lines)
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

      # chown -R : ไม่ใช่แค่โฟลเดอร์บนสุด
      #   ถ้าไม่ใส่ -R ไฟล์/โฟลเดอร์ย่อยจะยังเป็นของ "คนที่ deploy คนแรก"
      #   dev คนที่สองจะ extract ทับไม่ได้ (tar: Cannot open: Permission denied)
      #
      # :0 (group root) + chmod -R g+w : ให้คอนเทนเนอร์เขียนกลับได้
      #   image รันด้วย uid ที่ไม่ใช่ root แต่ gid 0 (pattern มาตรฐานของ OpenShift/rootless)
      #   ถ้าปล่อยให้ group เป็นของ dev คนที่ deploy งานที่เขียนไฟล์ (เช่น cron
      #   ที่อัปเดตข้อมูลใน volume) จะล้มแบบเงียบ ๆ หลังเปลี่ยนคน deploy
      ${local.ssh} "sudo mkdir -p ${local.remote_dir} \
        && sudo chown -R \$(whoami):0 ${local.remote_dir} \
        && sudo chmod -R g+w ${local.remote_dir}"

      # COPYFILE_DISABLE=1 : กัน bsdtar บน macOS แนบ AppleDouble (._xxx) ที่ไม่ใช่ UTF-8
      COPYFILE_DISABLE=1 tar czf - ${local.excludes} ${local.paths} \
      | ${local.ssh} "tar xzf - -C ${local.remote_dir}"

      ${local.ssh} "cd ${local.remote_dir} && [ '${var.compose_file}' = 'docker-compose.yml' ] || mv -f ${var.compose_file} docker-compose.yml"

      # ไฟล์ที่เพิ่ง extract มาพร้อม mode จากเครื่อง dev — ตั้งสิทธิ์ใหม่ให้ครบ
      # (.env ไม่แตะ: ต้องเป็น 600 และเป็นของคนที่กรอกไว้)
      ${local.ssh} "sudo chown -R \$(whoami):0 ${local.remote_dir} \
        && sudo chmod -R g+w ${local.remote_dir} \
        && sudo chmod 600 ${local.remote_dir}/.env 2>/dev/null || true"
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
          # ห้ามใส่ -f : มันทำให้ 4xx กลายเป็น exit error แล้ว code เป็น 000
          # ทั้งที่บาง endpoint ตอบ 4xx เมื่อ request ไม่ครบ = แอปฟังอยู่แล้ว
          code=\$(curl -sS -o /dev/null -w '%%{http_code}' http://127.0.0.1:${var.host_port}${var.health_path} 2>/dev/null || echo 000)
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

      # ⚠️ ต้อง validate ก่อน reload เสมอ — Caddy ตัวนี้ให้บริการแอปอื่นบนเครื่องด้วย
      #    vhost ที่ syntax ผิดทำให้ Caddy crash-loop = ทุกแอปบน VM ล่ม
      #    ถ้า validate ไม่ผ่าน ให้ถอดไฟล์ออกแล้วล้มทั้ง apply (ของเดิมยังทำงานต่อ)
      ${local.ssh} 'set -e
        sudo mkdir -p ${var.caddy_conf_dir}
        sudo cp -f ${local.vhost_path} /tmp/vhost.prev 2>/dev/null || true
        sudo mv /tmp/${var.app_name}.caddy ${local.vhost_path}
        sudo chmod 644 ${local.vhost_path}

        if ! sudo docker exec ${var.caddy_container} caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/tmp/caddy-validate.log 2>&1; then
          echo "Caddyfile ไม่ผ่าน validate — ถอด vhost ออกเพื่อไม่ให้ Caddy ล้มทั้งเครื่อง:" >&2
          tail -5 /tmp/caddy-validate.log >&2
          if [ -f /tmp/vhost.prev ]; then sudo mv /tmp/vhost.prev ${local.vhost_path}; else sudo rm -f ${local.vhost_path}; fi
          sudo docker exec ${var.caddy_container} caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
          exit 1
        fi

        # reload ไม่ restart — แอปอื่นบนเครื่องเดียวกันจะได้ไม่สะดุด
        sudo docker exec ${var.caddy_container} caddy reload --config /etc/caddy/Caddyfile
        sudo rm -f /tmp/vhost.prev'
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
