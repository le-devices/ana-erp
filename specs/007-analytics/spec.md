# 007 — Camada Analítica

## Problema
Relatórios e painéis agregam muitos dados. Consultá-los direto nas tabelas
transacionais concorre com a operação. Queremos analítico e transacional no
mesmo PostgreSQL (sem um segundo banco), com o analítico isolado do impacto.

## Requisitos funcionais
- **RF-007-01** Esquema `analytics` com visões materializadas:
  `daily_sales` (dia, produto, quantidade, valor), `sales_by_customer`
  (mês, parceiro, valor, pedidos), `stock_balance` (produto, depósito, saldo).
- **RF-007-02** Função `analytics.refresh()` atualiza todas as visões com
  `REFRESH MATERIALIZED VIEW CONCURRENTLY`.
- **RF-007-03** O núcleo chama `analytics.refresh()` a cada
  `ANA_ANALYTICS_INTERVAL_S` (padrão 300 s) e sob demanda via
  `POST /api/analytics/refresh` (desenvolvedor+).
- **RF-007-04** Se a extensão colunar `citus` estiver disponível no servidor,
  a migração cria `analytics.sales_fact` com `USING columnar`; senão cria
  tabela comum. `atualizar()` recarrega a tabela fato.
- **RF-007-06** A implantação padrão usa PostgreSQL com a extensão colunar
  (Citus) já habilitada pelo superusuário na criação do banco; a tabela fato é
  sempre colunar nesse caso. Sem a extensão, o ANA continua funcionando com
  tabela comum e informa `columnar: false` na saúde.
- **RF-007-05** `GET /health` informa `analytics: {columnar: bool,
  last_refresh}`.

## Requisitos não funcionais
- **RNF-007-01** (performance) Cada visão materializada tem índice único
  (requisito do refresh concorrente) — leituras nunca bloqueiam durante a
  atualização.
- **RNF-007-02** (robustez) Atualizações não se sobrepõem
  (`pg_try_advisory_lock`); falha é registrada e tentada no próximo ciclo.
- **RNF-007-03** (segurança) `ana_exec` e `ana_read` só têm SELECT no
  esquema `analytics`.

- **RNF-007-04** (performance, em memória) O banco é configurado para
  trabalhar o máximo possível em memória: `shared_buffers`,
  `effective_cache_size`, `work_mem` dimensionados pela memória disponível;
  `pg_prewarm` com aquecimento automático mantém as páginas quentes entre
  reinícios; JIT habilitado para consultas analíticas. No núcleo, catálogos,
  programas, parâmetros, sessões e statements preparados ficam em cache ETS
  (memória), e dados efêmeros (sessões) usam tabelas UNLOGGED.

## Critérios de aceite
- **CA-007-01** Após faturar um pedido e chamar atualizar, `daily_sales`
  reflete a venda.
- **CA-007-02** Duas chamadas simultâneas de atualizar: uma executa, a outra
  retorna `already_running` sem erro.
- **CA-007-03** No ambiente padrão, `GET /health` mostra `analytics.columnar =
  true` e `analytics.sales_fact` usa o método de acesso `columnar`.
- **CA-007-04** `pg_prewarm` está ativo (`autoprewarm`) e `shared_buffers`
  reflete a configuração do ambiente.
