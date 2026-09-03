#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — deploy แอปขึ้น VM ที่มี Caddy อยู่แล้ว ในคำสั่งเดียว
#
# ครั้งแรกจะ **ถามคำถาม** แล้วเขียนคำตอบลง app.auto.tfvars ครั้งต่อไปอ่านจากไฟล์นั้น
#
# ทำอะไรบ้าง (ตามลำดับ):
#   1. ตรวจ prerequisite — gcloud auth (2 ชั้น), terraform, SSH เข้า VM
#   2. wizard (ถ้ายังไม่มี config) แล้วตรวจ config — DNS, พอร์ตชน, .env, auth token
#   3. terraform init + plan แล้วสรุปให้ดูก่อนถาม
#   4. terraform apply — ส่ง source, build, up, Caddy vhost, cron
#   5. smoke test ผ่านโดเมนจริง
#   6. สรุป + คำสั่งที่ใช้ต่อ
#
# วิธีใช้:
#   ./scripts/deploy.sh [ตัวเลือก]
#
#     --dry-run       plan อย่างเดียว ไม่ apply
#     --yes, -y       ข้ามคำถามยืนยัน (ต้องมี config อยู่แล้ว)
#     --reconfigure   รัน wizard ใหม่ ทับ config เดิม
#     --smoke-only    ไม่ deploy — ทดสอบของที่รันอยู่
#     --skip-checks   ข้ามการตรวจ DNS/พอร์ต
#     --token <tok>   Bearer token (ไม่ใส่ = อ่านจาก vhost บน VM หรือสุ่มครั้งแรก)
#
# 🔐 ไม่มี secret ถูก hardcode: ค่า .env กรอกบน VM ครั้งเดียว
#    ส่วน token อ่านกลับจาก vhost บน VM ทุกครั้ง จึงไม่ต้องจำ
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${TF_DIR:-$PWD}/app.auto.tfvars"
TF_DIR="${TF_DIR:-$PWD}"

if [[ -t 1 ]]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;34m'; BOLD=$'\033[1m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; BOLD=''; N=''
fi
say()  { echo "${B}▶${N} $*"; }
ok()   { echo "${G}✅${N} $*"; }
warn() { echo "${Y}⚠️ ${N} $*"; }
die()  { echo "${R}❌ $*${N}" >&2; exit 1; }

DRY_RUN=0; ASSUME_YES=0; SMOKE_ONLY=0; SKIP_CHECKS=0; RECONFIGURE=0; TOKEN="${TF_VAR_auth_token:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --smoke-only)  SMOKE_ONLY=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --token)       TOKEN="${2:-}"; [[ -n "$TOKEN" ]] || die "--token ต้องตามด้วยค่า"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *)             die "ไม่รู้จัก argument: $1 (ดู --help)" ;;
  esac
done

# ── helper สำหรับ wizard ─────────────────────────────────────────────────────
# อ่านจาก /dev/tty ถ้ามี (เพื่อให้ถามได้แม้ stdout ถูก pipe) ไม่งั้นอ่าน stdin
# — ห้าม hardcode </dev/tty: ใน CI หรือ container จะได้ "Device not configured"
#   และทำให้ป้อนคำตอบผ่าน pipe (เช่นตอนเทสต์) ไม่ได้เลย
# [[ -r /dev/tty ]] เชื่อไม่ได้ — บนบางระบบมันผ่านแต่ open จริงล้ม
# ("Device not configured") จึงต้องลองเปิด fd ดูเลย ถ้าไม่ได้ค่อย fallback ไป stdin
if exec 3</dev/tty 2>/dev/null; then :; else exec 3<&0; fi

_ask_raw() { local __v="$1" __p="$2"; read -r -p "$__p" "$__v" <&3; }

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    _ask_raw ans "  ${prompt} [${BOLD}${default}${N}]: " || true
    echo "${ans:-$default}"
  else
    while :; do
      if ! _ask_raw ans "  ${prompt}: "; then
        # EOF = ไม่มีใครตอบแล้ว วนต่อก็ไม่มีวันได้คำตอบ
        echo "" >&2; die "ไม่ได้รับคำตอบสำหรับ: ${prompt}"
      fi
      [[ -n "$ans" ]] && { echo "$ans"; return; }
      echo "     ${Y}ต้องตอบข้อนี้${N}" >&2
    done
  fi
}
ask_yn() {
  local prompt="$1" default="${2:-n}" ans
  _ask_raw ans "  ${prompt} [${default}]: " || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}
