# 018 — Tarefas: Agendamento de rotinas

- [x] T-018-01 Esquema `scheduler` (rotinas, gatilhos, calendário/feriados, ocorrências) (RF-018-01, 02)
- [x] T-018-02 Parser cron + calendário de dias úteis + fuso/horário de verão (RF-018-02, RNF-018-02, CA-018-04)
- [x] T-018-03 Líder em cluster e reserva atômica de ocorrência (RNF-018-01, CA-018-01)
- [x] T-018-04 Concorrência, perdidas, tentativas e tempo máximo (RF-018-03..05, CA-018-02, 03, 06)
- [x] T-018-05 Dependências e passagem de resultado (RF-018-06, CA-018-05)
- [x] T-018-06 Operação, histórico e próximas ocorrências na Administração (RF-018-07, 09)
- [x] T-018-07 Notificações (RF-018-08)
- [x] T-018-08 Testes CA-018-01..06

Notas da implementação: testes em `tests/integration` (TestScheduler, CA-018-02..06,
RF-018-07/09) e `tests/cluster` (CA-018-01 com troca de líder); notificações por
e-mail/webhook ficam a cargo de `notify_program` + conectores da spec 017.
