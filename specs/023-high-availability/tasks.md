# 023 — Tarefas: Alta disponibilidade

- [x] T-023-01 Plano técnico; `/health/live` e `/health/ready` (RF-023-01)
- [x] T-023-02 Desligamento gracioso com drenagem (RF-023-02, CA-023-04)
- [x] T-023-03 Disciplina de migrações compatíveis e verificação de esquema (RF-023-03, CA-023-05)
- [x] T-023-04 Execuções interrompidas com resposta clara (RF-023-04)
- [x] T-023-05 Banco com troca de primário e leitura em réplica (RF-023-05) — lista de endereços exercitada no caos (primeiro endereço inexistente); promoção real de réplica não automatizada (exige cluster PostgreSQL de teste)
- [x] T-023-06 Backup contínuo e teste de restauração documentado (RF-023-06)
- [x] T-023-07 Disjuntores e filas limitadas (RF-023-07)
- [x] T-023-08 Suíte de caos `tests/chaos` (CA-023-01..06, RNF-023-03)
- [x] T-023-09 Troca real de primário com cluster PostgreSQL local (RF-023-05, RNF-023-02):
  `tests/chaos/docker-compose.pg-ha.yml` com primário + réplica em streaming (mesma imagem Citus,
  slot de replicação, `primary_conninfo`), núcleo com `ANA_DB_HOST=pg1,pg2` e
  `ANA_DB_READ_HOSTS=pg2`. Casos: (a) promover a réplica (`pg_promote()`) e derrubar o primário
  com carga — o núcleo segue o novo primário sem reiniciar, em ≤ 10 s; (b) console SQL lê na
  réplica e, com a réplica fora, cai para o primário; (c) primário antigo não é aceito se voltar
  sem ser rebaixado (`pg_is_in_recovery`); (d) opcional: reintegrar o antigo primário como réplica
  com `pg_rewind`. Suíte `tests/pg_ha` (`make teste-pg-ha`): (a), (b) e (c) automatizados;
  (d) não automatizado (documentado). Escolha do primário pela linha do tempo mais nova evita
  usar um primário antigo que volte sem ser rebaixado.
- [x] T-023-10 Falha momentânea do banco responde 503 (nunca 401) na autenticação, entrada e dono da execução;
  reconexão mais rápida (espera de 250 ms a 2 s, sondagem de 3 s); caos e pg-ha exigem zero 401 (RF-023-08, CA-023-07)
