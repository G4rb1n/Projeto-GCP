# Plano de backup (Parte D)

Decisão registrada no [ADR-005](adr/005-backup.md). Mecanismo implantado: **dump lógico do MySQL gravado em object storage (opção A)**.

## B1. Inventário

| Ativo | Precisa de backup? | Mecanismo | Justificativa |
|---|---|---|---|
| **Banco `zadinventory`** (usuários, produtos, categorias, tags, operações de venda) | **Sim** | Dump lógico diário em GFS | É o único estado da aplicação e não pode ser recriado pelo código |
| Arquivos enviados pelos usuários | Não existem | - | A aplicação não recebe upload de arquivos; tudo é registro no banco |
| `terraform.tfstate` | Não, por decisão | - | O state é local e o ambiente é destruído ao fim de cada sessão; a infraestrutura inteira é recriada pelo código. Em produção contínua passaria a *remote state* num bucket com versionamento |
| Código (Terraform, scripts, aplicação) | Já protegido | Git + GitHub | Versionado no repositório remoto |
| Configuração das VMs (Nginx, MySQL, systemd, SSH) | Não | - | Gerada pelos startup-scripts a cada boot (`infra/scripts/`) |
| Sistema operacional e pacotes | Não | - | Imagem pública do Ubuntu 24.04 + `apt`, reinstalados a cada `apply` |
| Segredos (senha do banco, JWT, token DuckDNS) | Não | - | Senha e JWT são regenerados pelo Terraform a cada ambiente novo; o token do DuckDNS fica com o grupo (variável de ambiente) e pode ser regenerado no site |
| Chaves KMS | Não aplicável | - | Gerenciadas pelo Cloud KMS. Cuidado: um dump cifrado com uma chave destruída fica ilegível, por isso o plano prevê destruir o keyring só depois de expirarem as cópias |
| Certificado TLS | Não | - | Reemitido pelo Let's Encrypt |

## B2. RPO e RTO

| Meta | Valor | Justificativa pelo uso da aplicação (seção 5.1 da Entrega 1) |
|---|---|---|
| **RPO** | **24 h** | Comércio pequeno, até 20 usuários em horário comercial. Perder as vendas de um dia é recuperável a partir dos cupons e notas do próprio caixa; um backup diário fora do horário de uso (03h) captura o dia inteiro. Reduzir o RPO exigiria binlog contínuo ou réplica, desproporcional ao negócio |
| **RTO** | **1 h** | Fora do ar, o comércio volta a anotar no papel por algumas horas sem parar de vender. 1 h cobre `terraform apply` (~5 min), startup-scripts (~10 min), `deploy.sh` (~10 min) e restauração do dump (minutos para centenas de MB) |

Restauração (passo a passo):
```bash
# 1. Recriar o ambiente e instalar a aplicação
terraform -chdir=infra apply && ./infra/scripts/deploy.sh
# 2. Baixar o dump escolhido (conta de um integrante, não a SA da VM)
gcloud storage cp gs://<bucket>/diario/zadinventory-<data>.sql.gz .
# 3. Enviar para a vm-db pelo bastion e restaurar
scp -J zadadmin@<bastion> zadinventory-<data>.sql.gz zadadmin@10.10.2.20:/tmp/
ssh -J zadadmin@<bastion> zadadmin@10.10.2.20 \
  "sudo systemctl stop --no-block zadinventory; gunzip -c /tmp/zadinventory-*.sql.gz | sudo mysql"
```

## B3. Política conservadora (GFS)

| Geração | Prefixo | Frequência | Promoção | Retenção | Classe | Duração mínima de cobrança |
|---|---|---|---|---|---|---|
| **Son** (diária) | `diario/` | Todo dia às 03h | - | **7 dias** (7 cópias) | Standard | Nenhuma |
| **Father** (semanal) | `semanal/` | Domingo | O dump de domingo é gravado também em `semanal/` | **35 dias** (5 cópias) | Nearline | 30 dias |
| **Grandfather** (mensal) | `mensal/` | Último dia do mês | O dump do último dia do mês é gravado também em `mensal/` | **365 dias** (12 cópias) | Coldline | 90 dias |

