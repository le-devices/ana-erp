# 003 — Plano técnico: Chamada Remota

## Módulos
| Módulo | Papel |
|--------|-------|
| `ana_rpc` | API Erlang: `call/3`, `functions/1`; mapeia erros para JSON-RPC |
| `ana_http_rpc` | handler cowboy de `POST /rpc` e `GET /rpc/functions`; lotes em paralelo |
| `ana_remote_system` | resolve Sistema remoto, executa JSON-RPC de saída com `httpc` (TLS verificado quando `https`) |
| `clients/python/ana_client.py` | cliente sem dependências |

## Fluxo de entrada
```
POST /rpc ─► autenticar ─► ana_rpc:chamar(F, P, Usuario)
              ├─ programa remoto/ativo? senão -32601
              ├─ papel suficiente?      senão -32003
              └─ ana_execution:executar(F, P, #{origem => remoto, sync})
```
Resultado `{ok, R}` → `result`; `{error, #{code := C}}` mapeado:
| Situação | code JSON-RPC |
|----------|---------------|
| JSON inválido | -32700 |
| requisição inválida | -32600 |
| não encontrado / não remoto | -32601 |
| parâmetro inválido | -32602 |
| proibido | -32003 |
| sobrecarga | -32004 |
| `ana.Error` (negócio) | -32000 |
| tempo esgotado | -32001 |
| erro interno | -32603 |

## Fluxo de saída (`ana.remote`)
Python envia `request{op: remote, args: {system, function, params}}`.
`ana_execution` chama `ana_remote_system:call/3` (lê destino em conexão separada,
fora do papel restrito), e devolve resultado ou erro ao Python, que lança
`ana.Error`.

Observação: a chamada de saída **não** participa da Unidade de Trabalho local
(sistemas distintos). Documentado para o desenvolvedor.

## Distribuição Erlang
`vm.args` gerado no start a partir de env: só aplica `-name`/`-setcookie` se
ambos definidos (RNF-003-02). Script `bin/ana-start`.
