# 003 — Chamada Remota

## Problema
Outros sistemas (e outros ANA) precisam acionar regras de negócio do ERP — criar
pedido, consultar saldo — sem acessar o banco diretamente. Programas do ANA
também precisam acionar programas expostos de outros sistemas.

## Histórias
- **H1** Como integrador, quero chamar uma programa exposto por HTTP com JSON e
  receber o resultado ou um erro estruturado.
- **H2** Como integrador Erlang/Elixir, quero chamar a função via distribuição
  Erlang.
- **H3** Como integrador Python, quero um cliente pronto.
- **H4** Como desenvolvedor, quero que um programa ANA chame programas expostos de
  outro ANA (Sistema remoto) de forma transparente.
- **H5** Como integrador, quero descobrir quais funções existem e seus
  parâmetros.

## Requisitos funcionais
- **RF-003-01** `POST /rpc` aceita JSON-RPC 2.0 (`method` = nome do programa,
  `params` = objeto). Lotes (array) são aceitos.
- **RF-003-02** Só programas com `exposed = true`, ativos e do tipo `program`
  são chamáveis; outros → erro `-32601` (método não encontrado), sem revelar
  se o programa existe.
- **RF-003-03** Autenticação Bearer (sessão de usuário). O papel do usuário
  deve ser ≥ `min_role` do programa, senão `-32003` (proibido).
- **RF-003-04** Erros de negócio (`ana.Error`) → código `-32000` com
  `data.code` e `message`. Erros inesperados → `-32603` com mensagem
  genérica e `data.execution_id` (sem rastro interno).
- **RF-003-05** `GET /rpc/functions` lista programas expostos acessíveis ao usuário,
  com descrição e `PARAMS` declarados.
- **RF-003-06** `ana_rpc:call(Function, Params, Username)` é chamável por outro
  nó Erlang (`erpc:call/4`) quando o nó compartilha o cookie de distribuição;
  as permissões do usuário `Login` se aplicam.
- **RF-003-07** Cliente Python `clients/python/ana_client.py` (só biblioteca
  padrão): `Ana(url).login(username, password)`, `.call(function, **params)`,
  `.batch(...)`, `.functions()`; erros viram `AnaRemoteError(code, message, data)`.
- **RF-003-08** Sistemas remotos: `ana_system.remote_system(name, url, username, password, timeout_ms, active)`.
  `ana.remote(destino, funcao, **p)` entra no Sistema remoto (sessão em cache,
  renovada em 401) e faz a chamada JSON-RPC. TLS sempre verificado.
- **RF-003-09** Toda chamada remota recebida gera registro de execução com
  origem `remote`.

## Requisitos não funcionais
- **RNF-003-01** (segurança) Programas não fornecem URL: só nome de Sistema remoto
  cadastrado (mitiga SSRF). Credenciais do Sistema remoto nunca são expostas ao Python.
- **RNF-003-02** (segurança) Distribuição Erlang desativada por padrão;
  habilitada só com `ANA_NODE_NAME` e `ANA_COOKIE` definidos.
- **RNF-003-03** (robustez) Chamadas de saída têm timeout (padrão 15 s) e
  falha vira `ana.Error("REMOTE_FAILED", ...)` no programa.
- **RNF-003-04** (robustez) Lote JSON-RPC limitado a 50 chamadas.
- **RNF-003-05** (performance) Lote JSON-RPC executa as chamadas em paralelo
  (cada uma em sua Unidade de Trabalho).

## Critérios de aceite
- **CA-003-01** `{"jsonrpc":"2.0","method":"sales.create_order","params":{...},"id":1}`
  retorna `result` com número do pedido.
- **CA-003-02** Chamar programa com `exposed=false` → `-32601`.
- **CA-003-03** Sem token → HTTP 401.
- **CA-003-04** `ana.Error("INSUFFICIENT_STOCK", ...)` chega como `-32000`
  com `data.code = "INSUFFICIENT_STOCK"`.
- **CA-003-05** Cliente Python cria pedido e consulta saldo de ponta a ponta.
- **CA-003-06** Programa com `ana.remote("local", "demo.sum", a=1, b=2)` com
  Sistema remoto `local` apontando para o próprio ANA retorna 3.