- **Mecanismo (projetado; o implantado é só a geração Son, B6):** o mesmo `zad-backup.sh` da política mínima seria estendido para decidir os prefixos pela data (`date +%u` = 7 → domingo; `date -d tomorrow +%d` = 01 → último dia do mês) e enviar cada objeto já na classe da geração (cabeçalho `x-goog-storage-class` da API XML), evitando a cobrança de uma transição de classe.
- **Expiração:** uma regra de ciclo de vida `Delete` por prefixo (`age` 7, 35 e 365), criada pelo Terraform como as regras atuais de `infra/backup.tf`.
- **Por que essas retenções:** 7 dias cobrem um erro percebido durante a semana; 5 semanas garantem uma cópia do fechamento do mês anterior mesmo em meses de 5 domingos; 12 meses cobrem consultas de vendas do ano e o fechamento fiscal.
- **Por que essas classes:** cada classe tem duração mínima menor que a retenção da geração (30 < 35; 90 < 365), então não há cobrança de exclusão antecipada. Archive (mínimo de 365 dias) foi descartado para o Grandfather porque a cópia de 12 meses seria apagada no limite exato do mínimo, e a leitura (US$ 0,05/GB) é a mais cara.

## B4. Armazenamento

| Requisito | Como é atendido |
|---|---|
| Fora da instância | Bucket do Cloud Storage, independente da VM e do disco; o `terraform destroy` da VM não afeta as cópias em produção (no trabalho o bucket também é destruído, por exigência do encerramento) |
| Outra zona/região | Bucket **regional** `southamerica-east1`: os objetos são replicados de forma redundante entre zonas da região. Perder a zona `-a` (onde está a `vm-db`) não perde backups. Uma cópia em outra região foi descartada no ADR-005 |
| Criptografia (S6) | CMEK `zad-backup` como chave padrão do bucket; todo objeto gravado herda a chave (verificável com `gcloud storage objects describe ... --format="value(kms_key)"`) |
| Acesso restrito (S5) | Acesso uniforme no nível do bucket, prevenção de acesso público **forçada**; a SA `zad-db` só tem `roles/storage.objectCreator` (cria, não lê/lista/apaga); leitura para restauração só por um integrante autenticado |

## B5. Responsabilidade compartilhada

| Ativo | O provedor (Google) garante | O grupo é responsável por |
|---|---|---|
| Banco em VM (`vm-db`) | Durabilidade do disco persistente e da infraestrutura física | **Tudo do backup**: gerar o dump, agendar, verificar que roda, testar a restauração, atualizar o MySQL. Nenhum backup é feito pelo Google para dados dentro da VM |
| Objetos no bucket | Durabilidade de 11 noves, replicação entre zonas, execução das regras de ciclo de vida | Definir retenção e classes, proteger a permissão de escrita, não destruir a chave KMS antes das cópias expirarem, monitorar se novas cópias continuam chegando |
| Chaves KMS | Disponibilidade e rotação automática configurada | Não destruir/desativar a chave enquanto houver cópias cifradas com ela |
| Proposta de HA (Cloud SQL, ADR-004) | Backups automáticos diários, PITR, failover | Configurar retenção, gerar as gerações semanal e mensal por exportação, testar restauração |

## B6. Política mínima configurada

Só a geração **Son**, configurada inteiramente pelo Terraform:

