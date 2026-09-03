output "url" {
  description = "endpoint สาธารณะของแอป"
  value       = "https://${var.domain}"
}

output "vm_ip" {
  description = "IP ของ VM — ต้องชี้ DNS มาที่นี่ และ allowlist ที่ปลายทางอื่น (เช่น DB) ด้วย"
  value       = data.google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "remote_dir" {
  value = local.remote_dir
}

output "ssh_command" {
  value = "gcloud compute ssh ${var.vm_name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "logs_command" {
  value = "gcloud compute ssh ${var.vm_name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap --command 'cd ${local.remote_dir} && sudo docker compose logs -f --tail=50'"
}

output "cron_log_command" {
  description = "ดู log ของ cron (ว่างถ้าไม่ได้ตั้ง cron)"
  value       = var.cron_schedule == "" ? "" : "gcloud compute ssh ${var.vm_name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap --command 'sudo tail -50 /var/log/${var.app_name}-cron.log'"
}
