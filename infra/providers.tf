# Sem credenciais no código. Autenticação pela CLI do Google:
#   gcloud auth application-default login
# ou por uma chave em GOOGLE_APPLICATION_CREDENTIALS fora do repositório.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # R10: labels aplicadas automaticamente em todos os recursos que suportam labels.
  default_labels = local.labels
}

data "google_project" "this" {
  project_id = var.project_id

  depends_on = [google_project_service.apis]
}

locals {
  labels = {
    projeto    = var.projeto
    grupo      = var.grupo
    entrega    = "2"
    ambiente   = var.ambiente
    gerenciado = "terraform"
  }

  # Sufixo aleatório para nomes que não podem ser reaproveitados depois de um
  # destroy (keyring do KMS) ou que precisam ser globalmente únicos (bucket).
  suffix = random_id.suffix.hex
}

resource "random_id" "suffix" {
  byte_length = 3
}

# APIs necessárias. disable_on_destroy = false evita desligar a API de um
# projeto em uso caso o destroy rode antes de todos os recursos sumirem.
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