tfget() { grep -E "^\s*$1\s*=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^ *//; s/ *$//; s/^"//; s/"$//'; }

# ═══ wizard ══════════════════════════════════════════════════════════════════
run_wizard() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "${BOLD} ตั้งค่า deploy ครั้งแรก${N}  (คำตอบจะถูกเขียนลง $(basename "$CFG"))"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local def_proj; def_proj="$(gcloud config get-value project 2>/dev/null || true)"
  echo ""
  echo "${BOLD}1) ปลายทาง${N}"
  W_PROJECT="$(ask "GCP project id" "$def_proj")"

  echo "     กำลังหา VM ใน project นี้…"
  local vms; vms="$(gcloud compute instances list --project="$W_PROJECT" --format='value(name,zone)' 2>/dev/null || true)"
  if [[ -n "$vms" ]]; then
    echo "$vms" | nl -w4 -s'. ' | sed 's/^/    /'
    local pick; pick="$(ask "เลือกหมายเลข VM (หรือพิมพ์ชื่อเอง)" "1")"
    if [[ "$pick" =~ ^[0-9]+$ ]]; then
      W_VM="$(echo "$vms" | sed -n "${pick}p" | awk '{print $1}')"
      W_ZONE="$(echo "$vms" | sed -n "${pick}p" | awk '{print $2}')"
    else
      W_VM="$pick"; W_ZONE="$(ask "zone ของ VM" "asia-southeast1-b")"
    fi
  else
    W_VM="$(ask "ชื่อ VM ที่มีอยู่แล้ว")"
    W_ZONE="$(ask "zone" "asia-southeast1-b")"
  fi
  echo "     → ${W_VM} (${W_ZONE})"

  echo ""
  echo "${BOLD}2) ตัวแอป${N}"
  W_APP="$(ask "ชื่อแอป (slug a-z0-9-)" "$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')")"
  W_SRC="$(ask "โฟลเดอร์ source ที่จะส่งขึ้น VM" "..")"
  W_COMPOSE="$(ask "ชื่อ compose file ใน source" "docker-compose.prod.yml")"
  echo "     path ไหนบ้างที่ต้องส่งขึ้นไป (คั่นด้วยช่องว่าง — ใส่เฉพาะที่จำเป็น)"
  W_PATHS="$(ask "  paths" "app")"

  echo ""
  echo "${BOLD}3) เครือข่าย${N}"
  W_DOMAIN="$(ask "โดเมน (ต้องชี้มาที่ VM แล้ว)")"
  W_PORT="$(ask "พอร์ตบนโฮสต์ที่ container publish" "8080")"
  if ask_yn "แอปใช้ SSE/websocket/streaming ไหม (ต้องปิด proxy timeout)" "n"; then
    W_STREAM=true
  else
    W_STREAM=false
  fi
  W_HEALTH="$(ask "path สำหรับเช็คว่าแอปขึ้นแล้ว (เว้นว่างเพื่อข้าม)" "/")"

  echo ""
  echo "${BOLD}4) env${N}"
  echo "     ใส่ชื่อ env ที่แอปต้องใช้ คั่นด้วยช่องว่าง (ใส่ค่า default ได้ด้วย KEY=value)"
  echo "     ค่าจริงจะไปกรอกบน VM — ไม่ผ่าน terraform state"
  W_ENV="$(ask "  env keys (เว้นว่างถ้าไม่มี)" "")"

  echo ""
  echo "${BOLD}5) cron${N}"
  if ask_yn "มีงานที่ต้องรันตามเวลาบน VM ไหม" "n"; then
    W_CRON_CMD="$(ask "คำสั่ง (รันใน remote dir)" "docker compose exec -T app python job.py")"
    echo "     เวลาเป็น UTC — เลี่ยงนาที 0/30 ถ้าไม่ได้ผูกกับเวลาเป๊ะ"
    W_CRON="$(ask "ตาราง cron" "23 22 * * *")"
  else
    W_CRON=""; W_CRON_CMD=""
  fi

  echo ""
  echo "${BOLD}6) auth${N}"
  if ask_yn "บังคับ Bearer token ที่ Caddy ไหม (แนะนำถ้า endpoint ไม่ควรเปิดสาธารณะ)" "y"; then
    TOKEN="${TOKEN:-$(openssl rand -hex 32)}"
    echo ""
    echo "     ${BOLD}${TOKEN}${N}"
    echo "     ↑ เก็บไว้ให้ client ใช้ (ครั้งต่อไปสคริปต์อ่านจาก VM ให้เอง)"
    echo ""
  fi

  {
    echo "# สร้างโดย deploy.sh $(date +%F) — แก้ได้ตามต้องการ"
    echo "project_id = \"${W_PROJECT}\""
    echo "zone       = \"${W_ZONE}\""
    echo "vm_name    = \"${W_VM}\""
    echo ""
    echo "app_name     = \"${W_APP}\""
    echo "source_dir   = \"${W_SRC}\""
    echo "compose_file = \"${W_COMPOSE}\""
    printf 'source_paths = ['; printf '"%s", ' $W_PATHS; echo ']'
    echo ""
    echo "domain            = \"${W_DOMAIN}\""
    echo "host_port         = ${W_PORT}"
    echo "long_lived_stream = ${W_STREAM}"
    echo "health_path       = \"${W_HEALTH}\""
    echo ""
    printf 'env_keys = ['; printf '"%s", ' $W_ENV; echo ']'
    echo ""
    echo "cron_schedule = \"${W_CRON}\""
    echo "cron_command  = \"${W_CRON_CMD}\""
  } > "$CFG"

  ok "เขียน config ลง $(basename "$CFG") แล้ว — แก้ไฟล์นี้ทีหลังได้"
}

