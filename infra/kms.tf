# ===========================================================================
# S6: criptografia em repouso declarada explicitamente (CMEK).
# A GCP já criptografa discos e buckets por padrão com chaves do Google; aqui a
# chave é do projeto, criada pelo Terraform e referenciada no código.
#
# O keyring do Cloud KMS não pode ser apagado (limitação do serviço). Por isso
# o nome leva um sufixo aleatório: cada apply após um destroy cria um keyring
# novo e não colide com o anterior. Keyrings vazios não são cobrados, e o
# destroy agenda a destruição das versões das chaves.
# ===========================================================================

resource "google_kms_key_ring" "zad" {
  name     = "zad-keyring-${local.suffix}"
  location = var.region

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "disco" {
  name            = "zad-disco"
  key_ring        = google_kms_key_ring.zad.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 dias

  # Tempo mínimo permitido entre o destroy e a destruição definitiva da versão.
  destroy_scheduled_duration = "86400s"
}

resource "google_kms_crypto_key" "backup" {
  name            = "zad-backup"
  key_ring        = google_kms_key_ring.zad.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"

  destroy_scheduled_duration = "86400s"
}

# O agente de serviço do Compute Engine cifra e decifra os discos com a chave.
resource "google_kms_crypto_key_iam_member" "disco_compute_agent" {
  crypto_key_id = google_kms_crypto_key.disco.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@compute-system.iam.gserviceaccount.com"
}

# O agente de serviço do Cloud Storage cifra os objetos do bucket de backup.
data "google_storage_project_service_account" "gcs" {
  project = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key_iam_member" "backup_gcs_agent" {
  crypto_key_id = google_kms_crypto_key.backup.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}
