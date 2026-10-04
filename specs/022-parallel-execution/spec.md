# 022 — Execução paralela de programas (dividir e juntar)

Situação: implementada

## Problema
Cálculos pesados (fechamento por cliente, reprocessar milhares de títulos,
simulações, relatórios por filial) ficam lentos em sequência. O núcleo Erlang
roda milhares de processos com facilidade; falta oferecer isso aos programas
com uma API simples, segura e governada.

## Histórias
- **H1** Como desenvolvedor, chamo vários programas em paralelo e recebo os
  resultados juntos, na ordem, com os erros individualizados.
- **H2** Como desenvolvedor, aplico um programa a uma lista de entradas
  (`map`) com grau de paralelismo controlado e junto os resultados (`reduce`
  no meu código).
- **H3** Como desenvolvedor, escolho se cada parte confirma sozinha
  (independente) ou se tudo é confirmado junto ou nada (atômico).
- **H4** Como desenvolvedor, faço leituras paralelas consistentes (mesmo
  instantâneo do banco em todas as partes).
- **H5** Como administrador, limito o paralelismo e vejo cada parte na
  auditoria ligada à execução principal.

## Requisitos funcionais
- **RF-022-01** `ana.parallel([(programa, params), ...], max_workers=N,
  mode="independent"|"atomic", snapshot=False, timeout_ms=None)` → lista de
  resultados na mesma ordem; cada item `{"ok": True, "result": …}` ou
  `{"ok": False, "error": {…}}`; opção `fail_fast=True` cancela as demais na
  primeira falha.
- **RF-022-02** `ana.map(programa, lista_de_params, max_workers=N, …)`
  (atalho) e `ana.gather(...)` para juntar resultados parciais já disparados
  com `ana.spawn(programa, params)` (handle) — permitindo trabalhar enquanto as
  partes rodam.
- **RF-022-03** Modo `independent`: cada parte é uma execução própria (sua
  transação, seu processo Python, seus limites), confirmada ao terminar.
- **RF-022-04** Modo `atomic`: cada parte prepara sua transação (two-phase
  commit, `PREPARE TRANSACTION`); a execução principal confirma todas se ela
  mesma terminar com sucesso e todas as partes também; caso contrário desfaz
  todas. Transações preparadas órfãs são resolvidas na partida do núcleo.
- **RF-022-05** `snapshot=True`: a execução principal exporta o instantâneo
  (`pg_export_snapshot`) e as partes o importam (`SET TRANSACTION SNAPSHOT`) —
  leituras consistentes entre si.
- **RF-022-06** Governança (spec 012): `max_workers` limitado por novo limite
  `max_parallel_parts` (programa/papel/grupo/teto); as partes contam nas cotas
  de concorrência; tempo das partes limitado pelo tempo restante da principal.
- **RF-022-07** Auditoria: cada parte registra `parent_execution_id`; a
  execução principal mostra a árvore de partes, tempos e consumo somado.
- **RF-022-08** Depuração: em execução depurada, as partes rodam em sequência
  (determinístico), com aviso.

## Requisitos não funcionais
- **RNF-022-01** (performance) 100 partes triviais com `max_workers=16`
  concluem em < 2 s com o pool pré-aquecido; sobrecarga por parte < 15 ms.
- **RNF-022-02** (robustez) Falha ou estouro de uma parte nunca derruba a
  principal; cancelamento da principal cancela as partes (e seus SQL).
- **RNF-022-03** (segurança) Partes executam com o mesmo usuário e permissões
  da principal; não elevam privilégio.

## Critérios de aceite
- **CA-022-01** `ana.map` de 50 partes que dormem 200 ms com 10 workers leva
  ~1 s, não 10 s; resultados na ordem de entrada.
- **CA-022-02** Uma parte com erro aparece como `ok: False` e as demais
  concluem; com `fail_fast`, as restantes são canceladas.
- **CA-022-03** Modo atômico: uma parte falha → nenhuma gravação de nenhuma
  parte permanece; todas ok e principal ok → todas gravadas.
- **CA-022-04** `snapshot=True`: gravação feita por outra sessão durante o
  processamento não aparece em nenhuma parte.
- **CA-022-05** `max_workers` acima do limite é reduzido ao limite efetivo.
- **CA-022-06** Auditoria mostra a árvore principal → partes.
