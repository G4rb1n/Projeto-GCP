#!/bin/bash
# ===========================================================================
# Biblioteca comum dos startup-scripts (concatenada antes do script da função).
# Roda como root a CADA boot da VM; as etapas de instalação são idempotentes.
# Log: sudo journalctl -u google-startup-scripts.service
# ===========================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MD_URL="http://metadata.google.internal/computeMetadata/v1"

# Lê um atributo zad-* dos metadados da instância.
md() {
  curl -fsS -H "Metadata-Flavor: Google" "${MD_URL}/instance/attributes/$1"
}

md_path() {
  curl -fsS -H "Metadata-Flavor: Google" "${MD_URL}/$1"
}

PROJECT_ID="$(md_path project/project-id)"

# Token OAuth de curta duração da service account da VM (S5: sem chaves gravadas).
sa_token() {
  md_path "instance/service-accounts/default/token" |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])'
}

# Lê a versão mais recente de um segredo do Secret Manager (S4).
# Tenta por até ~5 minutos: permissões IAM recém-criadas levam um tempo para
# propagar, e o startup-script pode rodar antes disso no primeiro boot.
get_secret() {
  local name="$1" resp
  for _ in $(seq 1 20); do
    if resp="$(curl -fsS -H "Authorization: Bearer $(sa_token)" \
      "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${name}/versions/latest:access")"; then
      python3 -c 'import sys, json, base64; sys.stdout.write(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode())' <<<"${resp}"
      return 0
    fi
    sleep 15
  done
  echo "[zad-startup] ERRO: nao foi possivel ler o segredo ${name}" >&2
  return 1
}

apt_get() {
  apt-get -o DPkg::Lock::Timeout=600 -y "$@"
}

log() {
  echo "[zad-startup] $*"
}

# S1: endurecimento do SSH. O arquivo 00-* é lido antes do 50-cloud-init.conf
# do Ubuntu e, no sshd, o primeiro valor encontrado é o que vale.
harden_ssh() {
  cat >/etc/ssh/sshd_config.d/00-zad-hardening.conf <<'EOF'
# Gerenciado pelo startup-script do ZadInventory (controle S1)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
EOF
  chmod 0644 /etc/ssh/sshd_config.d/00-zad-hardening.conf
  sshd -t
  systemctl reload ssh || systemctl reload sshd || true
  log "SSH endurecido (senha e root desativados)"
}

mkdir -p /var/lib/zad
timedatectl set-timezone America/Sao_Paulo || true
harden_ssh
