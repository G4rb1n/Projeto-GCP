# ADR-004: Estratégia de alta disponibilidade (proposta)

- **Status:** Proposto (projetado na Entrega 2, não implantado)
- **Data:** 2026-11-18
- **Decisores:** Grupo 6 (Lipe, Eduardo)
- **Contexto do projeto:** ZadInventory na Google Cloud (`southamerica-east1`), Entrega 2 do Projeto Integrador, Parte C

## Y-statement

No contexto da evolução do ZadInventory para alta disponibilidade, hoje com uma única VM por função na zona `southamerica-east1-a` (seção 5.10 da Entrega 1),
diante da necessidade de continuar atendendo se uma VM ou uma zona inteira cair,
decidimos propor **duas zonas (`-a` e `-b`) com grupos gerenciados de instâncias (MIG regionais) para frontend e backend atrás de balanceadores com health check, um único Cloud NAT regional compartilhado pelas duas zonas e o banco no Cloud SQL for MySQL em configuração HA (primária em `-a`, standby síncrona em `-b`)**,
e descartamos a réplica MySQL própria em VM e um NAT por zona,
para eliminar os pontos únicos de falha da aplicação com failover automático, sem o grupo operar replicação de banco,
aceitando que o custo mensal em operação contínua sobe de **US$ 75,25 para US$ 264,51 (+252%, calculadora oficial)**, puxado principalmente pelo Cloud SQL HA (~58% do total) e pelo balanceamento de carga, que o banco sai da VPC do grupo para a rede do Google conectada por peering (contrariando o motivo do ADR-003) e que, para o perfil de uso da Entrega 1, esse custo não se justifica.

## Contexto

A arquitetura implantada (ADR-001 a ADR-003) tem dez limitações listadas na seção 5.10 da Entrega 1. Quatro delas são pontos únicos de falha da aplicação: a `vm-db` única (1), a zona única (2), a `vm-frontend` como única porta de entrada (3) e a CPU compartilhada sem escala (6). O requisito de disponibilidade da seção 5.1 é **horário comercial, para até 20 usuários de um comércio pequeno**, com RPO de 24 h e RTO de ~1 h.

O documento completo da proposta, com diagrama, endereçamento, fluxos e custo, está em [`docs/alta-disponibilidade.md`](../alta-disponibilidade.md).

## Decisão

| Camada | Proposta |
|---|---|
| Zonas | `southamerica-east1-a` e `southamerica-east1-b`. As sub-redes da GCP são regionais e já cobrem as duas zonas; o endereçamento ganha a sub-rede só de proxy do balanceador e a faixa reservada ao Cloud SQL |
| Entrada | **Load balancer de aplicação externo** (HTTPS, certificado gerenciado pelo Google) → MIG regional `mig-frontend` (2× e2-micro, uma por zona), health check HTTP `/healthz` no Nginx |
| API | **Load balancer de rede interno de passagem** (`10.10.2.100:8080`) → MIG regional `mig-backend` (2× e2-small, uma por zona), health check HTTP `/actuator/health`; autoescalonamento de 2 a 4 instâncias por CPU |
| NAT | **Um Cloud NAT regional compartilhado** (`zad-nat`), como hoje |
| Banco | **Cloud SQL for MySQL 8.4, Enterprise, HA regional** (`db-custom-1-3840`), primária em `-a` e standby em `-b`, IP privado por Private Service Access, backups automáticos e PITR |
| Estado | JWT sem estado no servidor (nenhuma sessão em memória); a aplicação não recebe arquivos enviados; banco é o único estado |
| Acesso admin | Bastion em MIG de 1 instância com autocorreção (recriado sozinho em outra zona se a VM ou a zona cair) |

## Alternativas consideradas

| Alternativa | Por que foi descartada |
|---|---|
| **Réplica MySQL própria** (primária em `-a`, réplica em `-b`, replicação assíncrona) | Mais barata (~US$ 156/mês no total, +108%) e mantém o banco na VPC do grupo. Mas o failover é manual ou exige um orquestrador (Orchestrator, MySQL Router), a replicação assíncrona pode perder as últimas transações na troca e o grupo passaria a operar replicação, promoção e reconfiguração do backend. Para quem não tem DBA, o Cloud SQL HA entrega failover automático em ~60 s sem perda de transação confirmada (disco regional síncrono) |
| **NAT por zona** (dois gateways) | Na GCP o Cloud NAT não é uma instância numa zona: é um serviço regional definido por software, que continua atendendo a zona que sobrou se a outra cair. Dois gateways não aumentam a disponibilidade e dobram o custo fixo de gateway e IP |
| **Banco na mesma zona com snapshot frequente** | Não elimina o ponto único: uma falha zonal deixaria o sistema fora até restaurar o snapshot em outra zona (RTO de dezenas de minutos e perda desde o último snapshot) |
| **Load balancer interno de aplicação (proxy) para a API** | Cobra por instância de proxy (mínimo de três) e não acrescenta nada que a API precise; o de passagem (camada 4) basta para distribuir TCP 8080 com health check |

## Consequências

**Positivas:**
- Nenhuma VM isolada nem a perda de uma zona derruba a aplicação: os balanceadores tiram do ar as instâncias que falham no health check e o MIG as recria.
- O banco faz failover automático para a outra zona sem perder transação confirmada; backups e PITR passam a ser do serviço.
- O autoescalonamento do backend resolve o limite de CPU compartilhada (risco 6).

**Negativas (aceitas):**
- Custo ~3,5× maior em operação contínua. Os itens que mais pesam são o Cloud SQL HA (US$ 153,15) e o balanceamento de carga (US$ 27,79, cobrado por hora mesmo sem tráfego).
- O banco deixa de ficar sob as regras de firewall por tag da VPC: o acesso passa a depender do peering de Private Service Access, de usuário e senha e de TLS do Cloud SQL. Isso contraria a justificativa do ADR-003; se a proposta for implantada, o ADR-003 passa a "substituído" por este.
- O Cloud SQL não é destruído e recriado em minutos como a VM; o ciclo `apply`/`destroy` por sessão fica mais lento e o nome da instância fica reservado por até uma semana depois de apagada.
- **Para 20 usuários em horário comercial, com RTO de 1 h aceito pelo negócio, o custo não se justifica.** A recriação por Terraform mais a restauração do dump atende o RTO pela fração do preço. A proposta passa a fazer sentido se o comércio operar 24×7 ou tiver várias lojas usando o sistema ao mesmo tempo.
