# ZadInventory — Projeto Integrador (Grupo 6)

Sistema de controle de estoque (**Angular + Spring Boot + MySQL**) e o projeto da sua infraestrutura em **IaaS na Google Cloud**, para a disciplina de Arquitetura em Nuvem.

**Uniamérica Descomplica · Prof. Gildomiro Bairros**

## Integrantes

| Nome | RA | GitHub |
|---|---|---|
| Luiz Felipe Garbin Oliveira | 506064 | [@G4rb1n](https://github.com/G4rb1n) |
| Eduardo Gabriel Dreves Suptitz | 505212 | [@Eduol4](https://github.com/Eduol4) |

> A aplicação ZadInventory foi desenvolvida antes desta disciplina, com
> participação de Pedro Henrique Alves dos Santos, que não integra o grupo
> neste Projeto Integrador. Os commits a partir da Entrega 1 são dos
> integrantes listados acima.

## Visão geral

O ZadInventory controla produtos, categorias, tags e vendas de um pequeno comércio, com dois perfis de acesso (gerente e funcionário) e autenticação JWT.

A arquitetura projetada para a disciplina roda em `southamerica-east1`, dentro de uma VPC própria com duas sub-redes:

- **`zad-publica` (10.10.1.0/24):** `vm-bastion` (SSH administrativo) e `vm-frontend` (Nginx + Angular, único serviço público).
- **`zad-privada` (10.10.2.0/24):** `vm-backend` (Spring Boot) e `vm-db` (MySQL 8.4), sem IP externo e com saída pelo Cloud NAT.

## Documentação da Entrega 1

| Documento | Conteúdo |
|---|---|
| [`docs/arquitetura.md`](docs/arquitetura.md) | Aplicação, diagrama, endereçamento, rotas, segurança, tecnologias, dimensionamento, custos e riscos |
| [`docs/adr/`](docs/adr/) | `001-acesso-administrativo.md`, `002-saida-internet-subrede-privada.md`, `003-localizacao-banco.md` |
| [`docs/diagramas/`](docs/diagramas/) | `arquitetura.drawio` (fonte editável) e `arquitetura.png` |
| [`docs/custos/`](docs/custos/) | Estimativa exportada da Google Cloud Pricing Calculator |
| [`IA.md`](IA.md) | Declaração de uso de IA |
| [`infra/`](infra/) | Terraform da Entrega 2 (rede, NAT, firewall, VMs, segredos, KMS e backup) |

## Entrega 2 — Implantação na GCP

> ⚠️ **Este ambiente gera custo, pago pelo grupo.** O Cloud NAT e os IPs públicos são cobrados por hora mesmo sem tráfego. Suba o ambiente só para testar e **destrua ao final de cada sessão** (`terraform destroy`). Há um alerta de orçamento de R$ 100/mês (≈ US$ 20) na conta de faturamento, criado antes do primeiro `apply`.

Toda a infraestrutura é criada por Terraform em [`infra/`](infra/). O console da GCP serve só para consultar. A aplicação é instalada pelos *startup-scripts* das VMs (pacotes, MySQL, Nginx, TLS, SSH) e pelo [`infra/scripts/deploy.sh`](infra/scripts/deploy.sh) (cópia do JAR e do build do Angular).

### Pré-requisitos

| Ferramenta | Versão | Para quê |
|---|---|---|
| Terraform (ou OpenTofu) | 1.9 ou superior | Criar e destruir a infraestrutura |
| Google Cloud CLI (`gcloud`) | atual | Autenticação do Terraform |
| Bash | Linux, macOS, WSL ou Git Bash | `deploy.sh` |
| JDK 17+ e Node 20+ | — | Build do backend e do frontend no `deploy.sh` |
| Chave SSH do grupo | ed25519 | Acesso às VMs (a privada **nunca** vai para o Git) |

### Passo a passo

**1. Autenticar** (credenciais ficam fora do código):

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project mega-inventory-gcp
```

**2. Chave SSH do grupo** (um integrante gera e compartilha a privada por canal seguro):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/chave-grupo -C "grupo6-zadinventory"
```

**3. Variáveis.** Copie o exemplo e informe o IP /32 de cada integrante (`curl -s https://ifconfig.me`):

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars   # terraform.tfvars está no .gitignore
```

O token do DuckDNS é segredo e vai **só** por variável de ambiente:

```bash
export TF_VAR_duckdns_token="<token do duckdns.org>"          # Bash
# $env:TF_VAR_duckdns_token = "<token do duckdns.org>"        # PowerShell
```

**4. Criar a infraestrutura** (o NAT e as VMs levam alguns minutos):

```bash
terraform -chdir=infra init
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
terraform -chdir=infra output
```

**5. Instalar a aplicação** (espera os *startup-scripts*, compila e copia pelo bastion):

```bash
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/chave-grupo
./infra/scripts/deploy.sh
```

**6. Criar o gerente inicial** (o endpoint só funciona enquanto não existir usuário):

```bash
curl -k -X POST https://megainventory.duckdns.org/api/usuarios/criar-inicial \
  -H "Content-Type: application/json" \
  -d '{"nome":"Gerente","email":"gerente@zad.com","senha":"<senha forte>","tipoUsuario":"GERENTE"}'
```

**Funcionalidade verificável:** entrar com o gerente, cadastrar um produto, recarregar a página e vê-lo listado; registrar uma venda e ver o estoque atualizado.

**7. Ao final da sessão:**

```bash
terraform -chdir=infra destroy
```

### HTTPS

`tls_mode` no `terraform.tfvars` controla o certificado:

| Valor | Quando usar |
|---|---|
| `selfsigned` | Testes do dia a dia (o navegador mostra aviso) |
| `letsencrypt-staging` | Testar a emissão sem consumir o limite do Let's Encrypt |
| `letsencrypt` | Ensaio final e apresentação (limite de 5 certificados iguais por semana) |

O HTTP (porta 80) só atende o desafio do Let's Encrypt e redireciona o resto para HTTPS. A vm-frontend atualiza o DuckDNS com o próprio IP a cada boot.

### Onde investigar problemas

```bash
# Log dos startup-scripts (em qualquer VM)
sudo journalctl -u google-startup-scripts.service -n 200
# Backend
sudo journalctl -u zadinventory -n 100
```

## Código da aplicação

| Pasta | Conteúdo |
|---|---|
| `zadinventory-backend/` | Spring Boot 3.5 (Java 17), projeto Maven em `zadinventory/` |
| `zadinventory-frontend/` | Angular 19 |
| `.github/workflows/` | CI: testes, SpotBugs/ESLint, Trivy/npm audit |

O deploy anterior em Cloud Run + Cloud SQL, e como rodar localmente, estão documentados em [`docs/implantacao-cloud-run.md`](docs/implantacao-cloud-run.md).
