#!/usr/bin/env bash
# ===========================================================================
# Instala a aplicação nas VMs depois do `terraform apply`.
#   1. Compila o backend (JAR) e o frontend (Angular) na máquina local.
#   2. Copia os artefatos pelo bastion (ProxyJump) e reinicia os serviços.
#   3. Espera o backend responder /actuator/health.
#
# Uso (na raiz do repositório, com a chave do grupo no ssh-agent):
#   eval "$(ssh-agent -s)"; ssh-add ~/.ssh/chave-grupo
#   ./infra/scripts/deploy.sh             # compila e instala
#   ./infra/scripts/deploy.sh --sem-build # reaproveita artefatos já compilados
#
# Requisitos locais: bash (Linux, macOS, WSL ou Git Bash), terraform, ssh, scp,
# JDK 17 (ou superior) e Node 20+ (para o build).
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INFRA="${ROOT}/infra"
BACKEND_DIR="${ROOT}/zadinventory-backend/zadinventory"
FRONTEND_DIR="${ROOT}/zadinventory-frontend"
TF="${TF:-terraform}"

BUILD=1
[ "${1:-}" = "--sem-build" ] && BUILD=0

out() { "${TF}" -chdir="${INFRA}" output -raw "$1"; }

SSH_USER="$(out ssh_user)"
BASTION="$(out bastion_public_ip)"
PRIVATE_IPS="$("${TF}" -chdir="${INFRA}" output -json private_ips | tr -d ' \n')"
BACKEND_IP="$(sed -E 's/.*"backend":"([^"]+)".*/\1/' <<<"${PRIVATE_IPS}")"
FRONTEND_IP="$(sed -E 's/.*"frontend":"([^"]+)".*/\1/' <<<"${PRIVATE_IPS}")"
APP_URL="$(out app_url)"

# Cada apply recria as VMs com novas chaves de host. Um known_hosts temporário
# evita o erro de "host key changed" entre sessões; dentro da sessão, a chave
# é fixada na primeira conexão (accept-new).
# As opções vão num arquivo de config (-F) e não em -o: o ssh repassa o -F para
# o processo do ProxyJump (-J), mas não repassa os -o, e o salto pelo bastion
# falharia com "Host key verification failed".
KNOWN_HOSTS="$(mktemp)"
SSH_CFG="$(mktemp)"
trap 'rm -f "${KNOWN_HOSTS}" "${SSH_CFG}"' EXIT
cat >"${SSH_CFG}" <<EOF
Host *
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${KNOWN_HOSTS}
  ConnectTimeout 15
  ServerAliveInterval 30
EOF
SSH_OPTS=(-F "${SSH_CFG}")
JUMP=(-J "${SSH_USER}@${BASTION}")

ssh_to() { local host="$1"; shift; ssh "${SSH_OPTS[@]}" "${JUMP[@]}" "${SSH_USER}@${host}" "$@"; }

echo "==> Bastion ${BASTION} | backend ${BACKEND_IP} | frontend ${FRONTEND_IP}"

if [ "${BUILD}" = "1" ]; then
  echo "==> Compilando o backend"
  # O repositório não versiona .mvn/wrapper (mesmo motivo do backend.yml usar
  # `mvn`); usa o wrapper só se ele estiver completo.
  MVN="mvn"
  [ -f "${BACKEND_DIR}/.mvn/wrapper/maven-wrapper.properties" ] && MVN="./mvnw"
  command -v "${MVN}" >/dev/null 2>&1 || [ "${MVN}" = "./mvnw" ] || { echo "Maven não encontrado (instale o Maven 3.9+ ou adicione .mvn/wrapper)"; exit 1; }
  (cd "${BACKEND_DIR}" && "${MVN}" -B -q -DskipTests package)
  echo "==> Compilando o frontend"
  (cd "${FRONTEND_DIR}" && npm ci --no-audit --no-fund && npx ng build --configuration production)
fi

JAR=""
for f in "${BACKEND_DIR}"/target/zadinventory-*.jar; do
  case "${f}" in *-plain.jar) ;; *) JAR="${f}" ;; esac
done
DIST="${FRONTEND_DIR}/dist/zadinventory-frontend/browser"
[ -f "${JAR}" ] || { echo "JAR não encontrado em ${BACKEND_DIR}/target"; exit 1; }
[ -f "${DIST}/index.html" ] || { echo "Build do Angular não encontrado em ${DIST}"; exit 1; }

echo "==> Esperando os startup-scripts terminarem"
for host in "${BACKEND_IP}" "${FRONTEND_IP}"; do
  for _ in $(seq 1 60); do
    if ssh_to "${host}" "test -f /var/lib/zad/startup-ok"; then
      break
    fi
    sleep 10
  done
done

echo "==> Enviando o backend"
scp "${SSH_OPTS[@]}" -o ProxyJump="${SSH_USER}@${BASTION}" "${JAR}" "${SSH_USER}@${BACKEND_IP}:/tmp/app.jar"
ssh_to "${BACKEND_IP}" "sudo install -o zad -g zad -m 0640 /tmp/app.jar /opt/zadinventory/app.jar && rm -f /tmp/app.jar && sudo systemctl restart zadinventory"

echo "==> Enviando o frontend"
tar -C "${DIST}" -czf - . | ssh_to "${FRONTEND_IP}" \
  "sudo find /var/www/zadinventory -mindepth 1 -delete && sudo tar -xzf - -C /var/www/zadinventory && sudo chown -R root:root /var/www/zadinventory && sudo chmod -R a+rX /var/www/zadinventory"

echo "==> Aguardando o backend (Spring Boot pode levar ~1-2 min numa e2-small)"
for _ in $(seq 1 40); do
  if ssh_to "${BACKEND_IP}" "curl -fsS http://localhost:8080/actuator/health" 2>/dev/null | grep -q '"UP"'; then
    echo "==> Backend UP"
    echo "==> Aplicação: ${APP_URL}"
    exit 0
  fi
  sleep 10
done

echo "Backend não respondeu. Veja os logs: ssh -J ${SSH_USER}@${BASTION} ${SSH_USER}@${BACKEND_IP} 'sudo journalctl -u zadinventory -n 100'"
exit 1
