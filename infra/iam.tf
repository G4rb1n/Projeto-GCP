# ===========================================================================
# S5: uma service account por função, sem nenhum papel no nível do projeto.
# Cada permissão é concedida no próprio recurso (segredo ou bucket), só para a
# ação necessária. Nenhuma chave de service account é criada: as VMs obtêm
# tokens de curta duração pelo servidor de metadados.
# ===========================================================================

resource "google_service_account" "bastion" {
  account_id   = "zad-bastion"
  display_name = "ZadInventory - bastion (sem permissoes)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "frontend" {
  account_id   = "zad-frontend"
  display_name = "ZadInventory - frontend (le o token do DuckDNS)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "backend" {
  account_id   = "zad-backend"
  display_name = "ZadInventory - backend (le senha do banco e segredo JWT)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "db" {
  account_id   = "zad-db"
  display_name = "ZadInventory - banco (le senha do banco, grava backups)"

  depends_on = [google_project_service.apis]
}

# --- Segredos: acesso de leitura a segredos específicos ---------------------

resource "google_secret_manager_secret_iam_member" "backend_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_secret_manager_secret_iam_member" "backend_jwt" {
  secret_id = google_secret_manager_secret.jwt_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_secret_manager_secret_iam_member" "db_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.db.email}"
}

resource "google_secret_manager_secret_iam_member" "frontend_duckdns" {
  secret_id = google_secret_manager_secret.duckdns_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.frontend.email}"
}

# --- Backup: a vm-db só CRIA objetos no bucket de backup ---------------------
# roles/storage.objectCreator não permite ler, listar, sobrescrever nem apagar.
# Um invasor com acesso à vm-db não consegue destruir as cópias existentes.

resource "google_storage_bucket_iam_member" "db_backup_writer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.db.email}"
}
