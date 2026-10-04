# 004 — Plano técnico: Depurador

## Runtime (Python)
`AnaDebugger(bdb.Bdb)` em `ana_runtime.py`:
- O fonte é compilado com nome de arquivo `<ana:NAME>`; pontos de parada são
  registrados nesse "arquivo" (e a fonte, no `linecache`).
- `user_line(frame)`: se o arquivo do quadro não é o do programa, retorna sem
  parar (RF-004-07). Caso contrário emite `pause` e entra em `wait_command()` —
  leitura bloqueante do stdin do protocolo.
- `eval` usa `eval(expr, frame.f_globals, frame.f_locals)`; se falhar com
  `SyntaxError`, tenta `exec` (permite atribuições simples).
- `stop` → `set_quit()` → `bdb.BdbQuit` → `end` com `code = ABORTED`.
- Sem pontos de parada nem passo pendente, quadros não são rastreados
  (`dispatch_call` devolve `None`) — RNF-004-05.

## Núcleo (Erlang)
- `ana_execution` guarda: `owner` (usuário), buffer de eventos numerados
  (máx. 5000; os mais antigos descartados), lista de aguardantes (long poll).
- Estados: `running` → `paused` (temporizador de ociosidade ligado,
  prazo de execução suspenso) → `running` ... → `finished`.
- Após `end`, o processo permanece 5 min para consulta de eventos (execuções
  assíncronas) e então termina.
- Comandos chegam por `ana_execution:command(Id, User, Cmd)` e só são aceitos
  em estado `paused` (exceto `stop`, aceito sempre — mata o worker).
- Registro global: ETS `ana_executions` `Id → {Pid, Owner}`.

## HTTP
| Rota | Função |
|------|--------|
| `POST /api/programs/:name/run` | `{params, debug, breakpoints, stop_on_entry, commit, async, timeout_ms}` |
| `GET /api/executions/:id` | estado atual + resumo |
| `GET /api/executions/:id/events?since=N&wait=1` | eventos (long poll 25 s) |
| `POST /api/executions/:id/command` | `{action, expression?, lines?}` |
