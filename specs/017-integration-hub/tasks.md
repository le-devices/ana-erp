# 017 — Tarefas: Hub de integrações

- [x] T-017-01 Esquema `integration` (conectores, cofre, outbox, inbox, registro de chamadas) e chave mestra (RF-017-01, 02, 05)
- [x] T-017-02 `ana.http` com hosts permitidos, autenticação (basic, token, chave de API, OAuth2), limite por minuto e disjuntor (RF-017-03, RNF-017-01, CA-017-06)
- [ ] T-017-02b `ana.sftp`, pasta monitorada e e-mail de entrada (RF-017-01, 03, 06)
- [ ] T-017-02c mTLS por conector (RNF-017-01)
- [x] T-017-03 Webhooks de entrada com assinatura, anti-repetição e idempotência (RF-017-04, CA-017-04)
- [x] T-017-04 Entrega confiável com recuo e fila de mortos (RF-017-05, RNF-017-02, CA-017-05)
- [x] T-017-05 Leitores OFX e CSV configurável, deduplicação, 100 mil linhas < 60 s (RF-017-06, RNF-017-03, CA-017-01)
- [x] T-017-05b Leitor CNAB 240 (extrato FEBRABAN, segmento E e saldo final), fonte automática por conta — pasta de arquivos (OFX, CNAB 240) ou API do banco (conector + adaptador) — e rotina `extratos.buscar` (RF-017-06); CNAB 400 de extrato não é padronizado: adaptador por banco
- [x] T-017-06 Conciliação bancária por regras, manual, agrupada e com estorno (RF-017-07, CA-017-02, 03)
- [x] T-017-07 Cobrança por gateway e liquidação por webhook, idempotente (RF-017-08)
- [x] T-017-08 Painel de integrações e modelo de conector de gateway (RF-017-09, 10)
- [ ] T-017-08b Pacotes de modelos de conector instaláveis por cliente (RF-017-10)
- [x] T-017-09 Testes CA-017-01..06
