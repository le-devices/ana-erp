# 022 — Plano técnico

## Visão geral
Cada parte é uma **execução filha** comum (`ana_execution:run/4`): seu
processo Erlang, seu processo Python pré-aquecido, sua conexão, sua
transação, seus limites e sua auditoria, com o mesmo usuário da principal
(RNF-022-03, P14). A execução principal coordena as filhas sem bloquear: um
processo trabalhador por parte faz a chamada síncrona e devolve o resultado à
principal por mensagem.

## Protocolo (runtime ↔ núcleo)
- `spawn {program, params, group, max_workers, mode, snapshot, timeout_ms}` →
  devolve um número de parte na hora; a parte começa quando houver vaga no
  grupo (`max_workers` por chamada de `parallel`/`map`; `spawn` avulso é um
  grupo de uma parte).
- `gather {handles, fail_fast, timeout_ms}` → responde quando todas as partes
  pedidas terminarem (ou na primeira falha com `fail_fast`, cancelando as
  demais), com `[{ok, result} | {ok: false, error}]` na ordem pedida.
- `cancel {handles}`.
- Python: `ana.spawn` (devolve `Part`), `ana.gather(*parts)`,
  `ana.parallel([(programa, params), …], …)` e `ana.map(programa, lista, …)`
  são construídos sobre essas três operações.

## Núcleo
- Estado da principal: `parts` (número → situação, id da filha, resultado,
  modo, gid), `groups` (vagas e fila), `gather` em espera.
- Cancelamento: a filha recebe a opção `parent_pid`, monitora a principal e
  se encerra (desfazendo) se ela terminar; `fail_fast`/`cancel` param a
  filha pelo id (o id é escolhido pela principal e passado na opção `id`).
  Partes não aguardadas quando a principal termina são canceladas.
- Tempo: o prazo da filha é o menor entre o pedido e o tempo restante da
  principal (RF-022-06). Em depuração, `max_workers = 1` e um aviso
  (RF-022-08).
- Governança: novo limite `max_parallel_parts` (padrão 8, teto 64) na spec
  012; `max_workers` acima dele é reduzido. As filhas passam pela admissão
  global e pelas cotas por programa/usuário como qualquer execução.
- Auditoria: coluna `execution.parent_execution_id` (migração 015) e índice;
  o detalhe da execução na auditoria mostra as partes e o consumo somado.

## Modo atômico (two-phase commit)
- A filha recebe `prepare => Gid` e, no sucesso, faz `PREPARE TRANSACTION`
  em vez de `COMMIT` (a conexão volta ao pool; a transação fica preparada).
- Gid: `ana_<nó>_<execução principal>_<parte>` (nó = hash do nome do nó).
- Fim da principal com sucesso e todas as partes atômicas com sucesso:
  1. `PREPARE TRANSACTION` da própria principal;
  2. grava a decisão em `ana_system.parallel_decision` (gids, `commit`);
  3. `COMMIT PREPARED` de todas (principal e partes);
  4. apaga a decisão.
- Qualquer parte atômica com falha ⇒ a principal termina com erro
  `PARALLEL_ATOMIC_FAILED` (tudo ou nada, inclusive as gravações da
  principal); erro, parada ou prazo da principal ⇒ `ROLLBACK PREPARED` das
  partes preparadas.
- Tudo com conexões `ana_exec` (só o mesmo usuário pode confirmar ou
  desfazer uma transação preparada sem ser superusuário).
- Recuperação (`ana_parallel:recover/1`): na partida do nó, transações
  preparadas `ana_*` do próprio nó são resolvidas pela decisão gravada
  (`commit`) ou desfeitas; periodicamente, as de qualquer nó com mais de 2×
  o teto de tempo de execução também.

## Instantâneo compartilhado
A principal executa `pg_export_snapshot()` (uma vez por execução) e passa o
id às filhas; cada filha abre `BEGIN ISOLATION LEVEL REPEATABLE READ; SET
TRANSACTION SNAPSHOT '…'`. A principal mantém a transação aberta enquanto as
partes rodam (ela está esperando no `gather`).

## Desempenho
Sobrecarga por parte: um processo Erlang, um processo Python do pool
pré-aquecido e uma conexão do pool de programas. `max_workers` também fica
limitado ao tamanho desse pool menos 2, para a principal e as partes nunca
se bloquearem esperando conexão.
