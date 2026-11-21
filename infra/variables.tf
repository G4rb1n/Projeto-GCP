# ---------------------------------------------------------------------------
# Projeto e localização
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "ID do projeto GCP dedicado à disciplina (ex.: mega-inventory-gcp)."
}

variable "region" {
  type        = string
  description = "Região das sub-redes, do Cloud NAT e do bucket de backup (ADR justificado na Entrega 1, seção 5.6)."
  default     = "southamerica-east1"
}

variable "zone" {
  type        = string
  description = "Zona única das VMs na arquitetura implantada (sem HA, ver seção 5.10 da Entrega 1)."
  default     = "southamerica-east1-a"
}

# ---------------------------------------------------------------------------
# Labels (R10)
# ---------------------------------------------------------------------------

variable "projeto" {
  type        = string
  description = "Valor da label 'projeto' aplicada a todos os recursos."
  default     = "zadinventory"
}

variable "grupo" {
  type        = string
  description = "Valor da label 'grupo' aplicada a todos os recursos."
  default     = "grupo-6"
}

variable "ambiente" {
  type        = string
  description = "Valor da label 'ambiente' aplicada a todos os recursos."
  default     = "teste"
}

# ---------------------------------------------------------------------------
# Rede (R1, R2)
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  type        = string
  description = "Bloco de planejamento da VPC. Na GCP a VPC não tem CIDR próprio; usado para validar as sub-redes e nas regras de saída internas."
  default     = "10.10.0.0/16"
}

variable "subnet_publica_cidr" {
  type        = string
  description = "CIDR da sub-rede pública zad-publica (bastion e frontend)."
  default     = "10.10.1.0/24"
}

variable "subnet_privada_cidr" {
  type        = string
  description = "CIDR da sub-rede privada zad-privada (backend e banco, sem IP externo, saída pelo Cloud NAT)."
  default     = "10.10.2.0/24"
}

variable "ip_bastion" {
  type        = string
  description = "IP interno fixo da vm-bastion."
  default     = "10.10.1.10"
}

variable "ip_frontend" {
  type        = string
  description = "IP interno fixo da vm-frontend."
  default     = "10.10.1.20"
}

variable "ip_backend" {
  type        = string
  description = "IP interno fixo da vm-backend."
  default     = "10.10.2.10"
}

variable "ip_db" {
  type        = string
  description = "IP interno fixo da vm-db."
  default     = "10.10.2.20"
}

# ---------------------------------------------------------------------------
# Acesso administrativo (R7, R8)
# ---------------------------------------------------------------------------

variable "admin_ssh_cidrs" {
  type        = list(string)
  description = "CIDRs autorizados a abrir SSH no bastion (IP /32 de cada integrante). Nunca 0.0.0.0/0."

  validation {
    condition = length(var.admin_ssh_cidrs) > 0 && alltrue([
      for c in var.admin_ssh_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]), 0) >= 24
    ])
    error_message = "Informe ao menos um CIDR válido com prefixo /24 ou mais específico (ex.: 200.150.10.20/32). 0.0.0.0/0 não é aceito."
  }
}

variable "ssh_user" {
  type        = string
  description = "Usuário Linux criado nas VMs com a chave pública do grupo."
  default     = "zadadmin"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Caminho da chave pública SSH do grupo. A chave privada nunca entra no repositório."
  default     = "~/.ssh/chave-grupo.pub"
}

# ---------------------------------------------------------------------------
# Instâncias (R9)
# ---------------------------------------------------------------------------

variable "image" {
  type        = string
  description = "Imagem do sistema operacional das VMs."
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "machine_type_bastion" {
  type        = string
  description = "Tipo de máquina da vm-bastion (família E2, Entrega 1 seção 5.7)."
  default     = "e2-micro"
}

variable "machine_type_frontend" {
  type        = string
  description = "Tipo de máquina da vm-frontend."
  default     = "e2-micro"
}

variable "machine_type_backend" {
  type        = string
  description = "Tipo de máquina da vm-backend (JVM precisa de 2 GB)."
  default     = "e2-small"
}

variable "machine_type_db" {
  type        = string
  description = "Tipo de máquina da vm-db (buffer pool de 768 MB)."
  default     = "e2-small"
}

# ---------------------------------------------------------------------------
# Aplicação, domínio e TLS (R12, S3)
# ---------------------------------------------------------------------------

variable "domain" {
  type        = string
  description = "Subdomínio DuckDNS que aponta para o IP externo da vm-frontend."
  default     = "megainventory.duckdns.org"
}

variable "duckdns_token" {
  type        = string
  description = "Token do DuckDNS. Fornecer por variável de ambiente (TF_VAR_duckdns_token); vai para o Secret Manager."
  sensitive   = true
}

variable "tls_mode" {
  type        = string
  description = "Certificado HTTPS: selfsigned (testes), letsencrypt-staging (testa a emissão sem gastar o limite) ou letsencrypt (ensaio e apresentação)."
  default     = "selfsigned"

  validation {
    condition     = contains(["selfsigned", "letsencrypt-staging", "letsencrypt"], var.tls_mode)
    error_message = "tls_mode deve ser selfsigned, letsencrypt-staging ou letsencrypt."
  }
}

variable "letsencrypt_email" {
  type        = string
  description = "E-mail para avisos de expiração do Let's Encrypt (opcional)."
  default     = ""
}

# ---------------------------------------------------------------------------
# Backup (Parte D)
# ---------------------------------------------------------------------------

variable "backup_retention_days" {
  type        = number
  description = "Dias até a expiração das cópias da geração diária (política mínima: no máximo 2)."
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 2
    error_message = "A política mínima exige expiração em no máximo 2 dias."
  }
}

variable "backup_cron" {
  type        = string
  description = "Agenda (formato cron) do dump diário na vm-db, no fuso America/Sao_Paulo."
  default     = "0 3 * * *"
}
