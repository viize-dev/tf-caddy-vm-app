---
name: deploy-to-vm
description: Deploy แอป docker-compose ขึ้น VM ที่มี Caddy อยู่แล้ว (GCP + IAP) ด้วย terraform module tf-caddy-vm-app — ตั้งค่าครั้งแรก, deploy ซ้ำ, ตรวจสถานะ, แก้ปัญหา. ใช้เมื่อผู้ใช้พูดว่า "deploy แอปนี้ขึ้น server", "เอาขึ้น VM", "ตั้ง deploy ให้หน่อย", "deploy ซ้ำ", "แอปบน server ยังดีอยู่ไหม" หรือมี terraform/app.auto.tfvars อยู่แล้ว
---

# deploy-to-vm — เอาแอปขึ้น VM ที่มี Caddy

module: `git::ssh://git@github.com/viize-dev/tf-caddy-vm-app.git` (private — ต้องมีสิทธิ์อ่าน)

**หลักการ**: module นี้ **ไม่สร้าง VM/network/firewall/DNS** อ่านของเดิมด้วย data source
VM ถูกแชร์กับแอปอื่น — พังของเราได้ แต่ห้ามพังของคนอื่น

## เลือกโหมดก่อน

| สถานะ | ทำอะไร |
|---|---|
| ยังไม่มี `terraform/app.auto.tfvars` | **โหมดตั้งค่าใหม่** → ทำ Phase 1 |
| มีแล้ว + ผู้ใช้อยากส่งของขึ้น | `./scripts/deploy.sh --yes` |
| มีแล้ว + ผู้ใช้แค่อยากรู้ว่ายังดีไหม | `./scripts/deploy.sh --smoke-only` |
| อยากดูก่อนว่าจะเปลี่ยนอะไร | `./scripts/deploy.sh --dry-run` |

ถ้า repo ยังไม่มี `scripts/deploy.sh` ให้ copy จาก module (`scripts/deploy.sh` ใน repo tf-caddy-vm-app)

## Phase 1 — ตั้งค่าใหม่ (ถามทีละข้อ รอคำตอบก่อนถามข้อถัดไป)

อย่ารัน wizard ของ `deploy.sh` แทนผู้ใช้ — **ถามเองในแชท** แล้วเขียน `terraform/app.auto.tfvars`
เพราะบางข้อต้องดูโค้ดใน repo ประกอบ ซึ่ง wizard ทำไม่ได้

1. **ปลายทาง** — project, VM, zone
   ช่วยหาให้ก่อนถาม: `gcloud compute instances list --project=<p> --format='value(name,zone)'`
   ถ้าไม่รู้ project: `gcloud config get-value project`
2. **ตัวแอป** — slug, โฟลเดอร์ source, compose file, path ที่ต้องส่งขึ้น
   **ดู repo เองก่อน** แล้วเสนอ: มี Dockerfile ที่ไหน, compose service ชื่ออะไร, โฟลเดอร์ไหนที่ container ต้องใช้จริง
   ห้ามส่งของที่ไม่จำเป็น (ไฟล์ต้นฉบับขนาดใหญ่, `.git`, test fixtures)
3. **เครือข่าย** — domain, host port, แอปใช้ SSE/websocket ไหม, health path
   - port ต้องไม่ชนกับแอปอื่นบน VM: `sudo docker ps --format '{{.Names}} {{.Ports}}'`
   - **ต้องตอบข้อ SSE ให้ถูก** ถ้าใช่แล้วไม่ตั้ง `long_lived_stream = true` connection จะโดนตัดกลางคันแบบไม่มี error ให้เห็น
   - health path: เลือก path ที่ตอบเร็ว ถ้า endpoint ตอบ 4xx เมื่อ request ไม่ครบ ก็ใช้ได้ (ตั้ง `health_ok_codes = "2..|4.."`)
4. **env** — ชื่อ env ที่แอปต้องใช้ (อ่านจากโค้ด/compose แล้วเสนอ)
   ใส่ค่า default ที่ไม่ลับได้เลย (`PORT=8080`) ส่วนค่าลับใส่แค่ชื่อ
   **ห้ามเขียนค่าลับลง tfvars** — apply จะสร้าง `.env` โครงเปล่าบน VM แล้วหยุดให้คนไปกรอก