| Requisito | Implementação | Onde |
|---|---|---|
| Configuração por código | Bucket, regras de ciclo de vida, CMEK e permissão da SA criados pelo Terraform; script e cron instalados pelo startup-script | `infra/backup.tf`, `infra/iam.tf`, `infra/scripts/db.sh` |
| Retenção | Regra 1: `Delete` em `diario/` com `age = var.backup_retention_days` (**1 dia**; a variável aceita só 1 ou 2). Regra 2 (segurança): `Delete` em qualquer objeto com `age = 2`. Versionamento desligado e **soft delete = 0** (por padrão a GCP guardaria objetos apagados por 7 dias) | `infra/backup.tf` |
| Criptografia | CMEK `zad-backup` | `infra/kms.tf`, `infra/backup.tf` |
| Identidade (opção A) | A VM grava com a própria SA, que só tem `objectCreator` neste bucket | `infra/iam.tf` |
| Prefixo da geração | `diario/zadinventory-<AAAAMMDDTHHMMSSZ>.sql.gz` | `infra/scripts/db.sh` |
| Agendamento | Cron diário às 03h (America/Sao_Paulo) e execução manual com `sudo zad-backup.sh` | `/etc/cron.d/zad-backup` |
| Existência de cópia | Na apresentação: `sudo zad-backup.sh` na vm-db e `gcloud storage ls -l gs://<bucket>/diario/` | Demonstração D6 |

**Expiração assíncrona.** A documentação do Cloud Storage informa que as ações de ciclo de vida são assíncronas: depois que um objeto atinge a condição, pode levar até 24 horas para ele ser apagado. Com `age = 1`, a cópia some entre 1 e 2 dias depois de criada, dentro do limite de 2 dias; a regra de segurança com `age = 2` garante o teto.

**O que a política mínima não protege, em comparação com a conservadora:**
- Um erro (exclusão acidental, corrupção, ataque) percebido **depois de 1 dia** não pode ser desfeito: a única cópia já reflete o problema ou expirou.
- Não há como consultar o estado de semanas ou meses anteriores (fechamento mensal, auditoria).
- Se o dump de uma noite falhar, a janela sem cópia válida começa imediatamente; na GFS ainda restariam as 6 diárias anteriores.
- No trabalho, o `terraform destroy` apaga o bucket junto com o ambiente: não há cópia entre sessões.

## B7. Custos

### Política conservadora: 12 meses

