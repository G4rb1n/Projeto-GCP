# ===========================================================================
# vm-frontend: Nginx servindo o Angular e fazendo proxy de /api/ para a
# vm-backend; HTTPS (S3) com redirecionamento de 80 para 443; atualização do
# DuckDNS com o IP externo da VM.
# ===========================================================================
DOMAIN="$(md zad-domain)"
BACKEND_IP="$(md zad-backend-ip)"
TLS_MODE="$(md zad-tls-mode)"
LE_EMAIL="$(md zad-le-email || true)"
SECRET_DUCKDNS="$(md zad-secret-duckdns)"
EXT_IP="$(md_path instance/network-interfaces/0/access-configs/0/external-ip)"

if [ ! -f /var/lib/zad/frontend-instalado ]; then
  apt_get update
  apt_get install nginx certbot openssl curl
  install -d -m 0755 /var/www/zadinventory /var/www/letsencrypt /etc/ssl/zad
  echo "<h1>ZadInventory: aguardando deploy</h1>" >/var/www/zadinventory/index.html
  touch /var/lib/zad/frontend-instalado
fi

# --- DuckDNS: aponta o domínio para o IP externo desta VM -------------------
SUBDOMAIN="${DOMAIN%%.duckdns.org}"
DUCKDNS_TOKEN="$(get_secret "${SECRET_DUCKDNS}")"
if [ "$(curl -fsS "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${EXT_IP}")" = "OK" ]; then
  log "DuckDNS: ${DOMAIN} -> ${EXT_IP}"
else
  log "AVISO: falha ao atualizar o DuckDNS"
fi
unset DUCKDNS_TOKEN

# --- Certificado autoassinado (sempre existe, para o Nginx poder subir) -----
if [ ! -f /etc/ssl/zad/selfsigned.crt ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},IP:${EXT_IP}" \
    -keyout /etc/ssl/zad/selfsigned.key -out /etc/ssl/zad/selfsigned.crt
  chmod 0600 /etc/ssl/zad/selfsigned.key
fi
if [ ! -e /etc/ssl/zad/current.crt ]; then
  ln -sf /etc/ssl/zad/selfsigned.crt /etc/ssl/zad/current.crt
  ln -sf /etc/ssl/zad/selfsigned.key /etc/ssl/zad/current.key
fi

# --- Nginx -------------------------------------------------------------------
cat >/etc/nginx/sites-available/zadinventory <<'EOF'
# Gerenciado pelo startup-script do ZadInventory
server_tokens off;

# HTTP: só o desafio do Let's Encrypt; todo o resto redireciona para HTTPS (S3).
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     /etc/ssl/zad/current.crt;
    ssl_certificate_key /etc/ssl/zad/current.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;

    add_header Strict-Transport-Security "max-age=86400" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root /var/www/zadinventory;
    index index.html;

    # API: proxy para a vm-backend (rede interna). O backend lê o JWT do
    # usuário no header X-App-Authorization (herança do deploy em Cloud Run).
    location /api/ {
        proxy_pass http://__BACKEND_IP__:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-App-Authorization $http_authorization;
        proxy_set_header Authorization "";
        client_max_body_size 2m;
    }

    # Angular (SPA): rotas desconhecidas voltam para o index.html.
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
sed -i "s/__BACKEND_IP__/${BACKEND_IP}/" /etc/nginx/sites-available/zadinventory
ln -sf /etc/nginx/sites-available/zadinventory /etc/nginx/sites-enabled/zadinventory
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx
log "Nginx no ar (HTTPS com certificado $(readlink /etc/ssl/zad/current.crt))"

# --- Let's Encrypt (opcional, conforme var.tls_mode) ------------------------
if [ "${TLS_MODE}" != "selfsigned" ] && [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  # Espera o DNS do DuckDNS apontar para esta VM (até ~5 minutos).
  for _ in $(seq 1 30); do
    RESOLVED="$(getent ahostsv4 "${DOMAIN}" | awk 'NR==1 {print $1}' || true)"
    [ "${RESOLVED}" = "${EXT_IP}" ] && break
    sleep 10
  done

  CERTBOT_ARGS=(certonly --webroot -w /var/www/letsencrypt -d "${DOMAIN}" --non-interactive --agree-tos --keep-until-expiring)
  if [ -n "${LE_EMAIL}" ]; then
    CERTBOT_ARGS+=(-m "${LE_EMAIL}")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi
  if [ "${TLS_MODE}" = "letsencrypt-staging" ]; then
    CERTBOT_ARGS+=(--staging)
  fi

  if certbot "${CERTBOT_ARGS[@]}"; then
    ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/ssl/zad/current.crt
    ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/ssl/zad/current.key
    systemctl reload nginx
    log "Certificado Let's Encrypt (${TLS_MODE}) instalado para ${DOMAIN}"
  else
    log "AVISO: falha no Let's Encrypt; mantendo o certificado autoassinado"
  fi
fi

# Marca para o deploy.sh saber que a inicialização terminou.
touch /var/lib/zad/startup-ok
