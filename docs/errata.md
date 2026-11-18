# Errata: Entrega 1 × o que foi implantado na Entrega 2

Este documento lista toda divergência entre o projeto da Entrega 1 (`docs/arquitetura.md` e ADRs 001 a 003) e o que foi efetivamente implantado pelo Terraform em `infra/`, com o motivo. Mudanças em decisões citam o ADR afetado.

**Situação dos ADRs da Entrega 1 após a implantação:**

| ADR | Status | Observação |
|---|---|---|
| [ADR-001](adr/001-acesso-administrativo.md) Acesso administrativo (bastion) | Aceito, mantido | A forma de gerenciar as chaves SSH mudou (OS Login → chave via metadados): ver [ADR-006](adr/006-chave-ssh-por-metadados.md) |
| [ADR-002](adr/002-saida-internet-subrede-privada.md) Saída pela Cloud NAT | Aceito, mantido | A consequência aceita ("o NAT não filtra destinos") foi mitigada por regras de saída (item E2) |
| [ADR-003](adr/003-localizacao-banco.md) MySQL em VM privada | Aceito, mantido | Implantado como projetado. Na proposta de HA (não implantada), o banco passaria ao Cloud SQL: ver [ADR-004](adr/004-alta-disponibilidade.md) |
| [ADR-004](adr/004-alta-disponibilidade.md) Estratégia de alta disponibilidade | Novo (proposta) | Parte C |
| [ADR-005](adr/005-backup.md) Estratégia de backup | Novo | Parte D |
| [ADR-006](adr/006-chave-ssh-por-metadados.md) Chave SSH por metadados | Novo | Substitui o OS Login previsto na seção 5.5 |

## Divergências

