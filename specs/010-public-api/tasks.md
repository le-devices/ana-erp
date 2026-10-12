# 010 — Tarefas: API pública

- [x] T-010-01 Tabelas `api_client`, `signing_key`, `api_idempotency`, `api_nonce`, `api_usage`, `api_call_log`; coluna `program.public` (RF-010-01, 11) — migração 035
- [x] T-010-02 Tokens Ed25519 com `kid`, rotação sem parada e validação estrita (RNF-010-02, CA-010-02) — `ana_api`
- [x] T-010-03 Clientes de API com cache ETS, invalidação por NOTIFY e desativação em até 5 s (RF-010-01, 09, CA-010-03)
- [x] T-010-04 `/oauth/token` client_credentials, segredo duplo na troca, proteção contra força bruta (RF-010-02, CA-010-01)
- [x] T-010-05 Portão público: HTTPS/proxy confiável, HSTS, CORS em memória, escopo ∩ exposto ∩ papel, IPs permitidos (RF-010-05, 08, RNF-010-01, CA-010-04, 10)
- [x] T-010-06 Limite por minuto, cota diária consolidada entre nós e fração de capacidade pública (RNF-010-04, 08, CA-010-07)
- [ ] T-010-06b Disjuntor por cliente: suspender após excesso de 5xx/timeouts e avisar (RNF-010-10)
- [x] T-010-07 Requisições assinadas HMAC + nonce (RF-010-06, CA-010-06)
- [x] T-010-08 Idempotência com espera da chamada em andamento e falha segura (RF-010-07, RNF-010-09, CA-010-05)
- [x] T-010-09 Chave publicável e programas `public` (RF-010-04, CA-010-09)
- [ ] T-010-10b PKCE + tokens de renovação rotativos + tela de consentimento (RF-010-03, CA-010-08)
- [ ] T-010-11b TOTP (RF-010-12)
- [ ] T-010-12b HTTP/2 + TLS nativo opcional, compressão, cache `cacheable` (RNF-010-12, 13)
- [x] T-010-13 Tela "API pública" na Administração (clientes, segredo exibido uma vez, troca de segredo, chave HMAC, desativação, chamadas) e opção "Público" no programa (H1, H6, RF-010-11)
- [x] T-010-14 Teste de carga versionado `tests/load/public_api_load.py` (RNF-010-14, CA-010-11) — mede; ver "Situação" na spec
- [ ] T-010-14b Atingir 1.000 chamadas/s por nó: hoje cada execução abre um processo Python novo (isolamento, RNF-002-07); exige decisão (reuso de processo para programas só leitura, ou cache `cacheable` da T-010-12b)
