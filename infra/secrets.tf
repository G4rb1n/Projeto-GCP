# ===========================================================================
# S4: segredos da aplicação no Secret Manager, fora do código e do Git.
# - Senha do banco e segredo JWT são gerados pelo Terraform (ninguém digita).
# - O token do DuckDNS vem de TF_VAR_duckdns_token (variável sensível).
# As VMs leem os valores no boot com a própria service account (S5).
#
# Os valores também ficam no terraform.tfstate, que é local e está no
# .gitignore. Esse risco está registrado em docs/seguranca.md.
# ===========================================================================

resource "random_password" "db_app" {
  length  = 32
  special = false
}

# O backend decodifica o segredo JWT em Base64 (JwtService.getSignInKey) e o
# HS256 exige ao menos 256 bits: 48 bytes aleatórios em Base64.
resource "random_bytes" "jwt" {
  length = 48
}

locals {
  secret_replication_region = var.region
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "zad-db-password"

  replication {
    user_managed {
      replicas {
        location = local.secret_replication_region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_app.result
}

resource "google_secret_manager_secret" "jwt_secret" {
  secret_id = "zad-jwt-secret"

  replication {
    user_managed {
      replicas {
        location = local.secret_replication_region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "jwt_secret" {
  secret      = google_secret_manager_secret.jwt_secret.id
  secret_data = random_bytes.jwt.base64
}

resource "google_secret_manager_secret" "duckdns_token" {
  secret_id = "zad-duckdns-token"

  replication {
    user_managed {
      replicas {
        location = local.secret_replication_region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "duckdns_token" {
  secret      = google_secret_manager_secret.duckdns_token.id
  secret_data = var.duckdns_token
}