| # | Item | Projetado na Entrega 1 | Implantado na Entrega 2 | Motivo | ADR |
|---|---|---|---|---|---|
| E1 | Gestão das chaves SSH | **OS Login** (`roles/compute.osLogin`), seção 5.5 | Chave pública do grupo informada ao Terraform e gravada nos metadados de cada VM (`ssh-keys`), com `block-project-ssh-keys = true` e `enable-oslogin = FALSE` | O requisito R8 pede a chave pública informada ao Terraform; o OS Login exigiria conceder papéis IAM a cada integrante no projeto e não usa a chave da variável | [ADR-006](adr/006-chave-ssh-por-metadados.md) |
| E2 | Saída para a internet | Saída implícita permitida para tudo (matriz 5.5; risco 7 da seção 5.10) | Regra `zad-deny-egress-all` (prioridade 65000) bloqueia toda saída; liberações explícitas acima dela: 80/443 para a internet, 8080 frontend→backend, 3306 backend→db, 22 bastion→rede interna e DNS/NTP/metadados para `169.254.169.254` | Controle S2 da Entrega 2. Elimina o risco 7 para portas não web | ADR-002 mantido |
| E3 | Rota padrão | "Automática na criação da VPC" (seção 5.4) | A VPC é criada com `delete_default_routes_on_create = true` e a rota `0.0.0.0/0 → default-internet-gateway` é declarada no Terraform (`zad-rota-padrao-internet`) | Deixa a rota explícita no código (R3), em vez de depender de um recurso criado implicitamente | - |
| E4 | Acesso às APIs do Google | Não previsto | **Private Google Access** ligado em `zad-publica` e `zad-privada` | As VMs privadas leem o Secret Manager e gravam no Cloud Storage pela rede interna do Google, sem passar pelo Cloud NAT. Achado CKV_GCP_74 do Checkov | - |
| E5 | Segredos da aplicação | Arquivo de ambiente do systemd com permissão `600` (seção 5.5), sem dizer de onde vêm os valores | Senha do banco e segredo JWT **gerados pelo Terraform** (`random_password`, `random_bytes`) e guardados no **Secret Manager**; o token do DuckDNS também. A VM lê o segredo no boot e grava o arquivo `600` | Controle S4. Ninguém digita nem conhece a senha do banco | - |
| E6 | Identidade das VMs | Não especificada (seria a conta de serviço padrão do Compute, com papel Editor) | Uma service account por VM (`zad-bastion`, `zad-frontend`, `zad-backend`, `zad-db`), **sem nenhum papel no projeto**; permissões concedidas no próprio segredo ou bucket | Controle S5 (menor privilégio) | - |
| E7 | Criptografia em repouso | Padrão da GCP (chaves do Google) | **CMEK**: chaves `zad-disco` e `zad-backup` no Cloud KMS, rotação de 90 dias, aplicadas a todos os discos e ao bucket de backup | Controle S6: a criptografia precisa estar declarada no código | - |
| E8 | Conexão backend → banco | JDBC sem TLS | MySQL com `require_secure_transport = ON`; usuário `zad` criado com `REQUIRE SSL`; JDBC com `sslMode=REQUIRED` | Controle S3 estendido ao tráfego interno | - |
| E9 | Backup do banco | Snapshot do disco + `mysqldump` diário (risco 1 da seção 5.10) | Só **dump lógico** (`mysqldump --single-transaction`) gravado em bucket com CMEK, sob o prefixo `diario/`, expirando em 1 dia (política mínima) | O dump é consistente do ponto de vista do banco e independe do disco; o snapshot seria redundante para a política mínima. Detalhes no plano GFS | [ADR-005](adr/005-backup.md) |
| E10 | Versão do MySQL | MySQL 8.4 LTS do repositório oficial | No primeiro teste (18/11) a VM caiu na contingência e instalou o **MySQL 8.0.46 do Ubuntu**: a chave GPG `RPM-GPG-KEY-mysql-2023` do repositório oficial expirou em 22/10/2025. O `db.sh` foi corrigido para a chave `RPM-GPG-KEY-mysql-2025` | A série 8.0 está fora de suporte. **Confirmar no ensaio de 21/11** que a VM sobe com 8.4; se não subir, manter este item como desvio aceito | ADR-003 mantido |
| E11 | Proxy de autenticação | O auth-proxy em Go "deixa de ser necessário" (seção 5.1) | O Nginx copia o header `Authorization` para `X-App-Authorization` e limpa o `Authorization` original ao repassar `/api/` ao backend | O backend procura o JWT do usuário em `X-App-Authorization` (herança do deploy em Cloud Run, em que o `Authorization` carregava o token do IAM). Sem o mapeamento, todo login falharia | - |
| E12 | Nome da variável dos IPs administrativos | `admin_ips` | `admin_ssh_cidrs`, com validação no Terraform que rejeita prefixos menores que /24 (inclusive `0.0.0.0/0`) | Nome mais preciso; a validação impede o erro mais grave da entrega | - |
| E13 | Alerta de orçamento | US$ 20 | R$ 100/mês (≈ US$ 20), com avisos em 50%, 90% e 100% | A conta de faturamento é em reais | - |
| E14 | Projeto GCP | "Projeto dedicado" (seção 5.9) | Projeto `mega-inventory-gcp` (nome "Mega Inventory GCP"), conta de faturamento "Projeto integrador" | Implementação do item 4 do plano de controle de custos | - |
| E15 | Rede `default` do projeto | Não mencionada | **Removida** em 18/11, junto com as regras `default-allow-ssh` e `default-allow-rdp`, que liberavam 22 e 3389 para `0.0.0.0/0` | Nenhuma VM a usava; deixá-la existir mantinha portas administrativas abertas no projeto | - |
| E16 | Registros de tráfego | Não previstos | VPC Flow Logs nas duas sub-redes (amostragem de 50%, agregação de 10 min), log das regras `zad-allow-ssh-admin` e `zad-deny-egress-all`, log de erros do Cloud NAT | Rastreabilidade das demonstrações e dos ataques; achado CKV_GCP_26 | - |
| E17 | Endurecimento das VMs | Não previsto | Shielded VM (Secure Boot, vTPM, monitoramento de integridade) e console serial desligado | Boas práticas apontadas pelas ferramentas de análise | - |
| E18 | Pasta dos diagramas | `docs/diagrama/` | `docs/diagramas/`, com `arquitetura.png` | Estrutura exigida pela Entrega 2 | - |
| E19 | Instalação da aplicação | Não detalhada | Startup-scripts das VMs (`infra/scripts/*.sh`) instalam e configuram tudo; `infra/scripts/deploy.sh` compila e copia o JAR e o build do Angular pelo bastion | R12 | - |
| E20 | Finais de linha dos scripts | - | `.gitattributes` força LF em `*.sh`, `*.tf` e `mvnw` | No Windows, com `core.autocrlf=true`, os scripts saíam com CRLF e quebrariam o boot de todas as VMs | - |
