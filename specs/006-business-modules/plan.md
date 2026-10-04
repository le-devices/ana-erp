# 006 — Plano técnico: Módulos de Negócio

- Migração `002_business.sql`: esquemas, tabelas, índices, gatilho de
  balanceamento (`CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`),
  sequências, grants a `ana_exec` e `ana_read`.
- Migração `003_chart_of_accounts.sql`: plano de contas base do produto.
- `priv/demo/001_commerce.sql`: dados de demonstração (só com `ANA_DEMO=true`).
- Sementes de programas: `priv/programs/<name>.py` com cabeçalho de metadados
  em comentários:
  ```python
  # ana:description Cria pedido de venda
  # ana:exposed yes
  # ana:command order
  # ana:kind program
  # ana:role user
  ```
  `ana_seeds` lê, cria programa (versão 1, autor `system`) e comando se
  não existirem (RF-006-08).
- Baixa de estoque em `sales.invoice_order`: para cada item de `goods`,
  ordenado por produto (evita deadlock), `SELECT ... FROM base.product WHERE
  id=$1 FOR UPDATE`, calcula saldo, insere movimento negativo.
