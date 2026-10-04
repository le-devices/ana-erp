# 023 — Alta disponibilidade e tolerância a falhas (operação 24/7)

Situação: implementada; falta o teste de troca real de primário (T-023-09)

## Problema
Um ERP é usado o dia inteiro, todos os dias. O ANA já isola programas,
supervisiona processos e reconecta ao banco, mas a operação 24/7 exige
garantias explícitas, verificadas por testes de caos, para falhas de
programas, processos, nós, rede e banco — e manutenções sem parar.

## O que já existe (base)
Supervisão OTP; programas em processos isolados (exceção, estouro de memória
ou de CPU de um programa nunca derruba o núcleo); prazos com cancelamento de
SQL; pools com reconexão e recuo; agendador com liderança e troca de nó;
auditoria fora da transação.

## Requisitos funcionais
- **RF-023-01** Vários nós do núcleo atrás de um balanceador, sem estado na
  sessão HTTP (sessões no banco), com verificação de **prontidão**
  (`/health/ready`: banco, pools, Python, migrações) separada de **vida**
  (`/health/live`).
- **RF-023-02** Desligamento gracioso: ao receber sinal de parada, o nó deixa
  de aceitar novas requisições, sai da prontidão, aguarda execuções em curso
  até um prazo e só então encerra.
- **RF-023-03** Atualização sem parada (rolling): migrações compatíveis com a
  versão anterior em execução (expandir → migrar → contrair) e verificação na
  partida de compatibilidade de esquema.
- **RF-023-04** Execuções síncronas interrompidas pela queda de um nó são
  registradas como interrompidas; o chamador recebe erro claro (nunca fica
  sem resposta), e rotinas agendadas seguem as políticas da spec 018.
- **RF-023-05** Banco em alta disponibilidade: suporte a endereço de
  primário com troca automática (ex.: réplica promovida), reconexão
  transparente e opção de leitura em réplicas para o console SQL (consultas e
  relatórios de leitura). Programas continuam no primário (mesma transação).
- **RF-023-06** Cópias de segurança e restauração verificada: backup contínuo
  (WAL) com recuperação a um instante; teste periódico de restauração
  documentado.
- **RF-023-07** Proteção contra sobrecarga em cascata: disjuntores para
  dependências externas (sistemas remotos, conectores), filas com limite e
  rejeição rápida (503/429) em vez de degradação.

## Requisitos não funcionais
- **RNF-023-01** Disponibilidade alvo 99,9 % com 2+ nós; nenhuma falha de um
  único programa, processo ou nó do núcleo interrompe o serviço.
- **RNF-023-02** Recuperação: troca de nó em ≤ 10 s; queda e volta do banco
  sem reinício do núcleo.
- **RNF-023-03** Testes de caos automatizados e versionados.

## Critérios de aceite (testes de caos)
- **CA-023-01** 1.000 execuções de programas que lançam exceções, estouram
  memória, CPU ou tempo, ou matam o próprio processo: o núcleo continua
  respondendo e a memória do núcleo volta ao patamar inicial.
- **CA-023-02** Reiniciar o PostgreSQL com carga: requisições durante a queda
  falham rápido; após a volta, tudo funciona sem reiniciar o núcleo.
- **CA-023-03** Matar um nó do núcleo com carga atrás do balanceador: zero
  requisições perdidas após a janela de detecção; agendador troca de líder.
- **CA-023-04** Desligamento gracioso não interrompe execuções curtas em curso.
- **CA-023-05** Atualização rolling de dois nós sem erro para os usuários.
- **CA-023-06** Exceções internas no núcleo (handler HTTP, processo de
  execução) são registradas e isoladas; o supervisor reinicia o que cair.
