# 010 — Plano técnico: API pública

## Visão
```
 Internet ──TLS──► (proxy confiável opcional) ──► ana_http
                                                   │
                     ana_public_gate (middleware cowboy, só rotas públicas)
                       1. TLS / proxy confiável           (RNF-010-01)
                       2. CORS em memória                 (RF-010-08)
                       3. autenticação: token Ed25519 | X-Api-Key | sessão
                       4. assinatura HMAC + nonce         (RF-010-06)
                       5. limites (balde por cliente/IP)  (RNF-010-04)
                       6. escopo ∩ exposto ∩ papel        (RF-010-05)
                       7. idempotência                    (RF-010-07)
                                                   │
                                          ana_rpc / ana_execution
```

## Módulos
| Módulo | Responsabilidade |
|--------|------------------|
| `ana_api_client` | cadastro, cache ETS (`client_id` → config), invalidação via NOTIFY `ana_api_client` |
| `ana_token` | emissão/validação Ed25519 (JWS compacto, `alg` fixo `EdDSA`), chaves em `ana_system.signing_key` com `kid`, rotação |
| `ana_oauth` | `/oauth/token`, `/oauth/authorize`, PKCE S256, códigos de uso único (TTL 60 s), famílias de tokens de renovação |
| `ana_rate_limit` | baldes de fichas em ETS com `atomics` (por cliente, IP, usuário); cotas diárias persistidas a cada minuto |
| `ana_idempotency` | tabela `ana_system.idempotency` (chave, cliente, hash do corpo, estado, resposta, expira) com `INSERT ... ON CONFLICT` para reservar; resposta gravada ao final |
| `ana_public_gate` | middleware que encadeia as verificações e anota o contexto da chamada |
| `ana_totp` | 2º fator RFC 6238 |

## Dados
- `ana_system.api_client(client_id, name, kind, secret_hashes[], origins[],
  redirect_uris[], scopes[], ip_allow[], rate_per_minute, burst, daily_quota,
  require_signature, active, expires_at, created_at)`
- `ana_system.signing_key(kid, public_key, private_key_enc, active, created_at)`
  — chave privada cifrada com chave mestra de `ANA_MASTER_KEY`.
- `ana_system.refresh_token(id_hash, family, client_id, username, scopes,
  expires_at, used_at, revoked)`
- `ana_system.idempotency(key, client_id, body_hash, status, response, expires_at)`
  UNLOGGED não serve aqui (precisa sobreviver a queda): tabela normal com
  limpeza periódica.
- `ana_system.api_call_log` particionada por mês (RF-010-11).
- `ana_system.program.public` e `ana_system.program.cacheable_ttl_s`.

## Decisões
- **Tokens assinados (sem estado) + revogação por evento**: validação sem
  banco (performance); revogação imediata via NOTIFY → lista de revogados em
  ETS por até a validade máxima do token (10 min).
- **Ed25519** (crypto nativo do OTP): chaves pequenas, verificação rápida,
  sem armadilha de `alg=none`/HS-vs-RS.
- **PKCE obrigatório** inclusive para clientes confidenciais no fluxo de código.
- HTTP/2: `cowboy:start_tls` com ALPN quando `ANA_TLS_CERT`/`ANA_TLS_KEY`
  definidos; senão, espera-se proxy TLS na frente.
- Teste de carga com `k6` ou ferramenta própria em Erlang, versionado em
  `tests/load/`.

## Riscos
- Relógio dessincronizado afeta assinatura/expiração → tolerância de 30 s e
  alerta de desvio via `/health`.
- Cache de cliente desatualizado entre nós → NOTIFY + TTL curto de segurança (30 s).
