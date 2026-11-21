# ===========================================================================
# Parte D - Política mínima de backup (opção A: dump lógico em object storage).
# Só a geração "Son" (diária) do GFS, com expiração em var.backup_retention_days.
# O dump é gerado na vm-db (scripts/db.sh) e enviado com a identidade da VM,
# que só tem permissão de CRIAR objetos neste bucket (iam.tf).
# ===========================================================================

resource "google_storage_bucket" "backup" {
  name          = "${var.project_id}-zad-backup-${local.suffix}"
  location      = upper(var.region) # bucket regional: cópias replicadas entre zonas da região
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Permite que o terraform destroy apague o bucket mesmo com cópias dentro
  # (seção 11 do enunciado: não podem restar buckets ao final).
  force_destroy = true

  # S6: criptografia com a chave do projeto (CMEK), declarada no código.
  encryption {
    default_kms_key_name = google_kms_crypto_key.backup.id
  }

  # Sem versionamento: versões antigas ficariam guardadas além da retenção.
  versioning {
    enabled = false
  }

  # Sem "soft delete": por padrão a GCP guarda objetos apagados por 7 dias,
  # o que ultrapassaria o limite de 2 dias da política mínima.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # Geração diária (Son): expira após var.backup_retention_days.
  lifecycle_rule {
    condition {
      age            = var.backup_retention_days
      matches_prefix = ["diario/"]
    }
    action {
      type = "Delete"
    }
  }

  # Rede de segurança: nada fica no bucket por mais de 2 dias.
  lifecycle_rule {
    condition {
      age = 2
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.backup_gcs_agent]
}
