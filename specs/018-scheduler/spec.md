# 018 — Agendamento de rotinas

## Problema
Rotinas precisam rodar sozinhas: importar extratos às 6 h, gerar faturas no
último dia útil, recalcular reposição toda noite, enviar lembretes de
vencimento, atualizar o analítico. Isso exige agendamento granular, seguro
em cluster, com controle de falhas e histórico.

## Histórias
- **H1** Como administrador/desenvolvedor, agendo um programa com parâmetros,
  usuário de execução e calendário flexível.
- **H2** Defino o que acontece se uma execução ainda está rodando, se falhou
  ou se o servidor estava fora do ar no horário.
- **H3** Encadeio rotinas (B roda após A com sucesso; C se A falhar).
- **H4** Pauso, retomo, disparo manualmente e vejo o histórico e a próxima
  execução de cada rotina.
- **H5** Recebo aviso quando uma rotina falha ou atrasa.

## Requisitos funcionais
- **RF-018-01** Rotina (`scheduler.job`): programa, parâmetros (podem usar
  datas relativas: `{{today}}`, `{{last_month_start}}`…), executar como
  (usuário técnico com papel/grupos próprios), perfil de limite (spec 012),
  ativa/pausada, descrição, responsável.
- **RF-018-02** Gatilhos (um ou mais por rotina): expressão cron de 5 campos
  com fuso horário; intervalo fixo; data/hora única; calendário de dias úteis
  (feriados cadastrados, "último dia útil do mês", "n-ésimo dia útil");
  janela permitida (ex.: só entre 22 h e 6 h); data de início/fim.
- **RF-018-03** Política de concorrência: `skip` (não inicia se a anterior
  roda), `queue` (enfileira uma), `parallel` (até N).
- **RF-018-04** Execuções perdidas (servidor fora do ar): `skip`, `run_once`
  ou `run_all` (limitado), configurável por rotina.
- **RF-018-05** Falhas: novas tentativas com recuo exponencial e máximo;
  tempo máximo por execução; ação ao esgotar (notificar, pausar a rotina).
- **RF-018-06** Dependências: gatilho "após rotina X" com condição
  (`success` | `failure` | `always`) e passagem do resultado de X como
  parâmetro.
- **RF-018-07** Operação: pausar/retomar, executar agora (com parâmetros
  alternativos), pular a próxima, histórico (início, fim, status, tentativa,
  ligação com a execução auditada), próximas 10 ocorrências calculadas.
- **RF-018-08** Notificações para falha, atraso (não iniciou até X s após o
  previsto) e duração anômala: aviso no Estúdio (Início e Administração) e,
  opcionalmente, um programa de notificação da rotina (`notify_program`) que
  recebe o aviso — por ele se faz e-mail/webhook através de conectores
  (spec 017).
- **RF-018-09** Permissões: criar/alterar rotinas exige `developer`; rotinas
  que executam como outro usuário exigem `admin`; tudo em `admin_log`.

## Requisitos não funcionais
- **RNF-018-01** (robustez) Em cluster, cada ocorrência roda **exatamente
  uma vez**: reserva atômica da ocorrência no banco (`INSERT … ON CONFLICT`
  por rotina+horário) e liderança por advisory lock; um nó que cai libera a
  liderança automaticamente.
- **RNF-018-02** (robustez) Relógio: cálculos em UTC com fuso da rotina;
  mudanças de horário de verão tratadas (não duplica nem pula sem registrar).
- **RNF-018-03** (performance) 10 mil rotinas ativas com precisão de
  ±1 s; cálculo de próximas ocorrências sem varrer todas a cada segundo
  (fila ordenada por próxima execução).
- **RNF-018-04** (segurança) Rotinas executam com o menor privilégio do
  usuário técnico configurado, nunca como o criador implicitamente.

## Critérios de aceite
- **CA-018-01** Rotina `*/1 * * * *` roda uma vez por minuto mesmo com dois
  nós ativos.
- **CA-018-02** Rotina `skip` com execução de 90 s agendada a cada minuto não
  sobrepõe execuções e registra as ocorrências puladas.
- **CA-018-03** Falha com 3 tentativas e recuo: 3 execuções registradas, aviso
  emitido, rotina pausada se configurado.
- **CA-018-04** "Último dia útil do mês" calcula corretamente em mês com
  feriado no último dia.
- **CA-018-05** B só roda após A com sucesso e recebe o resultado de A.
- **CA-018-06** Núcleo parado durante 3 ocorrências com política `run_once`
  executa uma única recuperação ao voltar.
