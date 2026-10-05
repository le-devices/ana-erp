# 028 — Atualização dos programas do produto em instalações existentes

## Problema
Os programas do produto (sementes em `priv/programs`) só são criados quando
não existem, para nunca sobrescrever customizações do cliente. Por isso
correções e melhorias do produto não chegam a quem já tem o programa
instalado. Decisão do dono do produto (out/2026, spec 009 "Outros itens"):
**oferecer a atualização e o administrador aceita** — nada muda sozinho.

## Histórias
- **H1** Como administrador, vejo quais programas do produto têm versão nova,
  se foram alterados aqui e o que muda (comparação lado a lado).
- **H2** Como administrador, aceito uma atualização (ou todas as que não foram
  alteradas aqui) ou a dispenso; posso voltar à versão anterior pelo histórico.
- **H3** Como desenvolvedor do cliente, minhas alterações nunca são
  sobrescritas sem que o administrador confirme explicitamente.

## Requisitos funcionais
- **RF-028-01** Cada programa guarda a impressão (SHA-256) da semente em que
  se baseia (`seed_hash`): ao ser criado pela semente ou ao aceitar uma
  atualização. Instalações anteriores usam a versão gravada pela semente
  (comentário `seed`).
- **RF-028-02** Ao subir (e sob demanda), cada semente é comparada com o
  programa instalado: igual → em dia; semente igual à base e programa
  diferente → customização local, nada a oferecer; semente diferente da
  base → **atualização disponível**, marcada como *alterado aqui* quando o
  programa difere da base.
- **RF-028-03** Atualização dispensada não é oferecida de novo até que a
  semente mude outra vez. Quando o programa volta a se basear na semente
  atual (fica igual a ela), a dispensa deixa de valer.
- **RF-028-04** Aceitar grava a semente como nova versão do programa
  (histórico, auditoria, inspeção de PARAMS/lint), com o comentário
  "atualização do produto"; a configuração local (exposto, papel mínimo,
  menu, ativo, limites) é preservada. Programa *alterado aqui* exige
  confirmação explícita de sobrescrever.
- **RF-028-05** "Aceitar todas as não alteradas" em uma ação.
- **RF-028-06** Tela em Administração → Sistema → **Atualizações do
  produto**: lista (programa, tipo, situação, alterado aqui, detectada em),
  comparação lado a lado (instalado × produto, com a base quando houver),
  aceitar, dispensar, aceitar todas as não alteradas.

## Requisitos não funcionais
- **RNF-028-01** (segurança) Só administrador; cada decisão vai para o
  registro administrativo (spec 011) e a versão nova para o histórico.
- **RNF-028-02** (24/7, P16) A verificação roda em cada nó ao subir, é
  idempotente e não bloqueia a subida; aceitar não reinicia nada (o cache
  de programas é invalidado no cluster).
- **RNF-028-03** (P15) Só grava quando muda: oferta nova ou decisão.

## Critérios de aceite
- **CA-028-01** Semente nova sobre programa não alterado → oferta
  "não alterado"; aceitar → fonte igual à semente, versão +1, oferta some.
- **CA-028-02** Semente nova sobre programa alterado → oferta "alterado
  aqui"; aceitar sem confirmar é recusado (`LOCALLY_MODIFIED`); com
  confirmação, aceita.
- **CA-028-03** Dispensada não volta na próxima verificação.
- **CA-028-04** Programa alterado localmente sobre a semente atual não gera
  oferta.
- **CA-028-05** Não administrador não vê nem decide atualizações.