**Premissas:**
- Banco com **0,30 GB** no mês 1 e crescimento de **0,03 GB/mês** (~200 vendas/dia com itens, índices e histórico de operações).
- Dump comprimido = **25%** do tamanho do banco (texto SQL sem índices, gzip).
- Retenção em regime: 7 Son + 5 Father + até 12 Grandfather (no mês 1: 7 + 4 + 1). Cada cópia tem o tamanho do banco no mês em que foi feita.
- Preços unitários de São Paulo (`southamerica-east1`) **obtidos na calculadora oficial** em 21/11/2026 (<https://cloud.google.com/products/calculator?dl=CjhDaVJrWVdJd09EazNOeTA1TURBMUxUUmpPR1l0WW1RNVpTMWtNR0psWWpSa01qWmpZVE1RQVE9PRAJGiQ1MEYyOTJENi1FQ0NDLTREMjMtOERGQy05NjlDOUI1OEVBOEU>; exportação em [`custos/estimativa-backup-calculadora.csv`](custos/estimativa-backup-calculadora.csv), cujo link interno é outro snapshot da mesma estimativa). Com o volume do mês 12 (1,1 GiB Standard, 0,8 GiB Nearline, 1,4 GiB Coldline), a calculadora devolveu US$ 0,0385 + US$ 0,016 + US$ 0,0098 = **US$ 0,0643/mês**, o mesmo valor do mês 12 da tabela abaixo. Valores de operação e leitura são da tabela pública de preços do Cloud Storage:

| Item | Standard | Nearline | Coldline |
|---|---|---|---|
| Armazenamento (US$/GB-mês) | 0,035 | 0,020 | 0,007 |
| Operações classe A, gravação (US$/1.000) | 0,005 | 0,010 | 0,020 |
| Leitura na restauração (US$/GB) | 0 | 0,01 | 0,02 |
| Duração mínima | - | 30 dias | 90 dias |

- Operações: ~30 gravações diárias + 4 semanais + 1 mensal por mês. Exclusões pelo ciclo de vida não são cobradas. Transferência: o dump sai da vm-db para o Cloud Storage na mesma região pela rede do Google (Private Google Access), sem cobrança de egress. Restauração não incluída (não é exigida).

| Mês | Volume do banco | Tamanho da cópia | Cópias retidas (S + F + G) | Volume em backup | Custo mensal |
|---|---|---|---|---|---|
| 1 | 307 MB | 77 MB | 7 + 4 + 1 = 12 | 922 MB | US$ 0,025 |
| 2 | 338 MB | 84 MB | 7 + 5 + 2 = 14 | 1.175 MB | US$ 0,030 |
| 3 | 369 MB | 92 MB | 7 + 5 + 3 = 15 | 1.359 MB | US$ 0,033 |
| 4 | 399 MB | 100 MB | 7 + 5 + 4 = 16 | 1.551 MB | US$ 0,036 |
| 5 | 430 MB | 108 MB | 7 + 5 + 5 = 17 | 1.751 MB | US$ 0,040 |
| 6 | 461 MB | 115 MB | 7 + 5 + 6 = 18 | 1.958 MB | US$ 0,043 |
| 7 | 492 MB | 123 MB | 7 + 5 + 7 = 19 | 2.173 MB | US$ 0,046 |
| 8 | 522 MB | 131 MB | 7 + 5 + 8 = 20 | 2.396 MB | US$ 0,050 |
| 9 | 553 MB | 138 MB | 7 + 5 + 9 = 21 | 2.627 MB | US$ 0,053 |
| 10 | 584 MB | 146 MB | 7 + 5 + 10 = 22 | 2.865 MB | US$ 0,057 |
| 11 | 614 MB | 154 MB | 7 + 5 + 11 = 23 | 3.110 MB | US$ 0,061 |
| 12 | 645 MB | 161 MB | 7 + 5 + 12 = 24 | 3.364 MB | US$ 0,064 |
| **Total no ano** | | | | | **US$ 0,54** |

Planilha: [`custos/gfs-12-meses.csv`](custos/gfs-12-meses.csv). O custo cresce todo mês porque o Grandfather acumula uma cópia por mês até chegar a 12 e porque cada cópia nova é maior.

**Parâmetro de maior impacto: a retenção da geração diária (Son).** Ela responde por **~63%** do custo anual (Father ~26%, Grandfather ~10%), porque guarda o maior número de cópias na classe mais cara. Simulações com o mesmo volume:

| Variação | Custo anual | Diferença |
|---|---|---|
| Política proposta | US$ 0,54 | - |
| Son retido 30 dias em vez de 7 | US$ 1,66 | +209% |
| Son retido 3 dias em vez de 7 | US$ 0,34 | -36% |
| Tudo em Standard (sem Nearline/Coldline) | US$ 0,87 | +61% |
| Grandfather retido 6 meses em vez de 12 | US$ 0,53 | -2% |

Reduzir o Son para 3 dias economizaria ~US$ 0,20/ano, mas um erro percebido na sexta-feira sobre algo feito na segunda deixaria de ter cópia diária anterior a ele, e a restauração recuaria até o domingo (perda de até uma semana em vez de um dia). Para este volume, o custo de backup é irrelevante perto do custo das VMs (US$ 75/mês); a decisão deve ser guiada pelo RPO e pela janela de descoberta de erros, não pelo preço.

### Política mínima no período do trabalho

Na mesma estimativa da calculadora, a política mínima foi lançada como **0,01 GiB em Standard** (uma cópia do banco de teste por vez, retida no máximo 2 dias): **US$ 0,00035/mês**, ou seja, US$ 0,00 arredondado, próximo de zero como exigido. Somando as operações de gravação (alguns dumps por sessão, ~5 sessões) e a chave KMS `zad-backup` (US$ 0,06 por versão de chave ativa por mês, proporcional às horas em que o ambiente existe, ~US$ 0,01), o **total estimado é de ~US$ 0,01 no período**. O valor real será comparado no painel de faturamento após a apresentação (`docs/custos/`).