5. **cron** — มีงานตามเวลาไหม, คำสั่งอะไร, ตารางไหน (UTC — เลี่ยงนาที 0/30)
6. **auth** — บังคับ Bearer token ไหม (แนะนำ "ใช่" ถ้า endpoint ไม่ควรเปิดสาธารณะ)

สรุปเป็นตารางให้ยืนยันครั้งเดียว แล้วเขียน `terraform/app.auto.tfvars` +
`terraform/main.tf` (module block) + `versions.tf` (backend) ตาม `examples/` ใน repo module

## Phase 2 — รัน

```bash
./scripts/deploy.sh --dry-run    # ให้ผู้ใช้ดู plan ก่อนเสมอ
./scripts/deploy.sh              # apply (ถามยืนยันเอง)
```

**apply รอบแรกจะหยุด** ถ้ามี `env_keys` — ตั้งใจให้หยุด บอกผู้ใช้ไปกรอก `.env` บน VM
(บอก `gcloud compute ssh ... --command 'sudo nano <remote_dir>/.env'` ให้ครบ) แล้วรันซ้ำ

## Rules

- ❌ **ห้าม `terraform apply` ตรง ๆ** — ใช้ `deploy.sh` เสมอ ไม่งั้น auth token ที่อยู่ใน vhost
  บน VM จะถูกเขียนทับหาย แล้ว client เดิม 401 (`deploy.sh` อ่าน token เดิมกลับมาให้)
- ❌ ห้ามเขียนค่าลับลง tfvars / terraform state / git — `.env` บน VM ที่เดียว
- ❌ ห้ามแก้ไฟล์ใน `<remote_dir>` บน VM ด้วยมือ — deploy รอบหน้าเขียนทับ
- ✅ **หลัง deploy ทุกครั้ง เช็คว่าแอปอื่นบน VM ยังไม่ล่ม** — Caddy ตัวเดียวให้บริการทุกแอป
  `curl -o /dev/null -w '%{http_code}' https://<โดเมนของแอปอื่น>/`
- ✅ ถ้า plan จะไปแตะ `google_compute_instance/disk/network/firewall` = ผิดแน่นอน หยุดทันที
- ✅ รายงานผลด้วยตัวเลขจริงจาก smoke test ไม่ใช่ "น่าจะขึ้นแล้ว"

## แก้ปัญหา

| อาการ | สาเหตุ | ทำอะไร |
|---|---|---|
| `invalid_grant` / `invalid_rapt` | ADC หมดอายุ (คนละตัวกับ `gcloud auth login`) | `gcloud auth application-default login` |
| `Backend configuration changed` | เคย init แบบอื่นไว้ | `terraform init -reconfigure` |
| apply หยุดที่ `.env` ยังว่าง | ตั้งใจให้หยุด | บอกผู้ใช้ไปกรอกแล้วรันซ้ำ |
| smoke test ได้ 52x | TLS ระหว่าง proxy กับ origin | cert ยังออกไม่เสร็จ (รอ ~30 วิ) หรืออยู่หลัง Cloudflare Full(strict) แล้ว origin ยังไม่มี cert |
| client เดิม 401 หลัง deploy | มีคน `terraform apply` ตรง ๆ | รัน `deploy.sh` ใหม่ (อ่าน token จาก VM) หรือส่ง `--token <ค่าเดิม>` |
| **แอปอื่นบน VM ล่มพร้อมกัน** | Caddy crash-loop จาก vhost ที่ syntax ผิด | ถอด vhost ออกแล้ว restart caddy — ดู "กู้ฉุกเฉิน" ข้างล่าง |
| container ขึ้นแต่ endpoint ไม่ตอบ | compose ไม่ได้ bind `127.0.0.1:<port>` หรือพอร์ตไม่ตรง tfvars | แก้ compose ให้ตรงกับ `host_port` |

### กู้ฉุกเฉิน (Caddy ล้มทั้งเครื่อง)
```bash
gcloud compute ssh <VM> --zone=<zone> --project=<project> --tunnel-through-iap \
  --command 'sudo mv /mnt/data/caddy/conf.d/<app>.caddy /tmp/ && sudo docker restart caddy'
```
แล้วแจ้งผู้ใช้ว่าแอปอื่นกลับมาแล้ว ก่อนค่อยไปหาสาเหตุของ vhost

## อ่านต่อ
`README.md` ของ repo module — ตารางกับดัก 10 อย่างพร้อมสาเหตุจริง และตัวอย่างเต็มใน `examples/`
