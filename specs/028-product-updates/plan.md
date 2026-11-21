# 028 — Plano técnico

## Dados (migração `021_product_updates.sql`)
- `ana_system.program.seed_hash text` — SHA-256 (hex) da semente base.
  Preenchido para instalações existentes a partir da versão de comentário
  `seed` (a primeira gravada pela semente).
- `ana_system.product_update` (uma linha por programa): `name` (PK, FK
  program ON DELETE CASCADE), `seed_source`, `seed_hash`, `base_hash`,
  `locally_modified`, `status` (`available` | `accepted` | `dismissed`),
  `detected_at`, `decided_at`, `decided_by`.

## Núcleo
- `ana_seeds`: além de criar, chama `ana_product_updates:check/0` (tarefa
  interna do robô `system`, P14).
- `ana_product_updates`:
  - `decide(Current, Base, Seed, Offer)` — função pura (testada em eunit):
    `in_sync` | `customized` | `{offer, LocallyModified}` | `keep`.
  - `check/0` lê as sementes, compara com o banco (uma consulta para todos)
    e grava só ofertas novas/alteradas; em dia → apaga oferta pendente.
  - `list/0`, `detail/1` (instalado, produto, base pelo histórico),
    `accept/3` (`overwrite`), `accept_unmodified/1`, `dismiss/2`.
  - Aceitar: `ana_program:save/3` com `base_version` (controle otimista),
    fonte e descrição da semente, comentário "atualização do produto";
    depois `seed_hash` e situação na mesma transação lógica; `admin_log`.
- Rotas: `GET /api/admin/product-updates`, `POST …/check`,
  `GET …/:name`, `POST …/:name/accept` `{overwrite}`, `POST …/:name/dismiss`,
  `POST …/accept-unmodified`.

## Tela
Administração → Sistema → "Atualizações do produto": tabela com ações;
detalhe com comparação lado a lado (diff de linhas em JS, LCS simples,
programas < 5 000 linhas) e botões; contador no menu quando houver ofertas.