[[ ! -f "$CFG" || $RECONFIGURE -eq 1 ]] && [[ $SMOKE_ONLY -eq 0 ]] && run_wizard
[[ -f "$CFG" ]] || die "ไม่มี $(basename "$CFG") — รันโดยไม่ใส่ --smoke-only เพื่อตั้งค่าก่อน"

PROJECT="$(tfget project_id)"; ZONE="$(tfget zone)"; VM="$(tfget vm_name)"
APP="$(tfget app_name)"; DOMAIN="$(tfget domain)"; PORT="$(tfget host_port)"
HEALTH="$(tfget health_path)"; CRON="$(tfget cron_schedule)"
REMOTE="$(tfget remote_dir)"; REMOTE="${REMOTE:-/opt/$APP}"
VHOST="$(tfget caddy_conf_dir)"; VHOST="${VHOST:-/mnt/data/caddy/conf.d}/${APP}.caddy"
URL="https://${DOMAIN}"

ssh_vm() {
  gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --tunnel-through-iap --quiet \
    --command="$1" 2>&1 | grep -vE "NumPy|iap/docs/using-tcp-forwarding|^WARNING: *$|^$" || true
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "${BOLD} ${APP} — Deploy${N}"
printf "  %-12s %s\n" "project" "$PROJECT"
printf "  %-12s %s\n" "VM" "${VM} (${ZONE})"
printf "  %-12s %s\n" "โดเมน" "$URL"
printf "  %-12s %s\n" "พอร์ต" "127.0.0.1:${PORT}"
[[ $DRY_RUN    -eq 1 ]] && echo "  ${Y}โหมด         DRY-RUN${N}"
[[ $SMOKE_ONLY -eq 1 ]] && echo "  ${Y}โหมด         SMOKE-ONLY${N}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══ 1: prerequisite ═════════════════════════════════════════════════════════
echo ""; say "[1/6] ตรวจ prerequisite"
command -v gcloud >/dev/null    || die "ไม่พบ gcloud"
command -v terraform >/dev/null || die "ไม่พบ terraform"
ok "เครื่องมือครบ"

gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud ยังไม่ได้ login — รัน: gcloud auth login"
# ADC เป็นคนละ credential กับข้างบน terraform ใช้ตัวนี้ และหมดอายุแยกกัน
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "ADC หมดอายุ/ยังไม่มี (terraform ใช้ตัวนี้) — รัน: gcloud auth application-default login"
ok "gcloud auth + ADC ใช้ได้"

if [[ $SMOKE_ONLY -eq 0 ]]; then
  [[ "$(ssh_vm 'echo PONG' | tail -1)" == "PONG" ]] \
    || die "SSH เข้า ${VM} ไม่ได้ — ต้องมี roles/iap.tunnelResourceAccessor + roles/compute.osLogin"
  ok "SSH (IAP) เข้า ${VM} ได้"
fi

# ═══ 2: ตรวจ config ══════════════════════════════════════════════════════════
echo ""; say "[2/6] ตรวจ config"
VM_IP="$(gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
          --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
[[ -n "$VM_IP" ]] || die "หา IP ของ ${VM} ไม่เจอ"
echo "     IP ของ VM : ${VM_IP}"

if [[ $SKIP_CHECKS -eq 0 ]]; then
  DNS_IP="$(dig +short "$DOMAIN" A 2>/dev/null | tail -1 || true)"
  echo "     DNS       : ${DOMAIN} → ${DNS_IP:-<ไม่มี A record>}"
  [[ -n "$DNS_IP" ]] || die "ยังไม่มี A record ของ ${DOMAIN} — ชี้มาที่ ${VM_IP} ก่อน"
  [[ "$DNS_IP" == "$VM_IP" ]] && ok "DNS ชี้ตรงมาที่ VM" \
    || warn "DNS ไม่ตรง IP ของ VM — ถ้าอยู่หลัง proxy (Cloudflare) ถือว่าปกติ"

  if [[ $SMOKE_ONLY -eq 0 ]]; then
    # พอร์ตชนกับแอปอื่นบนเครื่องเดียวกันคือ error ที่หาสาเหตุยาก ดักไว้ก่อน
    CLASH="$(ssh_vm "sudo docker ps --format '{{.Names}} {{.Ports}}' | grep ':${PORT}->' | grep -v '${APP}' | head -1")"
    [[ -z "${CLASH// /}" ]] && ok "พอร์ต ${PORT} ว่าง" \
      || die "พอร์ต ${PORT} ถูกใช้อยู่แล้วโดย: ${CLASH} — เปลี่ยน host_port ใน $(basename "$CFG")"
  fi
fi

if [[ $SMOKE_ONLY -eq 0 && -z "$TOKEN" ]]; then
  # ⚠️ gcloud พ่นคำเตือนปน stdout — ต้องเช็คว่ามี vhost ก่อน แล้ว validate รูปแบบให้ตรงเป๊ะ
  #    ไม่งั้นตัวอักษร a-f จากประโยคภาษาอังกฤษจะกลายเป็น "token" ที่ดูเหมือนจริง
  if ssh_vm "sudo test -f ${VHOST} && echo HAS || echo NO" | grep -q HAS; then
    TOKEN="$(ssh_vm "sudo grep -oE 'Bearer [a-f0-9]{32,}' ${VHOST} 2>/dev/null | head -1 | cut -d' ' -f2" \
             | grep -oE '^[a-f0-9]{32,}$' | head -1 || true)"
    [[ -n "$TOKEN" ]] && ok "อ่าน auth token เดิมจาก VM ได้" \
      || warn "vhost บน VM ไม่มี token — endpoint เปิดสาธารณะอยู่"
  fi
fi

# ═══ 3-4: plan + apply ═══════════════════════════════════════════════════════
if [[ $SMOKE_ONLY -eq 0 ]]; then
  echo ""; say "[3/6] terraform init + plan"
  set +e
  terraform -chdir="$TF_DIR" init -input=false >/tmp/${APP}.init.txt 2>&1
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    if grep -qE 'invalid_grant|invalid_rapt' /tmp/${APP}.init.txt; then
      die "credential หมดอายุ — รัน: gcloud auth application-default login"
    elif grep -qiE 'backend configuration changed|reconfigure' /tmp/${APP}.init.txt; then
      terraform -chdir="$TF_DIR" init -reconfigure -input=false >/dev/null || die "init -reconfigure ล้ม"
    else
      tail -20 /tmp/${APP}.init.txt >&2; die "terraform init ล้ม"
    fi
  fi
  ok "init เรียบร้อย"

  export TF_VAR_auth_token="$TOKEN"
  set +e
  terraform -chdir="$TF_DIR" plan -no-color -input=false -out=/tmp/${APP}.tfplan >/tmp/${APP}.plan.txt 2>&1
  RC=$?
  set -e
  [[ $RC -eq 0 ]] || { tail -25 /tmp/${APP}.plan.txt >&2; die "plan ล้ม (ดู /tmp/${APP}.plan.txt)"; }
  grep -E '^(Plan:|No changes)' /tmp/${APP}.plan.txt | sed 's/^/     /' || true

  # กันพลาด: module นี้ต้องไม่สร้าง/แก้ VM หรือ network ของใคร
  if grep -qE '^  # (google_compute_instance|google_compute_disk|google_compute_network|google_compute_firewall)' /tmp/${APP}.plan.txt; then
    die "plan จะแตะ VM/network — หยุดก่อน module นี้ต้องไม่สร้างของพวกนั้น (ดู /tmp/${APP}.plan.txt)"
  fi
  ok "plan พร้อม"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""; echo "${Y}DRY-RUN — หยุดตรงนี้ (plan เต็ม: /tmp/${APP}.plan.txt)${N}"; exit 0
  fi

  if [[ $ASSUME_YES -eq 0 ]]; then
    echo ""
    read -r -p "${BOLD}deploy ตามนี้เลยไหม? [y/N] ${N}" ans <&3 || true
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "ยกเลิก"; exit 0; }
  fi

  echo ""; say "[4/6] terraform apply"
  terraform -chdir="$TF_DIR" apply -input=false /tmp/${APP}.tfplan \
    || die "apply ล้ม — ดู log: terraform output -raw logs_command | bash"
  ok "apply สำเร็จ"
