# ---------------------------------------------------------------------------
# R1: VPC em modo custom. Na GCP a VPC é global e não tem CIDR próprio; o
# bloco var.vpc_cidr (10.10.0.0/16) é a reserva de planejamento da Entrega 1.
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "zad-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  # A rota padrão automática é removida e recriada abaixo, explícita no código (R3).
  delete_default_routes_on_create = true

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# R2: sub-redes pública e privada
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "publica" {
  name          = "zad-publica"
  ip_cidr_range = var.subnet_publica_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true

  # VPC Flow Logs com amostragem de 50% e agregação de 10 min: rastreabilidade
  # do tráfego com volume de log baixo (dentro da cota gratuita do Logging).
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "privada" {
  name          = "zad-privada"
  ip_cidr_range = var.subnet_privada_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  # As VMs privadas alcançam as APIs do Google (Secret Manager, Cloud Storage)
  # pela rede interna do Google, sem passar pelo Cloud NAT.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# R3: saída para a internet. Na GCP não existe tabela de rotas por sub-rede:
# a rota pertence à VPC. As VMs com IP externo (bastion, frontend) saem por ela
# com o próprio IP; as VMs sem IP externo só saem porque o Cloud NAT (R4)
# traduz o endereço de origem.
# ---------------------------------------------------------------------------
resource "google_compute_route" "default_internet" {
  name             = "zad-rota-padrao-internet"
  network          = google_compute_network.vpc.id
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
  description      = "Rota padrao 0.0.0.0/0 para o internet gateway (R3). O Cloud NAT depende dela."
}

# ---------------------------------------------------------------------------
# R4: Cloud NAT gerenciado com IP público estático, aplicado só à zad-privada.
# O Cloud NAT não é um próximo salto de rota: a tradução acontece na rede
# definida por software do Google para as VMs sem IP externo da sub-rede.
# ---------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "zad-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_address" "nat" {
  name         = "zad-nat-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_router_nat" "nat" {
  name   = "zad-nat"
  router = google_compute_router.router.name
  region = var.region

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = [google_compute_address.nat.self_link]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.privada.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
