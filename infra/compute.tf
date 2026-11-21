# ===========================================================================
# R5, R6, R8, R9: instâncias, chave SSH e IP público estático.
# ===========================================================================

locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # Metadados de acesso repetidos em todas as VMs (explícitos em cada uma para
  # que a análise estática consiga verificá-los):
  #  - ssh-keys: só a chave do grupo, para o usuário var.ssh_user (R8).
  #  - block-project-ssh-keys: ignora chaves de projeto (ninguém entra por fora).
  #  - enable-oslogin FALSE: o acesso é pela chave informada ao Terraform (ver ADR-006).
  #  - serial-port-enable FALSE: console serial interativo desligado.
  ssh_keys_metadata = "${var.ssh_user}:${local.ssh_public_key}"

  # Script de inicialização = biblioteca comum + script da função da VM.
  # Os valores de configuração chegam por metadados (zad-*), não pelo script.
  startup = {
    for role in ["bastion", "frontend", "backend", "db"] :
    role => join("\n", [
      file("${path.module}/scripts/common.sh"),
      file("${path.module}/scripts/${role}.sh"),
    ])
  }

  shielded = {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
}

# R6: IP externo estático da vm-frontend, que expõe a aplicação.
resource "google_compute_address" "frontend" {
  name         = "zad-frontend-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# vm-bastion (zad-publica, IP externo efêmero)
# ---------------------------------------------------------------------------
resource "google_compute_instance" "bastion" {
  name         = "vm-bastion"
  machine_type = var.machine_type_bastion
  zone         = var.zone
  tags         = [local.tag_bastion]
  labels       = { funcao = "bastion" }

  allow_stopping_for_update = true

  boot_disk {
    kms_key_self_link = google_kms_crypto_key.disco.id

    initialize_params {
      image  = var.image
      size   = 10
      type   = "pd-standard"
      labels = merge(local.labels, { funcao = "bastion" })
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.publica.id
    network_ip = var.ip_bastion

    access_config {
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email  = google_service_account.bastion.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = local.shielded.enable_secure_boot
    enable_vtpm                 = local.shielded.enable_vtpm
    enable_integrity_monitoring = local.shielded.enable_integrity_monitoring
  }

  metadata = {
    ssh-keys               = local.ssh_keys_metadata
    block-project-ssh-keys = true
    enable-oslogin         = "FALSE"
    serial-port-enable     = false
    startup-script         = local.startup["bastion"]
  }

  depends_on = [google_kms_crypto_key_iam_member.disco_compute_agent]
}

# ---------------------------------------------------------------------------
# vm-frontend (zad-publica, IP externo estático) - Nginx + Angular + TLS
# ---------------------------------------------------------------------------
resource "google_compute_instance" "frontend" {
  name         = "vm-frontend"
  machine_type = var.machine_type_frontend
  zone         = var.zone
  tags         = [local.tag_frontend]
  labels       = { funcao = "frontend" }

  allow_stopping_for_update = true

  boot_disk {
    kms_key_self_link = google_kms_crypto_key.disco.id

    initialize_params {
      image  = var.image
      size   = 10
      type   = "pd-standard"
      labels = merge(local.labels, { funcao = "frontend" })
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.publica.id
    network_ip = var.ip_frontend

    access_config {
      nat_ip       = google_compute_address.frontend.address
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email  = google_service_account.frontend.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = local.shielded.enable_secure_boot
    enable_vtpm                 = local.shielded.enable_vtpm
    enable_integrity_monitoring = local.shielded.enable_integrity_monitoring
  }

  metadata = {
    ssh-keys               = local.ssh_keys_metadata
    block-project-ssh-keys = true
    enable-oslogin         = "FALSE"
    serial-port-enable     = false
    startup-script         = local.startup["frontend"]
    zad-domain             = var.domain
    zad-backend-ip         = var.ip_backend
    zad-tls-mode           = var.tls_mode
    zad-le-email           = var.letsencrypt_email
    zad-secret-duckdns     = google_secret_manager_secret.duckdns_token.secret_id
  }

  depends_on = [
    google_kms_crypto_key_iam_member.disco_compute_agent,
    google_secret_manager_secret_version.duckdns_token,
    google_secret_manager_secret_iam_member.frontend_duckdns,
  ]
}

# ---------------------------------------------------------------------------
# vm-backend (zad-privada, SEM IP externo) - Spring Boot
# ---------------------------------------------------------------------------
resource "google_compute_instance" "backend" {
  name         = "vm-backend"
  machine_type = var.machine_type_backend
  zone         = var.zone
  tags         = [local.tag_backend]
  labels       = { funcao = "backend" }

  allow_stopping_for_update = true

  boot_disk {
    kms_key_self_link = google_kms_crypto_key.disco.id

    initialize_params {
      image  = var.image
      size   = 20
      type   = "pd-balanced"
      labels = merge(local.labels, { funcao = "backend" })
    }
  }

  # R5: sem bloco access_config = sem IP externo. A saída é pelo Cloud NAT.
  network_interface {
    subnetwork = google_compute_subnetwork.privada.id
    network_ip = var.ip_backend
  }

  service_account {
    email  = google_service_account.backend.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = local.shielded.enable_secure_boot
    enable_vtpm                 = local.shielded.enable_vtpm
    enable_integrity_monitoring = local.shielded.enable_integrity_monitoring
  }

  metadata = {
    ssh-keys               = local.ssh_keys_metadata
    block-project-ssh-keys = true
    enable-oslogin         = "FALSE"
    serial-port-enable     = false
    startup-script         = local.startup["backend"]
    zad-db-ip              = var.ip_db
    zad-secret-db          = google_secret_manager_secret.db_password.secret_id
    zad-secret-jwt         = google_secret_manager_secret.jwt_secret.secret_id
  }

  depends_on = [
    google_kms_crypto_key_iam_member.disco_compute_agent,
    google_compute_router_nat.nat,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_version.jwt_secret,
    google_secret_manager_secret_iam_member.backend_db_password,
    google_secret_manager_secret_iam_member.backend_jwt,
  ]
}

# ---------------------------------------------------------------------------
# vm-db (zad-privada, SEM IP externo) - MySQL 8.4 + dump diário para o bucket
# ---------------------------------------------------------------------------
resource "google_compute_instance" "db" {
  name         = "vm-db"
  machine_type = var.machine_type_db
  zone         = var.zone
  tags         = [local.tag_db]
  labels       = { funcao = "db" }

  allow_stopping_for_update = true

  boot_disk {
    kms_key_self_link = google_kms_crypto_key.disco.id

    initialize_params {
      image  = var.image
      size   = 20
      type   = "pd-balanced"
      labels = merge(local.labels, { funcao = "db" })
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.privada.id
    network_ip = var.ip_db
  }

  service_account {
    email  = google_service_account.db.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = local.shielded.enable_secure_boot
    enable_vtpm                 = local.shielded.enable_vtpm
    enable_integrity_monitoring = local.shielded.enable_integrity_monitoring
  }

  metadata = {
    ssh-keys               = local.ssh_keys_metadata
    block-project-ssh-keys = true
    enable-oslogin         = "FALSE"
    serial-port-enable     = false
    startup-script         = local.startup["db"]
    zad-db-ip              = var.ip_db
    zad-backend-ip         = var.ip_backend
    zad-secret-db          = google_secret_manager_secret.db_password.secret_id
    zad-backup-bucket      = google_storage_bucket.backup.name
    zad-backup-cron        = var.backup_cron
  }

  depends_on = [
    google_kms_crypto_key_iam_member.disco_compute_agent,
    google_compute_router_nat.nat,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_iam_member.db_db_password,
    google_storage_bucket_iam_member.db_backup_writer,
  ]
}
