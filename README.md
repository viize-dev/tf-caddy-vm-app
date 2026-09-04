# tf-caddy-vm-app

เอาแอป docker-compose ไปเกาะ **VM ที่มี Caddy อยู่แล้ว** — ในคำสั่งเดียว พร้อม TLS, auth, cron

```bash
./scripts/deploy.sh          # ครั้งแรกจะถามคำถามแล้วจำไว้ใน app.auto.tfvars
```

## ติดตั้ง skill (สำหรับคนใช้ Claude Code)

repo นี้เป็น plugin marketplace ในตัว — ติดตั้งครั้งเดียวแล้วใช้ได้ทุก project:

```
/plugin marketplace add viize-dev/tf-caddy-vm-app
/plugin install deploy-to-vm@viize-infra
```

จากนั้นสั่งเป็นภาษาคนได้เลย: *"deploy แอปนี้ขึ้น VM หน่อย"* · *"แอปบน server ยังดีอยู่ไหม"*
skill จะถามข้อมูลที่ต้องใช้ทีละข้อ (โดยดูโค้ดใน repo ประกอบ) เขียน `app.auto.tfvars`
แล้วรัน `deploy.sh` ให้ — พร้อมกฎที่กัน**พังของแอปอื่นบน VM เดียวกัน**

ไม่ใช้ Claude Code ก็ข้ามส่วนนี้ไป รัน `./scripts/deploy.sh` ตรง ๆ ได้เหมือนกัน

**ไม่สร้าง VM / network / firewall / DNS** — อ่านของเดิมด้วย data source
เพราะของพวกนั้นเป็นของ terraform ชุดที่สร้าง VM ถ้าประกาศซ้ำจะแย่งกันคุม

## ใช้เมื่อไหร่

- มี VM ที่รัน Caddy อยู่แล้ว และอยากเอาแอปตัวที่ 2, 3, 4 ไปเกาะโดยไม่กระทบตัวเดิม
- แอปเป็น docker-compose ที่ publish พอร์ตบน `127.0.0.1`
- deploy จากเครื่อง dev (ไม่ต้องมี CI / registry)

**ไม่เหมาะกับ**: แอปที่ต้อง scale หลายเครื่อง, ต้องมี CI pipeline, หรือใช้ managed platform อยู่แล้ว

## VM ปลายทางต้องมี

1. Docker + `docker compose`
2. คอนเทนเนอร์ Caddy ที่ Caddyfile หลักมีบรรทัด `import /data/conf.d/*.caddy`
   (path ในคอนเทนเนอร์ — ฝั่งโฮสต์คือ `caddy_conf_dir`, default `/mnt/data/caddy/conf.d`)
3. เข้าถึงได้ผ่าน `gcloud compute ssh --tunnel-through-iap`

## deploy.sh ทำอะไร

| ขั้น | ทำอะไร |
|---|---|
| 0 | **wizard** — ถาม 6 กลุ่ม (ปลายทาง, ตัวแอป, เครือข่าย, env, cron, auth) แล้วเขียน `app.auto.tfvars` |
| 1 | gcloud auth **2 ชั้น** (user + ADC — terraform ใช้ ADC และหมดอายุแยกกัน), terraform, SSH เข้า VM |
| 2 | DNS ชี้มาถูกเครื่องไหม · **พอร์ตชนกับแอปอื่นบนเครื่องเดียวกันไหม** · อ่าน auth token เดิมจาก VM |
| 3 | `init` + `plan` — และ**หยุดทันทีถ้า plan จะไปแตะ VM/network** |
| 4 | `apply` — ส่ง source, build, up, รอให้แอปตอบจริง, วาง Caddy vhost (reload ไม่ restart), ตั้ง cron |
| 5 | smoke test ผ่านโดเมนจริง + เช็ค container + cron |
| 6 | สรุป + คำสั่งที่ใช้ต่อ |

ตัวเลือก: `--dry-run` `--yes` `--reconfigure` `--smoke-only` `--skip-checks` `--token <tok>`

## เรื่อง secret

| ค่า | อยู่ที่ไหน |
|---|---|
| env จริงของแอป (รหัส DB ฯลฯ) | `<remote_dir>/.env` บน VM เท่านั้น — module สร้างโครงเปล่าให้แล้ว **หยุด** ให้ไปกรอก |
| Bearer token | อยู่ใน vhost บน VM — `deploy.sh` อ่านกลับมาให้ทุกครั้ง **จึงไม่ต้องจำ** |

⚠️ ถ้ารัน `terraform apply` ตรง ๆ โดยไม่ส่ง `auth_token` vhost จะถูกเขียนทับเป็นแบบ
ไม่มี auth แล้ว client เดิมจะ 401 — ใช้ `deploy.sh` แทนจะกันให้เอง

## กับดักที่ module นี้แก้ไว้ให้แล้ว

ทั้งหมดเจอจริงตอน deploy แอปตัวแรก ทุกข้อเสียเวลาไปเป็นชั่วโมง

