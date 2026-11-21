# ADR-005: Estratégia de backup do banco

- **Status:** Aceito
- **Data:** 2026-11-18
- **Decisores:** Grupo 6 (Lipe, Eduardo)
- **Contexto do projeto:** ZadInventory na Google Cloud (`southamerica-east1`), Entrega 2 do Projeto Integrador, Parte D

## Y-statement

No contexto do backup do MySQL do ZadInventory, que roda numa única VM (`vm-db`, ADR-003) e é o único estado da aplicação,
diante de um RPO de 24 h, um RTO de ~1 h e da exigência de que um invasor na VM não consiga apagar as cópias,
decidimos usar **dump lógico diário (`mysqldump --single-transaction`) gravado pela própria VM num bucket regional do Cloud Storage com CMEK, organizado em GFS por prefixo: `diario/` (7 cópias, Standard), `semanal/` (5 cópias de domingo, Nearline) e `mensal/` (12 cópias do último dia do mês, Coldline)**, com a service account da VM limitada a `roles/storage.objectCreator` no bucket,
e descartamos snapshots agendados do disco da VM e o versionamento do bucket como mecanismo de retenção,
para ter cópias consistentes do ponto de vista do banco, independentes do disco e da VM, e restauráveis em qualquer MySQL,
aceitando que a restauração exige reprocessar o dump (minutos, não segundos), que o dump perde até 24 h de dados, que a política mínima implantada no trabalho guarda só 1 dia (um erro descoberto depois disso não pode ser desfeito) e que as cópias Nearline e Coldline têm duração mínima de cobrança (30 e 90 dias) e custo de leitura na restauração.

## Contexto

O plano completo (inventário, RPO/RTO, política, armazenamento, responsabilidade e custos) está em [`docs/backup.md`](../backup.md). A Entrega 1 previa "snapshot do disco + `mysqldump`" (risco 1 da seção 5.10); a errata (item E9) registra a mudança para só dump lógico.

## Decisão

- **Mecanismo:** `/usr/local/bin/zad-backup.sh` na `vm-db`, agendado pelo cron às 03h (America/Sao_Paulo). Gera `mysqldump --single-transaction --routines --triggers --events` comprimido com gzip e envia pela API JSON do Cloud Storage, com o token da service account obtido no servidor de metadados.
- **Local:** bucket regional em `southamerica-east1` (replicado entre zonas da região), separado da VM, com acesso uniforme no nível do bucket, prevenção de acesso público e CMEK (`zad-backup`).
- **Acesso:** a service account `zad-db` só **cria** objetos. Não lê, não lista, não sobrescreve e não apaga. Apagar é tarefa exclusiva das regras de ciclo de vida.
- **Política conservadora (GFS, projetada):** diária 7 dias (Standard); a cópia de domingo também é gravada em `semanal/` e retida 35 dias (Nearline); a cópia do último dia do mês também em `mensal/`, retida 365 dias (Coldline). Uma regra de ciclo de vida por prefixo.
- **Política mínima (implantada no trabalho):** só `diario/`, expirando em 1 dia; regra de segurança apaga qualquer objeto com mais de 2 dias; versionamento e *soft delete* desligados para que nada sobreviva à retenção.

## Alternativas consideradas

| Alternativa | Por que foi descartada |
|---|---|
| **Snapshot agendado do disco** (resource policy) | É *crash-consistent*: equivale a desligar a VM da tomada; o InnoDB costuma se recuperar, mas transações em voo podem se perder. Na política mínima, a agenda só roda no horário marcado, e o ambiente é destruído entre as sessões, então poderia não existir cópia na apresentação. O snapshot também guarda o sistema operacional inteiro, que é reproduzível pelo Terraform |
| **Versionamento do bucket como retenção** | Guardaria versões antigas sem controle por geração e contrariaria o limite de 2 dias da política mínima |
| **Dump para outra região** (ex.: `southamerica-west1`, Santiago) | Protege contra a perda da região inteira, mas tira os dados de clientes do Brasil e adiciona transferência entre regiões. Para o risco aceito (comércio pequeno, RTO de 1 h), a replicação entre zonas do bucket regional basta |
| **Backup automático do Cloud SQL** | Só se aplica se a proposta de HA (ADR-004) for implantada; nesse caso ele cobre a geração diária e o dump continua gerando as gerações semanal e mensal |

## Consequências

**Positivas:**
- Cópias consistentes, portáveis (qualquer MySQL 8 restaura) e pequenas (~77 MB comprimidas no primeiro mês).
- Um invasor com root na `vm-db` não destrói as cópias existentes.
- Custo anual da política conservadora de ~US$ 0,54 (ver `docs/backup.md`, B7).

**Negativas (aceitas):**
- RPO de 24 h: vendas registradas depois do dump das 03h se perdem numa falha antes do próximo dump.
- A política mínima do trabalho só permite voltar ao dia anterior.
- Restaurar a partir de Nearline/Coldline cobra a leitura (US$ 0,01 e 0,02 por GB) e apagar antes da duração mínima cobra o restante do período.
