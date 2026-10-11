# 036 — Plano técnico

## Arquivos (`deploy/`)
- `install.sh`: pré-requisitos (Linux, Docker 24+, compose v2, memória,
  disco, portas), endereço e certificado (automático por domínio + e-mail,
  interno por IP ou certificado da empresa), segredos gerados (senhas do
  banco e dos papéis restritos, chave mestra, cookie, senha inicial do
  admin), imagem construída do pacote (ou `--image`), arquivos e `.env`
  (600) no diretório da instalação, subida, HTTPS conferido, primeira cópia e
  agendamento (cron).
- `docker-compose.prod.yml`: banco (perfil `localdb`, arquivamento de WAL
  ligado desde o início, volume de cópias preparado), `ana1` e `ana2`
  (perfil `ha`), proxy Caddy com HTTPS e balanceamento só para nós prontos;
  contêineres somente leitura, sem privilégios, limites de memória.
- `Caddyfile`: HTTPS, HSTS, cabeçalhos, `default_sni` para acesso por IP,
  verificação `/health/ready`, novas tentativas.
- `ana-ctl`: status, doctor, backup (com limpeza por idade e do WAL antigo),
  restore-test, upgrade (cópia → imagem nova → nó a nó com espera de
  prontidão → volta atrás se falhar), rollback, logs, install-cron,
  uninstall (mantém dados; `--purge` apaga com confirmação), up.
- `k8s/`: kustomize (namespace, configuração, segredo, volume RWX dos
  arquivos, Deployment com 2 réplicas e atualização sem indisponibilidade,
  serviço, PDB, ingress com cert-manager).
- `initdb.sql` e `initdb-managed.sql`; `INSTALL.md` (guia em português).

## Núcleo
- Admin inicial criado quando não há nenhuma pessoa (o robô `system` já
  existe numa base nova — antes o admin nunca era criado numa instalação
  limpa); em produção, troca de senha obrigatória no primeiro acesso;
  criação tolerante a dois nós subindo juntos.

## Testes
- `make teste-instalacao`: instala uma pilha isolada (projeto, portas e
  diretório próprios) com dois nós e HTTPS interno, confere CA-036-01..03,
  diagnóstico e teste de restauração, valida os manifestos Kubernetes e
  remove tudo o que criou.
- `make pacote`: pacote `.tar.gz` do commit atual.
