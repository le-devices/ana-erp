# 053 — Regressão automática dos processos do cliente antes de atualizar

Situação: especificada (nov/2026).

## Problema
O maior medo de quem tem ERP é a atualização quebrar o processo da empresa —
principalmente quando há personalização. O ANA já tem as peças para acabar
com esse medo: trilhas de processo de ponta a ponta com conciliações (spec
042), instância de testes com dados reais mascarados (spec 034), programas do
cliente em camadas (spec 009) e atualização do produto com comparação lado a
lado (spec 028). Falta juntá-las num **ensaio automático da atualização com
os processos e os dados do próprio cliente**.

## Decisões
- **D1 — Trilhas do cliente.** Além das trilhas do produto, o cliente grava
  as suas: uma sequência de rotinas com variantes (spec 045) e o resultado
  esperado (documentos gerados, saldos, conciliações em zero). Pode gravar
  "fazendo": o ERP registra a sequência que a pessoa executou na instância
  de testes e a transforma em trilha.
- **D2 — Ensaio da atualização.** Ao chegar uma versão nova (produto ou
  pacote de transporte, spec 034), a instância de testes recebe uma cópia
  mascarada recente, aplica a atualização e roda todas as trilhas;
  o resultado compara antes × depois.
- **D3 — Relatório de impacto.** O que mudou: trilhas que passaram, que
  falharam (com a rotina, o erro e a diferença), programas do cliente
  afetados pela mudança de programas do produto, tempo de cada trilha
  (regressão de desempenho). A produção só recebe a atualização com o
  relatório aceito (política configurável).
- **D4 — Personalização protegida.** Programas do cliente que dependem de
  programas do produto alterados são listados com a diferença; o ensaio diz
  se continuam funcionando.

## Requisitos funcionais
- **RF-053-01** Cadastro de trilhas do cliente e gravação "fazendo" (D1).
- **RF-053-02** Ensaio automático na instância de testes a cada atualização
  ou pacote (D2), agendável e sob demanda.
- **RF-053-03** Relatório de impacto (D3) com comparação de desempenho.
- **RF-053-04** Política de liberação: atualização na produção só com o
  ensaio verde ou aceito por quem tem permissão.
- **RF-053-05** Dependências da personalização (D4).

## Requisitos não funcionais
- **RNF-053-01** O ensaio nunca roda na produção nem chama sistemas externos
  (bloqueio da instância de testes, spec 034).
- **RNF-053-02** 50 trilhas típicas em menos de 15 minutos.

## Critérios de aceite
- **CA-053-01** Uma trilha gravada "fazendo" (pedido → expedição →
  fatura → recebimento) roda sozinha e confere documentos e conciliações.
- **CA-053-02** Uma atualização que muda um programa usado por um programa do
  cliente aparece no relatório com a diferença e o resultado da trilha.
- **CA-053-03** Com a política ligada, a produção recusa a atualização sem
  ensaio aceito.
