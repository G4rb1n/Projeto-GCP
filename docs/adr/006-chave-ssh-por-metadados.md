# ADR-006: Chave SSH do grupo por metadados em vez de OS Login

- **Status:** Aceito
- **Data:** 2026-11-18
- **Decisores:** Grupo 6 (Lipe, Eduardo)
- **Contexto do projeto:** ZadInventory na Google Cloud (`southamerica-east1`), Entrega 2 do Projeto Integrador
- **Relação:** complementa o [ADR-001](001-acesso-administrativo.md) (o bastion continua); substitui o uso de **OS Login** previsto na seção 5.5 da Entrega 1 (errata E1)

## Y-statement

No contexto da autenticação SSH no bastion e, por ProxyJump, nas VMs internas do ZadInventory,
diante do requisito R8 (par de chaves com a chave pública informada ao Terraform) e do controle S1 (sem senha, sem root),
decidimos **gravar a chave pública do grupo nos metadados de cada VM pelo Terraform (`ssh-keys`), bloquear as chaves do projeto (`block-project-ssh-keys = true`), desligar o OS Login (`enable-oslogin = FALSE`) e endurecer o `sshd` no boot** (`PasswordAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`),
e descartamos o OS Login e o IAP com TCP forwarding,
para que o acesso fique inteiramente descrito no código, sem depender de papéis IAM por integrante,
aceitando que todos os integrantes compartilham a mesma chave privada (não há rastreio de quem entrou, e revogar um integrante exige trocar a chave e rodar `apply` em todas as VMs) e que a chave foi gerada sem senha.

## Contexto

A Entrega 1 previa OS Login, que associa o acesso SSH a papéis IAM (`roles/compute.osLogin`) e gera as chaves por usuário Google. O enunciado da Entrega 2 exige que a chave pública seja informada ao Terraform (R8), e o projeto `mega-inventory-gcp` pertence à conta de um único integrante: com OS Login, o outro precisaria receber papéis IAM no projeto.

## Decisão

- Variáveis `ssh_user` (padrão `zadadmin`) e `ssh_public_key_path` (padrão `~/.ssh/chave-grupo.pub`).
- Metadados repetidos explicitamente em cada VM, para que a análise estática (CKV_GCP_32) os verifique.
- `infra/scripts/common.sh` grava `/etc/ssh/sshd_config.d/00-zad-hardening.conf` a cada boot; o prefixo `00-` faz o arquivo ser lido antes do `50-cloud-init.conf` do Ubuntu (no `sshd`, vale o primeiro valor encontrado).

## Alternativas consideradas

| Alternativa | Por que foi descartada |
|---|---|
| **OS Login** | Acesso por papel IAM e chave por usuário, com auditoria. Não usa a chave informada ao Terraform (R8) e exigiria conceder papéis no projeto a cada integrante |
| **IAP TCP forwarding** (sem bastion) | Já descartado no ADR-001: remove o bastion, que é exigido pela arquitetura da disciplina |
| **Uma chave por integrante** nos metadados | Melhor rastreio e revogação individual. Fica como evolução: a variável passaria a ser uma lista de chaves |

## Consequências

**Positivas:**
- Acesso 100% reproduzível pelo Terraform; nenhuma chave de projeto ou configuração manual.
- Senha e root desativados verificáveis na demonstração (`ssh -o PubkeyAuthentication=no` → `Permission denied (publickey)`).

**Negativas (aceitas):**
- Chave compartilhada: os logs mostram o usuário `zadadmin`, não o integrante.
- Chave sem senha: quem obtiver o arquivo da chave privada entra. Mitigação recomendada: `ssh-keygen -p -f ~/.ssh/chave-grupo` antes de compartilhar com o colega, e compartilhar só por canal privado.