| อาการ | สาเหตุจริง | ที่แก้ |
|---|---|---|
| แอปที่ไล่อ่านไฟล์ทั้งโฟลเดอร์พังด้วย `UnicodeDecodeError` | `bsdtar` บน macOS แนบ AppleDouble (`._xxx`) ที่ไม่ใช่ UTF-8 ขึ้นไปทุกไฟล์ | `COPYFILE_DISABLE=1` + `--exclude='._*'` เป็น default |
| `gcloud: unrecognized arguments: <ครึ่งหลังของ token>` | vhost มี `"` อยู่ข้างใน แต่ถูกห่อด้วย `"` ของ `ssh --command` อีกชั้น | เขียน vhost เป็นไฟล์แล้ว `scp` ไม่ inline |
| deploy รอบสองแล้ว client เดิม 401 | token ถูกสุ่มใหม่/หายตอนเขียน vhost ทับ | `deploy.sh` อ่าน token เดิมจาก vhost บน VM ก่อนเสมอ |
| stream โดนตัดกลางคันแบบไม่มี error | reverse proxy ตั้ง read/write timeout | `long_lived_stream = true` → timeout 0 |
| terraform เขียวแต่ของยังไม่ขึ้น | `docker compose up -d` คืนทันทีโดยไม่รอ container พร้อม | `apply` รอ health check จริงก่อนถือว่าสำเร็จ |
| แอปที่ deploy ทีหลังทำแอปเดิมล่ม | พอร์ตโฮสต์ชนกัน | `deploy.sh` ตรวจพอร์ตบน VM ก่อน apply |
| Caddy restart ทำ vhost ของแอปอื่นสะดุด | ใช้ `docker restart` แทน reload | `caddy reload` |
| **vhost syntax ผิด → Caddy crash-loop → แอปอื่นบน VM ล่มหมด** | template ที่ interpolate บล็อกว่างทำให้ `}` ไปต่อท้ายบรรทัดอื่น (`}  }`) | สร้าง vhost เป็น list ของบรรทัดแล้ว join + **`caddy validate` ก่อน reload เสมอ** ถ้าไม่ผ่านให้ถอด vhost ออกแล้วล้ม apply |
| อยู่หลัง Cloudflare proxy + **Full (strict)** แล้วขอ cert ไม่ได้ | CF ต่อ origin ด้วย HTTPS ตั้งแต่ request แรก แต่ origin ยังไม่มี cert = chicken-and-egg (ACME ไม่ผ่านทั้ง tls-alpn-01 และ http-01) | ใส่ Cloudflare **Origin Certificate** ชั่วคราวให้ CF ต่อติดก่อน แล้ว ACME จะผ่านเองแล้วค่อยถอดออก |
| dev คนที่สอง deploy ไม่ได้ (`tar: Cannot open: Permission denied`) | `chown` ไม่มี `-R` ไฟล์ย่อยยังเป็นของคนแรกที่ deploy | `chown -R <user>:0` + `chmod -R g+w` ทุกครั้งที่ส่ง source |
| cron ที่เขียนไฟล์ล้มเงียบ ๆ หลังเปลี่ยนคน deploy | container รันด้วย gid 0 แต่ group ของไฟล์กลายเป็นของ dev | group เป็น `0` และ `g+w` เสมอ |
| Windows (Git Bash) รัน deploy.sh ไม่ผ่านขั้นตรวจ DNS | ไม่มี `dig` | `deploy.sh` ลอง `dig` → `host` → `nslookup` → `python3` แล้วข้ามถ้าไม่มีเลย |
| bash ตายเงียบ ๆ ไม่มี error | `grep` ไม่เจอ = exit 1 แล้ว `set -e` ฆ่าทั้งสคริปต์ · `"${ARR[@]}"` ของ array ว่างตายใต้ `set -u` (bash 3.2 บน macOS) | `set +e` ตลอดขั้นตรวจ · `${ARR[@]+"${ARR[@]}"}` |

## ใช้เป็น module

```hcl
module "app" {
  source = "github.com/viize-dev/tf-caddy-vm-app"

  project_id = "my-project"
  zone       = "asia-southeast1-b"
  vm_name    = "shared-vm"

  app_name     = "my-app"
  source_dir   = ".."
  source_paths = ["app", "config"]

  domain    = "my-app.example.com"
  host_port = 8080

  env_keys      = ["DB_HOST", "DB_PASSWORD", "PORT=8080"]
  cron_schedule = "17 3 * * *"
  cron_command  = "docker compose exec -T app python job.py"
}
```

ตัวอย่างเต็ม: `examples/property-wiki/`

## ถอนแอปออก

```bash
terraform destroy     # ลบเฉพาะ null_resource — ไม่แตะ VM
```
แล้วเก็บกวาดบน VM:
```bash
sudo rm -rf /opt/<app_name>
sudo rm -f /mnt/data/caddy/conf.d/<app_name>.caddy /etc/cron.d/<app_name>
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```
