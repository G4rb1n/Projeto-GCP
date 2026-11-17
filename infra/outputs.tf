# R11: IP público do recurso de acesso, IP público do NAT, IPs privados e URL.

output "bastion_public_ip" {
  description = "IP externo (efêmero) da vm-bastion, usado no SSH administrativo."
  value       = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
}

output "frontend_public_ip" {
  description = "IP externo estático da vm-frontend, para onde o DuckDNS aponta."
  value       = google_compute_address.frontend.address
}

output "nat_public_ip" {
  description = "IP público do Cloud NAT. Deve ser o IP de origem visto pela internet a partir das VMs privadas (curl ifconfig.me)."
  value       = google_compute_address.nat.address
}

output "private_ips" {
  description = "IPs internos das VMs."
  value = {
    bastion  = google_compute_instance.bastion.network_interface[0].network_ip
    frontend = google_compute_instance.frontend.network_interface[0].network_ip
    backend  = google_compute_instance.backend.network_interface[0].network_ip
    db       = google_compute_instance.db.network_interface[0].network_ip
  }
}

output "app_url" {
  description = "URL HTTPS da aplicação."
  value       = "https://${var.domain}"
}

output "app_url_ip" {
  description = "URL HTTPS pelo IP (útil antes da propagação do DNS)."
  value       = "https://${google_compute_address.frontend.address}"
}

output "ssh_user" {
  description = "Usuário Linux das VMs."
  value       = var.ssh_user
}

output "ssh_bastion" {
  description = "Comando para entrar no bastion."
  value       = "ssh ${var.ssh_user}@${google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip}"
}

output "ssh_backend_via_bastion" {
  description = "Comando para entrar na vm-backend saltando pelo bastion."
  value       = "ssh -J ${var.ssh_user}@${google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip} ${var.ssh_user}@${var.ip_backend}"
}

output "backup_bucket" {
  description = "Bucket da política mínima de backup."
  value       = google_storage_bucket.backup.name
}
