# 009 — Plano (fase 1)

## Dados (migração 041)
- `ana_system.license`: id, text (o texto assinado), payload (jsonb), kid,
  installed_by, installed_at, source (`screen` | `file`), active (uma só
  ativa).
- `ana_system.license_state` (linha única): first_boot (início da
  avaliação), last_seen (maior data vista).
- Nada em esquemas de negócio: a licença é do núcleo.

## Núcleo
- `ana_license` (gen_server, em todos os nós):
  - `verify(Text)` pura: formato, `kid` em `priv/license/keys.json`,
    Ed25519, campos obrigatórios; chave de teste força `non_production`.
  - `status/1` pura: dada a licença (ou nenhuma), o primeiro boot, a maior
    data vista, hoje e a versão do produto → `#{state, reason, days_left,
    modules, limits, environment}`.
  - estado em `persistent_term` (`allowed_module/1`, `restricted/0`);
    recalcula na partida, de hora em hora, ao instalar e por NOTIFY
    `ana_license` (outros nós do cluster).
  - `boot_check/0` em `ana_app` antes de `ana_migrate:run/0`: lê a licença
    ativa (se a tabela existir) ou `ANA_LICENSE_FILE`; versão não coberta →
    `exit` com mensagem.
  - `install(Text, Source, User)`: verifica, recusa versão não coberta,
    grava, audita (`ana_admin:log`), notifica.
- `ana_execution:load/2`: módulo do programa (prefixo → módulo, mapa no
  `ana_license`) fora da licença → `NOT_LICENSED`.
- `ana_execution:prepare_run/3`: modo restrito → `SET TRANSACTION READ ONLY`;
  erro 25006 → `LICENSE_RESTRICTED`.
- `ana_api` (clientes da API pública) e login de conta externa (portal):
  módulo não contratado → recusa.
- `ana_admin`: criar/reativar usuário humano interno conta os nomeados.
- `ana_program`: salvar programa novo em namespace reservado →
  `PRODUCT_NAMESPACE` (sementes e atualizações do produto passam por outro
  caminho); listagem informa `customized`.
- HTTP: `GET /api/license` (estado resumido para a faixa, qualquer usuário),
  `GET/POST /api/admin/license` (detalhe, uso, histórico, instalar).

## Telas
- Faixa no topo (`studio.js`) conforme o estado.
- Administração → Licença (`admin.js`): estado, validade, módulos (contratado
  ou não), usuários nomeados (uso/limite), ambiente, histórico, colar texto.
- Estúdio: selo "customizado — fora do suporte padrão".

## BPM
- `bpm.common.validate`: programa de módulo não contratado → aviso.

## Ferramenta
- `scripts/license.py keygen | issue | verify` (biblioteca `cryptography`).

## Testes
- eunit: `ana_license` verify/status (datas, carência, relógio, versão,
  chave de teste).
- integração: CA-009-01..08, deixando ao final uma licença de testes válida
  (para a instância de dev nunca cair em modo restrito).