else
  echo ""; say "[3-4/6] ข้าม (smoke-only)"
fi

# ═══ 5: smoke test ═══════════════════════════════════════════════════════════
echo ""; say "[5/6] smoke test ผ่าน ${URL}"
# ทุกอย่างในขั้นนี้คือ "การตรวจ" ล้มได้เป็นปกติ — set -e จะฆ่าสคริปต์ก่อนพิมพ์ว่าอะไรพัง
set +e

AUTH=()
[[ -n "$TOKEN" ]] && AUTH=(-H "Authorization: Bearer ${TOKEN}")

CODE=""
for i in $(seq 1 10); do
  # ${ARR[@]+"${ARR[@]}"} = ขยายเฉพาะตอนมีสมาชิก (bash 3.2 + set -u)
  # ห้ามใช้ $(printf) แทน — command substitution จะ word-split header ออกเป็นหลาย argument
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${URL}${HEALTH}" ${AUTH[@]+"${AUTH[@]}"} 2>/dev/null)"
  [[ "$CODE" =~ ^[234] ]] && break
  sleep 3
done

case "$CODE" in
  2*|3*) ok "โดเมนตอบ HTTP ${CODE}" ;;
  4*)    ok "โดเมนตอบ HTTP ${CODE} (แอปฟังอยู่ — request ไม่ครบตาม spec ของมันเท่านั้น)" ;;
  52*)   warn "HTTP ${CODE} — TLS ระหว่าง proxy กับ origin ยังไม่ผ่าน (cert ยังออกไม่เสร็จ?)" ;;
  000|"") warn "ต่อไม่ติดเลย — เช็ค DNS, firewall และ TLS" ;;
  *)     warn "HTTP ${CODE}" ;;
