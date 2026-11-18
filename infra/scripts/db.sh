# ===========================================================================
# vm-db: MySQL 8.4 LTS (repositório oficial), usuário da aplicação restrito ao
# IP da vm-backend, TLS obrigatório e dump diário para o bucket de backup.
# ===========================================================================
DB_IP="$(md zad-db-ip)"
BACKEND_IP="$(md zad-backend-ip)"
SECRET_DB="$(md zad-secret-db)"
BACKUP_CRON="$(md zad-backup-cron)"

if [ ! -f /var/lib/zad/db-instalado ]; then
  # Remove sobra de uma execução anterior que falhou: com o repositório
  # inválido já listado, até o primeiro apt-get update abaixo falharia.
  rm -f /etc/apt/sources.list.d/mysql.list
  apt_get update
  apt_get install ca-certificates curl gnupg

  # Repositório APT oficial do MySQL, série 8.4 LTS (a 8.0 chegou ao fim de vida).
  if curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --dearmor --yes -o /usr/share/keyrings/mysql.gpg; then
    echo "deb [signed-by=/usr/share/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu noble mysql-8.4-lts" \
      >/etc/apt/sources.list.d/mysql.list
    # Com set -e, uma assinatura inválida aqui (ex.: EXPKEYSIG da chave 2023
    # expirada) derrubava o script antes da contingência abaixo.
    if ! apt_get update; then
      log "AVISO: repositorio oficial do MySQL com assinatura invalida; removendo"
      rm -f /etc/apt/sources.list.d/mysql.list
      apt_get update
    fi
  fi

  if ! apt_get install mysql-server; then
    # Contingência: se o repositório oficial falhar, usa o MySQL do Ubuntu.
    # Se isso acontecer, registrar na errata.
    log "AVISO: falha no repositorio oficial do MySQL; usando o pacote do Ubuntu"
    rm -f /etc/apt/sources.list.d/mysql.list
    apt_get update
    apt_get install mysql-server
  fi
  touch /var/lib/zad/db-instalado
fi

# Configuração (reaplicada a cada boot).
cat >/etc/mysql/mysql.conf.d/zz-zad.cnf <<EOF
[mysqld]
# Escuta só no IP interno; o firewall libera 3306 apenas para a tag backend.
bind-address             = ${DB_IP}
mysqlx                   = OFF
innodb_buffer_pool_size  = 768M
# Conexões da aplicação precisam usar TLS.
require_secure_transport = ON
EOF
systemctl enable mysql
systemctl restart mysql

# Banco e usuário da aplicação. A senha vem do Secret Manager (S4) e o usuário
# só é aceito a partir do IP da vm-backend. root usa auth_socket (sem senha,
# só a partir do root local).
DB_PASSWORD="$(get_secret "${SECRET_DB}")"
mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS zadinventory CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS 'zad'@'${BACKEND_IP}' IDENTIFIED BY '${DB_PASSWORD}' REQUIRE SSL;
ALTER USER 'zad'@'${BACKEND_IP}' IDENTIFIED BY '${DB_PASSWORD}' REQUIRE SSL;
GRANT ALL PRIVILEGES ON zadinventory.* TO 'zad'@'${BACKEND_IP}';
FLUSH PRIVILEGES;
SQL
unset DB_PASSWORD
log "MySQL configurado (bind ${DB_IP}, usuario zad@${BACKEND_IP})"

# ---------------------------------------------------------------------------
# Backup (Parte D, política mínima - opção A): mysqldump consistente
# (--single-transaction) enviado ao bucket com o token da própria VM.
# A service account só tem roles/storage.objectCreator no bucket.
# ---------------------------------------------------------------------------
cat >/usr/local/bin/zad-backup.sh <<'EOF'
#!/bin/bash
# Gera um dump lógico do banco zadinventory e envia ao bucket de backup,
# sob o prefixo da geração diária (diario/). Uso: sudo zad-backup.sh
set -euo pipefail
MD_URL="http://metadata.google.internal/computeMetadata/v1"
BUCKET="$(curl -fsS -H 'Metadata-Flavor: Google' "${MD_URL}/instance/attributes/zad-backup-bucket")"
TOKEN="$(curl -fsS -H 'Metadata-Flavor: Google' "${MD_URL}/instance/service-accounts/default/token" |
  python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="diario/zadinventory-${TS}.sql.gz"
TMP="$(mktemp /tmp/zad-backup-XXXXXX.sql.gz)"
trap 'rm -f "${TMP}"' EXIT

mysqldump --protocol=socket --single-transaction --routines --triggers --events \
  --databases zadinventory | gzip -9 >"${TMP}"

curl -fsS -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/gzip" \
  --data-binary "@${TMP}" \
  "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=${NAME//\//%2F}" \
  -o /dev/null

echo "Backup enviado: gs://${BUCKET}/${NAME} ($(stat -c %s "${TMP}") bytes)"
logger -t zad-backup "Backup enviado: gs://${BUCKET}/${NAME}"
EOF
chmod 0750 /usr/local/bin/zad-backup.sh

cat >/etc/cron.d/zad-backup <<EOF
# Geração diária (Son) do GFS - política mínima. Gerenciado pelo startup-script.
# Horário no fuso da VM (America/Sao_Paulo, definido em common.sh).
${BACKUP_CRON} root /usr/local/bin/zad-backup.sh >>/var/log/zad-backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/zad-backup
log "rotina de backup instalada (${BACKUP_CRON}, America/Sao_Paulo)"

# Marca para o deploy.sh saber que a inicialização terminou.
touch /var/lib/zad/startup-ok
