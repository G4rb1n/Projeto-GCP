# Declaração de uso de Inteligência Artificial

Este documento declara o uso de ferramentas de IA na Entrega 1 do Projeto
Integrador (Grupo 6 — ZadInventory na Google Cloud), conforme exigido pelo
enunciado. O uso de IA foi de **apoio**: todo o conteúdo foi revisado, ajustado e
verificado pelos integrantes antes de ir para o repositório.

## Ferramentas utilizadas

| Integrante | Ferramenta | Onde foi usada | O que a IA produziu |
|---|---|---|---|
| Lipe | Claude (chat) | Documentação da arquitetura | Rascunhos do `arquitetura.md`, dos READMEs, do material de custos, a primeira versão dos 3 ADRs e do diagrama `.drawio`, e revisão final dos ADRs e do diagrama |
| Lipe | Claude Code | Repositório | Apoio na organização da estrutura de pastas e dos arquivos do projeto |
| Eduardo | Claude (chat) | ADRs, diagrama e esta declaração | Reescrita e revisão dos 3 ADRs (`docs/adr/`), apoio na edição do diagrama, rascunho do `IA.md` e preparação para a defesa técnica |

## O que foi verificado e corrigido pelo grupo

- **Valores de custo conferidos na calculadora oficial.** Os números dos cenários
  A e B foram validados na Google Cloud Pricing Calculator, e não apenas aceitos
  do rascunho gerado pela IA.
- **Preço dos IPs externos corrigido.** O rascunho trazia US$ 0,005/h; ao conferir
  na calculadora, o grupo ajustou para **US$ 0,0025/h**, valor usado na estimativa
  final.
- **Decisões dos ADRs revisadas.** Cada decisão, alternativa descartada e
  consequência aceita foi lida e validada pelos integrantes, para que ambos
  consigam defendê-las oralmente (o professor sorteia quem responde).
- **Justificativas dos ADRs corrigidas.** Na revisão, removemos justificativas
  inadequadas que a IA havia sugerido (como "sem ganho para a nota") e corrigimos
  detalhes inconsistentes com a arquitetura, por exemplo a referência à seção do
  RPO/RTO e a instalação de dependências do Spring Boot nas VMs, que não acontece
  porque o JAR é gerado fora delas.
- **Links indevidos removidos do diagrama.** O arquivo `.drawio` continha links
  externos sem relação com o projeto embutidos nos textos; eles foram removidos
  antes do commit.
- **Consistência entre documentos.** CIDRs, nomes e tipos das VMs, tags de
  firewall e os fluxos citados nos ADRs foram conferidos contra o `arquitetura.md`.

## Declaração

As ferramentas de IA foram usadas como apoio à redação e à organização do
material. As decisões técnicas de arquitetura, os valores de custo e as
justificativas são de responsabilidade do grupo, que revisou e validou todo o
conteúdo entregue.

## Entrega 2

| Integrante | Ferramenta | Onde foi usada | O que a IA produziu |
|---|---|---|---|
| Lipe | Claude (chat) | Planejamento, infraestrutura e documentação | Plano de trabalho da entrega; primeira versão do Terraform (`infra/*.tf`), dos startup-scripts, do `deploy.sh`, do workflow `seguranca-iac.yml` e do perfil Spring `vm`; rascunhos de `seguranca.md`, `errata.md`, `backup.md`, `alta-disponibilidade.md`, ADRs 004 a 006, planilhas de custo e diagrama de HA; apoio na configuração da conta de faturamento, do alerta de orçamento e do DuckDNS |
| Lipe | Claude Code (VS Code) | Execução e depuração | Aplicou o código no repositório, rodou `terraform init/plan/apply/destroy` com aprovação do integrante a cada passo, corrigiu problemas encontrados na implantação (finais de linha CRLF, ProxyJump no `deploy.sh`, chave GPG expirada do MySQL, `mvnw` sem wrapper) e gerou as evidências |

### O que foi verificado e corrigido pelo grupo (Entrega 2)

- **Plano revisado antes de cada `apply`.** O resumo do `terraform plan` (53 recursos) foi conferido pelo integrante, incluindo a regra de SSH só com o IP /32 e as VMs privadas sem IP externo.
- **Funcionamento testado na nuvem real**, não só no papel: aplicação acessada por HTTPS, SSH via bastion, saída pelo NAT, backup gravado no bucket e ambiente destruído ao final (18/11).
- **Problemas que a IA não previu** e que só apareceram na implantação foram corrigidos e registrados na errata (E10, E20).
- **Rede `default` removida** por decisão do grupo, após revisão do console.
- _Completar: valores de custo conferidos na calculadora oficial (HA e GFS), relatórios do Trivy e do Gitleaks revisados, e o que cada integrante revisou para conseguir defender na apresentação._

