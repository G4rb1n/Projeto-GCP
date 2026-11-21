# ===========================================================================
# vm-backend: OpenJDK 17 + serviço systemd do Spring Boot (perfil "vm").
# O JAR é copiado depois pelo infra/scripts/deploy.sh (via bastion).
# ===========================================================================
DB_IP="$(md zad-db-ip)"
SECRET_DB="$(md zad-secret-db)"
SECRET_JWT="$(md zad-secret-jwt)"

if [ ! -f /var/lib/zad/backend-instalado ]; then
  apt_get update
  apt_get install openjdk-17-jre-headless curl
  id zad >/dev/null 2>&1 || useradd --system --home /opt/zadinventory --shell /usr/sbin/nologin zad
  install -d -o zad -g zad -m 0750 /opt/zadinventory
  touch /var/lib/zad/backend-instalado
fi

# Segredos lidos do Secret Manager a cada boot (S4) e gravados num arquivo
# legível só pelo root. O systemd lê o arquivo antes de trocar para o usuário zad.
install -d -m 0700 /etc/zadinventory
DB_PASSWORD="$(get_secret "${SECRET_DB}")"
JWT_SECRET="$(get_secret "${SECRET_JWT}")"
umask 077
{
  echo "SPRING_PROFILES_ACTIVE=vm"
  echo "DB_HOST=${DB_IP}"
  echo "DB_NAME=zadinventory"
  echo "DB_USER=zad"
  echo "DB_PASSWORD=${DB_PASSWORD}"
  echo "JWT_SECRET=${JWT_SECRET}"
} >/etc/zadinventory/zadinventory.env
chmod 0600 /etc/zadinventory/zadinventory.env
umask 022
unset DB_PASSWORD JWT_SECRET

cat >/etc/systemd/system/zadinventory.service <<'EOF'
[Unit]
Description=ZadInventory API (Spring Boot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/opt/zadinventory/app.jar

[Service]
User=zad
Group=zad
EnvironmentFile=/etc/zadinventory/zadinventory.env
ExecStart=/usr/bin/java -Xms256m -Xmx1g -jar /opt/zadinventory/app.jar
Restart=on-failure
RestartSec=10
SuccessExitStatus=143
# Endurecimento do processo
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/zadinventory

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zadinventory.service
if [ -f /opt/zadinventory/app.jar ]; then
  systemctl restart zadinventory.service
  log "zadinventory reiniciado"
else
  log "aguardando o deploy do JAR (infra/scripts/deploy.sh)"
fi

# Marca para o deploy.sh saber que a inicialização terminou.
touch /var/lib/zad/startup-ok
