# 017 — Plano técnico

Princípio: programas Python nunca fazem rede nem veem segredos (P10). Toda
saída passa por um **conector** no núcleo (hosts permitidos, autenticação,
TLS verificado, limite de taxa, prazo, disjuntor, registro). Toda entrega é
**pelo menos uma vez** com idempotência ponta a ponta.

## Dados (migração `022_integration_hub.sql`)
Esquema `integration` (sem acesso de `ana_exec`, exceto pela função de
enfileirar):
- `connector`: `name`, `kind` (`http_api` | `webhook_in`), `base_url`,
  `auth` (`none`, `basic`, `bearer`, `api_key`, `oauth2_client`),
  `api_key_header`, `token_url` (OAuth2), `allowed_hosts text[]`,
  `timeout_ms`, `rate_per_min`, `outbound_program` (entrega da caixa de
  saída), `inbound_program` (processa webhooks), assinatura de webhook
  (`signature_header`, `timestamp_header`, `event_id_header`,
  `replay_window_s`), `max_attempts`, `active`.
- `secret` (`connector`, `key`, `ciphertext`, `nonce`, `tag`,
  `expires_at`): **AES-256-GCM** no núcleo com a chave mestra
  `ANA_MASTER_KEY` (32 bytes base64, igual em todos os nós). Sem chave →
  cofre desligado (cadastrar segredo é recusado). Nunca sai do núcleo:
  a API devolve só quais chaves existem e a validade.
- `outbox` (gravada na transação do programa via
  `integration.enqueue(connector, kind, payload, ordering_key)` —
  SECURITY DEFINER) e `inbox` (`UNIQUE (connector, event_id)`): situação
  (`pending`, `processing`, `done`, `dead`), tentativas, próxima tentativa,
  último erro, arrendamento (`lease_until`) para retomar o que um nó caído
  deixou.
- `call_log` (uma linha por chamada HTTP: conector, método, caminho,
  status, ms, erro) — base do painel; expurgo pela retenção (spec 024).
- Finanças: `finance.bank_account` (conta contábil do banco),
  `bank_statement`, `bank_statement_line` (`UNIQUE (bank_account,
  dedup_key)`), `bank_match` (linha ↔ títulos, N:1), `finance.charge`
  (cobrança por gateway, `UNIQUE (connector, external_id)`); contas padrão
  `bank_fees`, `interest_received`.

## Núcleo
- `ana_vault`: cifra/decifra, grava/lê segredos (só o núcleo).
- `ana_connector:http/5`: monta a URL a partir de `base_url` + caminho
  relativo (sem esquema/host: impede SSRF), confere o host contra
  `allowed_hosts`, autentica (basic/bearer/api_key/OAuth2 client
  credentials com token em cache), aplica prazo, limite por minuto (ETS),
  disjuntor (spec 023) e resposta até 10 MB; registra em `call_log` com
  segredos mascarados.
- Execução: operação `http` no protocolo (assíncrona como `remote`).
- `ana_integration` (gen_server em cada nó): a cada segundo reivindica
  mensagens vencidas com `FOR UPDATE SKIP LOCKED` (nenhuma entrega
  duplicada entre nós), respeita ordem por `ordering_key`, executa o
  programa do conector como o dono da mensagem (P14; quem enfileirou, ou o
  robô `system` para webhooks) e grava o resultado. Falha → recuo
  exponencial (10 s × 2ⁿ, até 1 h); esgotou → `dead`. Reprocessar/descartar
  pelo painel.
- Webhooks: `POST /hooks/<conector>` sem sessão; corpo até 1 MB; HMAC-SHA256
  de `timestamp.corpo` com o segredo `hmac_key` (comparação em tempo
  constante), janela anti-repetição, id do evento por cabeçalho ou campo
  `id` do JSON; grava na `inbox` (duplicado → 200 sem reprocessar) e
  responde 202 sem esperar o processamento.

## Programas do produto
- `ana.http(conector, método, caminho, json=…, headers=…, params=…)` e
  `ana.send(conector, tipo, dados, key=None)`.
- `finance.save_bank_account`, `finance.import_statement` (OFX e CSV com
  layout configurável; deduplicação por FITID ou hash data+valor+histórico;
  inserção em lotes de 5 000 por `unnest`), `finance.reconcile` (regras em
  conjunto: cobrança exata → documento + valor → valor + data ± tolerância;
  confiança; automática acima do limiar quando há um só candidato),
  `finance.match_statement_line` (manual, 1 linha ↔ N títulos, diferença em
  tarifas/juros), `finance.unmatch_statement_line` (estorno),
  `finance.reconciliation` (bancada, comando `conciliar`),
  `finance.create_charge` e `finance.settle_charge` (idempotente).
- Modelo de conector: `integration.generic_gateway_out` /
  `integration.generic_gateway_in` (contrato JSON simples, ponto de partida
  para gateways reais).

## Painel
Administração → Operação do sistema → **Integrações**: conectores (cadastro,
segredos só de escrita, validade), mensagens de saída/entrada por situação
com reprocessar/descartar, indicadores por conector (24 h: chamadas, erro %,
p95).

## Fica para depois (tarefas abertas)
SFTP, pasta monitorada e e-mail de entrada; mTLS; leitores CNAB 240/400;
pacotes de modelos instaláveis por cliente.
