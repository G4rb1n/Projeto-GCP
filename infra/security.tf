# ===========================================================================
# R7 + S2: regras de firewall da VPC, aplicadas por tag de rede (matriz da
# Entrega 1, seção 5.5). Regras implícitas da GCP (não removíveis):
#   - nega toda entrada   (prioridade 65535)
#   - permite toda saída  (prioridade 65535) -> anulada por "zad-deny-egress-all"
# ===========================================================================

locals {
  tag_bastion  = "bastion"
  tag_frontend = "frontend"
  tag_backend  = "backend"
  tag_db       = "db"
  todas_tags   = [local.tag_bastion, local.tag_frontend, local.tag_backend, local.tag_db]
}

# ---------------------------------------------------------------------------
# ENTRADA
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "allow_web" {
  name        = "zad-allow-web"
  network     = google_compute_network.vpc.id
  description = "Unico servico publico: Nginx na vm-frontend. 80 so redireciona para 443 e atende o desafio do Let's Encrypt."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.tag_frontend]
}

resource "google_compute_firewall" "allow_ssh_admin" {
  name        = "zad-allow-ssh-admin"
  network     = google_compute_network.vpc.id
  description = "SSH no bastion apenas a partir dos IPs /32 dos integrantes (var.admin_ssh_cidrs). Nunca 0.0.0.0/0."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.admin_ssh_cidrs
  target_tags   = [local.tag_bastion]

  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_ssh_interno" {
  name        = "zad-allow-ssh-interno"
  network     = google_compute_network.vpc.id
  description = "So o bastion abre SSH nas demais VMs (ProxyJump)."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_tags = [local.tag_bastion]
  target_tags = [local.tag_frontend, local.tag_backend, local.tag_db]
}

resource "google_compute_firewall" "allow_api" {
  name        = "zad-allow-api"
  network     = google_compute_network.vpc.id
  description = "So o Nginx da vm-frontend chama a API na porta 8080."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_tags = [local.tag_frontend]
  target_tags = [local.tag_backend]
}

resource "google_compute_firewall" "allow_mysql" {
  name        = "zad-allow-mysql"
  network     = google_compute_network.vpc.id
  description = "So a vm-backend acessa o MySQL."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }

  source_tags = [local.tag_backend]
  target_tags = [local.tag_db]
}

# ---------------------------------------------------------------------------
# SAÍDA (S2). Uma regra de bloqueio geral com prioridade baixa e liberações
# específicas acima dela. Respostas a conexões de entrada permitidas não
# precisam de regra: o firewall da GCP é stateful.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "deny_egress_all" {
  name        = "zad-deny-egress-all"
  network     = google_compute_network.vpc.id
  description = "Bloqueia toda saida que nao foi liberada explicitamente pelas regras abaixo (S2)."
  direction   = "EGRESS"
  priority    = 65000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_egress_web" {
  name        = "zad-allow-egress-web"
  network     = google_compute_network.vpc.id
  description = "HTTP/HTTPS de saida: pacotes (apt, repo.mysql.com), APIs do Google, Let's Encrypt e DuckDNS."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = local.todas_tags
}

resource "google_compute_firewall" "allow_egress_metadata" {
  name        = "zad-allow-egress-metadata"
  network     = google_compute_network.vpc.id
  description = "DNS, NTP e metadados pelo servidor de metadados da GCP (a GCP ja sempre permite; regra explicita para documentacao)."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "udp"
    ports    = ["53", "123"]
  }

  allow {
    protocol = "tcp"
    ports    = ["53", "80"]
  }

  destination_ranges = ["169.254.169.254/32"]
  target_tags        = local.todas_tags
}

resource "google_compute_firewall" "allow_egress_ssh_interno" {
  name        = "zad-allow-egress-ssh-interno"
  network     = google_compute_network.vpc.id
  description = "Bastion abre SSH para as VMs internas (ProxyJump)."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  destination_ranges = [var.subnet_publica_cidr, var.subnet_privada_cidr]
  target_tags        = [local.tag_bastion]
}

resource "google_compute_firewall" "allow_egress_api" {
  name        = "zad-allow-egress-api"
  network     = google_compute_network.vpc.id
  description = "Nginx da vm-frontend chama a API da vm-backend."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  destination_ranges = ["${var.ip_backend}/32"]
  target_tags        = [local.tag_frontend]
}

resource "google_compute_firewall" "allow_egress_mysql" {
  name        = "zad-allow-egress-mysql"
  network     = google_compute_network.vpc.id
  description = "Porta do banco liberada apenas da vm-backend para a vm-db."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }

  destination_ranges = ["${var.ip_db}/32"]
  target_tags        = [local.tag_backend]
}