esac

CSTAT="$(ssh_vm "sudo docker ps --filter name=${APP} --format '{{.Status}}' | head -1")"
[[ -n "${CSTAT// /}" ]] && ok "container: ${CSTAT}" || warn "ไม่พบ container ชื่อ ${APP}"

if [[ -n "$CRON" ]]; then
  ssh_vm "sudo test -f /etc/cron.d/${APP} && echo OK" | grep -q OK \
    && ok "cron ติดตั้งแล้ว (${CRON} UTC)" || warn "ไม่พบ /etc/cron.d/${APP}"
fi
set -e

# ═══ 6: สรุป ═════════════════════════════════════════════════════════════════
echo ""; say "[6/6] สรุป"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-12s %s\n" "endpoint" "$URL"
printf "  %-12s %s\n" "container" "${CSTAT:-—}"
printf "  %-12s %s\n" "remote dir" "$REMOTE"
[[ -n "$CRON" ]] && printf "  %-12s %s\n" "cron" "${CRON} UTC"
[[ -n "$TOKEN" ]] && printf "  %-12s %s\n" "auth" "Bearer ${TOKEN:0:8}…${TOKEN: -4}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "${BOLD}คำสั่งที่ใช้บ่อย${N}"
echo "  ดู log      : terraform output -raw logs_command | bash"
echo "  เข้าเครื่อง  : terraform output -raw ssh_command | bash"
[[ -n "$CRON" ]] && echo "  log ของ cron : terraform output -raw cron_log_command | bash"
echo ""
ok "เสร็จเรียบร้อย"
