# Segurança (Parte B)

Controles S1 a S8 aplicados à infraestrutura implantada por `infra/`, tratamento dos achados das ferramentas de análise e análise de ameaças específicas do ZadInventory.

> Evidências em `docs/evidencias/`. Os nomes de arquivo citados abaixo são os prints e relatórios gerados nas sessões de teste.

## 1. Controles obrigatórios

| # | Controle | Como foi implementado | Onde está no código | Como verificar (evidência) |
|---|---|---|---|---|
| **S1** | SSH só com chave; senha e root desativados | Chave pública do grupo nos metadados de cada VM; chaves de projeto bloqueadas; OS Login desligado ([ADR-006](adr/006-chave-ssh-por-metadados.md)). A cada boot, o startup-script grava `/etc/ssh/sshd_config.d/00-zad-hardening.conf` com `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`, valida com `sshd -t` e recarrega o serviço | `infra/compute.tf` (metadados `ssh-keys`, `block-project-ssh-keys`, `enable-oslogin`), `infra/scripts/common.sh` (`harden_ssh`) | `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password zadadmin@<bastion>` → `Permission denied (publickey)`; `sudo sshd -T \| grep -E "passwordauth\|permitroot"` |
| **S2** | Saída restrita | Regra `zad-deny-egress-all` (prioridade 65000) nega toda saída. Acima dela: `zad-allow-egress-web` (80/443 para a internet: apt, repo.mysql.com, APIs do Google, Let's Encrypt, DuckDNS), `zad-allow-egress-api` (frontend → `10.10.2.10:8080`), `zad-allow-egress-mysql` (backend → `10.10.2.20:3306`), `zad-allow-egress-ssh-interno` (bastion → sub-redes, 22) e `zad-allow-egress-metadata` (DNS/NTP/metadados em `169.254.169.254`) | `infra/security.tf` | Na vm-backend: `curl -s https://ifconfig.me` responde (= `nat_public_ip`); `curl -m 5 telnet://1.1.1.1:22` expira; no frontend: `nc -zv 10.10.2.20 3306` é bloqueado |
| **S3** | Tráfego cifrado | Nginx só serve a aplicação em 443 (TLS 1.2/1.3, HSTS, `X-Frame-Options`, `nosniff`); a porta 80 só atende o desafio do Let's Encrypt e devolve **301** para `https://`. Certificado Let's Encrypt para `megainventory.duckdns.org` (`tls_mode = "letsencrypt"`). Entre backend e banco: MySQL com `require_secure_transport = ON`, usuário `REQUIRE SSL` e JDBC com `sslMode=REQUIRED` | `infra/scripts/frontend.sh`, `infra/scripts/db.sh`, `application-vm.properties` | `curl -I http://megainventory.duckdns.org` → `301 Location: https://...`; cadeado no navegador; na vm-db: `SHOW STATUS LIKE 'Ssl_cipher'` numa conexão do backend |
| **S4** | Segredos fora do código | Senha do banco (`random_password`, 32 caracteres) e segredo JWT (`random_bytes`, 48 bytes em Base64) gerados pelo Terraform e guardados no **Secret Manager**, com réplica só em `southamerica-east1`. Token do DuckDNS via `TF_VAR_duckdns_token` (variável `sensitive`). As VMs leem os segredos no boot e gravam `/etc/zadinventory/zadinventory.env` com permissão `600`. `.gitignore` cobre `*.tfstate`, `*.tfvars`, `tfplan`, chaves e `.env` | `infra/secrets.tf`, `infra/variables.tf`, `infra/scripts/backend.sh`, `.gitignore` | Relatório do Gitleaks no histórico completo; `git ls-files \| grep -E "tfstate\|tfvars$"` vazio |
| **S5** | Menor privilégio nas identidades | Uma service account por VM, **sem nenhum papel no projeto**. Permissões no próprio recurso: `zad-backend` lê só `zad-db-password` e `zad-jwt-secret`; `zad-db` lê só `zad-db-password` e tem só `roles/storage.objectCreator` no bucket de backup; `zad-frontend` lê só `zad-duckdns-token`; `zad-bastion` não tem permissão nenhuma. Nenhuma chave de service account é criada (tokens de curta duração pelo servidor de metadados) | `infra/iam.tf` | Na vm-db: `gsutil ls gs://<bucket>` ou `curl` de listagem → **403**; no frontend: ler `zad-db-password` → **403** |
| **S6** | Criptografia em repouso declarada | CMEK no Cloud KMS: chave `zad-disco` em todos os discos de boot (`kms_key_self_link`) e chave `zad-backup` como chave padrão do bucket (`encryption.default_kms_key_name`), rotação a cada 90 dias. O keyring leva sufixo aleatório porque a GCP não permite apagar keyrings | `infra/kms.tf`, `infra/compute.tf`, `infra/backup.tf` | `gcloud compute disks describe vm-db --zone southamerica-east1-a --format="value(diskEncryptionKey.kmsKeyName)"`; `gcloud storage buckets describe gs://<bucket> --format="value(default_kms_key)"`; `gcloud storage objects describe gs://<bucket>/diario/... --format="value(kms_key)"` |
| **S7** | Análise automatizada | Workflow `.github/workflows/seguranca-iac.yml` em todo push: `terraform fmt -check` e `validate`, **Trivy** (`config`) e **Checkov** em `infra/`, **Gitleaks** no histórico completo (`fetch-depth: 0`). Relatórios publicados como artefatos e copiados para `docs/evidencias/` | `.github/workflows/seguranca-iac.yml` | `docs/evidencias/checkov-iac.txt`, `trivy-iac.txt`, `gitleaks.json` |
| **S8** | MFA na conta | Verificação em duas etapas ativa na conta Google dona do projeto e da conta de faturamento (`lipe31102005@gmail.com`) desde 09/11/2021. A GCP não tem "usuário root": o equivalente é a conta proprietária do projeto | Console Google Conta → Segurança | Print `docs/evidencias/s8-mfa.png` (sem dados pessoais além do status) |

**Controles adicionais aplicados** (não exigidos, apontados pelas ferramentas):
- Shielded VM (Secure Boot, vTPM e monitoramento de integridade) e console serial desligado em todas as VMs.
- VPC Flow Logs nas duas sub-redes e log das regras `zad-allow-ssh-admin` e `zad-deny-egress-all`.
- Bucket com prevenção de acesso público e acesso uniforme; MySQL escutando só no IP interno e usuário da aplicação restrito ao IP do backend.
- Rede `default` do projeto removida (tinha `default-allow-ssh` e `default-allow-rdp` abertas para `0.0.0.0/0`).
- O serviço `zadinventory` roda como usuário sem shell, com `NoNewPrivileges`, `ProtectSystem=strict` e `ProtectHome`.

## 2. Tratamento dos achados

### 2.1 Checkov (`docs/evidencias/checkov-iac.txt`)

Primeira execução: 117 verificações aprovadas e 13 falhas. Depois das correções: **123 aprovadas e 7 falhas, todas aceitas com justificativa**. O Checkov gratuito não informa severidade; a coluna usa a severidade da regra equivalente do Trivy.

| Achado | Severidade | Recurso | Decisão | Justificativa |
|---|---|---|---|---|
| CKV_GCP_32 – chaves SSH do projeto não bloqueadas | Média | 4 instâncias | **Corrigido** | Metadados `block-project-ssh-keys = true` escritos explicitamente em cada VM (antes vinham de um `merge` que a ferramenta não avaliava) |
| CKV_GCP_74 – Private Google Access desligado | Baixa | `zad-publica` | **Corrigido** | Ligado nas duas sub-redes |
| CKV_GCP_26 – sem VPC Flow Logs | Baixa | `zad-publica`, `zad-privada` | **Corrigido** | Flow Logs com amostragem de 50% e agregação de 10 min, dentro da cota gratuita do Logging |
| CKV_GCP_40 – instância com IP público | Alta | `vm-bastion` | **Aceito** | É o recurso de acesso exigido (R6/ADR-001); o SSH só aceita os IPs /32 dos integrantes (R7) e só com chave (S1) |
| CKV_GCP_40 – instância com IP público | Alta | `vm-frontend` | **Aceito** | É a porta de entrada da aplicação; só 80/443 abertas. Na proposta de HA ([ADR-004](adr/004-alta-disponibilidade.md)) o IP público passa para o load balancer e as VMs perdem o IP externo |
| CKV_GCP_106 – porta 80 aberta para `0.0.0.0/0` | Alta | `zad-allow-web` | **Aceito** | A porta 80 só responde ao desafio HTTP-01 do Let's Encrypt e com 301 para HTTPS; nenhuma página da aplicação é servida em HTTP |
| CKV_GCP_82 – chave KMS sem proteção contra destruição | Baixa | `zad-disco`, `zad-backup` | **Aceito** | O enunciado exige destruir o ambiente ao fim de cada sessão; `prevent_destroy` bloquearia o `terraform destroy`. As versões ficam 24 h agendadas para destruição antes de sumir |
| CKV_GCP_78 – bucket sem versionamento | Média | `google_storage_bucket.backup` | **Aceito** | Versionamento guardaria cópias além da retenção de 2 dias da política mínima. A proteção contra sobrescrita vem da permissão: a VM só tem `objectCreator`, que não sobrescreve nem apaga |
| CKV_GCP_62 – bucket sem log de acesso | Média | `google_storage_bucket.backup` | **Aceito** | Volume e custo de log incompatíveis com o escopo; o acesso de escrita é de uma única service account, e o risco residual está na ameaça A5 |

### 2.2 Trivy (`docs/evidencias/trivy-iac.txt`)

Execução do workflow `seguranca-iac` em 21/11/2026 (`trivy config infra/`): **7 achados, nenhum crítico, 2 altos e 5 médios**, todos com decisão abaixo.

| Achado | Severidade | Recurso (arquivo) | Decisão | Justificativa |
|---|---|---|---|---|
| GCP-0031: instância com IP público | **Alta** | `google_compute_instance.bastion` (`compute.tf`) | **Aceito** | É o recurso de acesso administrativo exigido (R6, [ADR-001](adr/001-acesso-administrativo.md)). O SSH só aceita os IPs /32 dos integrantes (R7), só com chave (S1), e nenhuma outra porta está aberta |
| GCP-0031: instância com IP público | **Alta** | `google_compute_instance.frontend` (`compute.tf`) | **Aceito** | É a porta de entrada da aplicação; só 80 (redireciona para HTTPS) e 443 estão abertas. Na proposta de HA ([ADR-004](adr/004-alta-disponibilidade.md)) o IP público passa para o load balancer e as VMs de frontend perdem o IP externo, eliminando o achado |
| GCP-0036: OS Login desativado | Média | bastion, frontend, backend, db (`compute.tf`) | **Aceito** | Decisão do [ADR-006](adr/006-chave-ssh-por-metadados.md): o requisito R8 exige a chave pública informada ao Terraform, o que o OS Login não usa. Compensado por `block-project-ssh-keys`, senha e root desativados (S1) e SSH restrito por IP |
| GCP-0078: bucket sem versionamento | Média | `google_storage_bucket.backup` (`backup.tf`) | **Aceito** | O versionamento guardaria versões além da retenção de 2 dias da política mínima. A proteção contra sobrescrita e exclusão vem da permissão: a SA da vm-db só tem `objectCreator` (S5) |

### 2.3 Gitleaks (`docs/evidencias/gitleaks.json`)

Execução no **histórico completo** do repositório (`fetch-depth: 0`) em 21/11/2026: **3 achados, todos a regra `generic-api-key` sobre a mesma chave fictícia de teste**. Nenhum segredo real.

| Achado | Severidade | Arquivo e commit | Decisão | Justificativa |
|---|---|---|---|---|
| `generic-api-key` em `jwt.secret` | Baixa | `zadinventory-backend/zadinventory/src/test/resources/application-test.properties`, linha 27 (versão atual) | **Aceito (falso positivo)** | Valor fixo usado só nos testes automatizados com banco H2 em memória. Não é usado em nenhum ambiente; o segredo JWT de produção é gerado pelo Terraform (`random_bytes`) e fica no Secret Manager |
| `generic-api-key` em `jwt.secret` (2 ocorrências) | Baixa | `backend/src/test/resources/application-test.properties`, linha 34, commit `7db5355a` (03/08/2026, antes da reorganização das pastas) | **Aceito (falso positivo)** | O mesmo valor de teste, marcado no próprio arquivo como "valores dummy apenas para os testes". Permanece no histórico, mas não protege nada |

Os três achados estão registrados em `.gitleaksignore` (por *fingerprint*: commit, arquivo, regra e linha), para que o job do Gitleaks no workflow passe com eles e **continue falhando se aparecer qualquer segredo novo** em qualquer arquivo ou commit.

**Segredos reais verificados:** token do DuckDNS, chave SSH do grupo, `terraform.tfvars`, `terraform.tfstate` e `tfplan` **nunca** foram commitados (confirmado pelo Gitleaks e por `git log --all -- '*.tfstate' '*.tfvars' 'tfplan'`). O token do DuckDNS apareceu numa captura de tela local durante a configuração (18/11), que não foi versionada e já foi apagada. O grupo decidiu **não** regenerar o token (risco aceito na ameaça A3).

## 3. Análise de ameaças

| # | Ameaça | Ativo afetado | Controle aplicado | Risco residual |
|---|---|---|---|---|
| **A1** | **Sequestro do endpoint de criação do primeiro gerente.** `POST /api/usuarios/criar-inicial` é público e só funciona enquanto o banco não tem usuários. A cada `terraform apply` o banco nasce vazio e o site fica no ar antes do grupo criar o gerente; quem chamar o endpoint primeiro vira GERENTE e controla usuários, produtos e vendas | Contas de usuário, dados do estoque | S3 (o pedido trafega cifrado); o endpoint se fecha sozinho depois do primeiro usuário | Janela de alguns minutos após cada `deploy.sh`. Mitigação operacional: criar o gerente imediatamente após o deploy e conferir que a resposta não foi "Usuário inicial já foi criado!". Correção definitiva: o gerente inicial ser criado pelo próprio script, com senha vinda do Secret Manager |
| **A2** | **Comprometimento da `vm-frontend` pela internet** (falha no Nginx ou no sistema) e uso dela como ponto de apoio | vm-frontend, API, sessões dos usuários | Só 80/443 expostas; S2 limita o que a VM alcança (só `10.10.2.10:8080` na rede interna e 80/443 fora); S5: a service account só lê o token do DuckDNS; Shielded VM; sem SSH a partir da internet | O invasor vê o tráfego HTTP interno entre Nginx e backend (que inclui o JWT dos usuários logados) e pode enviar dados para qualquer destino em 80/443. Pode também alterar o DNS com o token do DuckDNS (A3) |
| **A3** | **Vazamento do token do DuckDNS** e redirecionamento de `megainventory.duckdns.org` para um servidor do atacante, que emite certificado próprio pelo Let's Encrypt e captura logins | Domínio, credenciais dos usuários | S4: token só no Secret Manager e em variável de ambiente, nunca no Git; S5: só a SA do frontend o lê; Gitleaks no histórico | O DuckDNS não tem MFA nem escopo por domínio. O token foi exibido numa captura de tela local em 18/11 (nunca versionada, já apagada) e o grupo **aceitou não regenerá-lo**: o domínio é de teste, o pior caso é o redirecionamento do DNS até o próximo `apply` (que reaponta o domínio), e a regeneração leva um minuto se houver qualquer suspeita de uso indevido. HSTS de 1 dia não protege o primeiro acesso |
| **A4** | **Roubo da chave SSH do grupo** (sem senha) do notebook de um integrante | Bastion e, por ProxyJump, todas as VMs | R7: SSH só a partir dos IPs /32 cadastrados; S1; nada exposto além do bastion | Quem tem a chave **e** está numa rede cujo IP está liberado entra como `zadadmin` com sudo. Chave compartilhada impede saber quem entrou ([ADR-006](adr/006-chave-ssh-por-metadados.md)). Mitigação: senha na chave e chave por integrante |
| **A5** | **Invasor com root na `vm-db` tenta destruir os dados e os backups** (ransomware) | Banco e cópias de backup | S5: a SA `zad-db` só tem `objectCreator`, sem permissão de apagar, sobrescrever ou listar; CMEK; bucket sem acesso público | O invasor apaga o banco local e pode enviar dumps falsos ou corrompidos ao bucket; como a política mínima retém só 1 dia, uma corrupção percebida depois disso não tem cópia boa. Na política GFS a retenção de 7/35/365 dias cobre esse caso |
| **A6** | **Exposição dos segredos pelo `terraform.tfstate` local**, que guarda em texto claro a senha do banco, o segredo JWT e o token do DuckDNS | Banco, autenticação da API, domínio | `.gitignore` (`*.tfstate`, `*.tfvars`, `tfplan`), Gitleaks no histórico; o ambiente é destruído ao fim das sessões e um novo `apply` gera senha e JWT novos | Perda ou roubo do notebook enquanto o ambiente está no ar. Evolução: *remote state* em bucket com CMEK e acesso restrito, ou atributos *write-only* (`secret_data_wo`) |
| **A7** | **Força bruta / credential stuffing no login da API** (`POST /api/auth/login`) | Contas de usuário | Senhas com BCrypt; HTTPS; o backend não é exposto diretamente (só via Nginx) | Não há limite de tentativas nem bloqueio de conta. Evolução: `limit_req` no Nginx para `/api/auth/login` e bloqueio após N falhas |

## 4. Riscos residuais conhecidos

- **MySQL 8.0 fora de suporte** só se a VM voltar a cair na contingência do `db.sh` (errata E10; no teste de 21/11 subiu o 8.4.13 oficial).
- Tráfego Nginx → backend em HTTP na rede interna. A GCP cifra o tráfego entre VMs da mesma VPC na camada de rede, mas o conteúdo fica visível para quem controlar a `vm-frontend` (A2).
- Firewall por tag de rede (risco 8 da Entrega 1): quem pode editar uma VM pode trocar a tag. Só a conta dona tem papel de edição no projeto.
