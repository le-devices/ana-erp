# 004 — Depurador

## Problema
Desenvolver regra de negócio exige ver o programa rodando: parar numa linha,
inspecionar variáveis, avançar passo a passo, avaliar expressões — tudo pelo
Estúdio, sem ferramentas externas, sobre dados reais e sem risco de
gravar algo por acidente.

## Histórias
- **H1** Como desenvolvedor, quero marcar pontos de parada no editor e executar
  em modo depuração.
- **H2** Ao parar, quero ver linha atual, pilha de chamadas e variáveis locais.
- **H3** Quero continuar, passar por cima (próxima linha), entrar em função,
  sair da função e parar a execução.
- **H4** Quero avaliar expressões no contexto do quadro atual.
- **H5** Quero adicionar/remover pontos de parada com a execução pausada.

## Requisitos funcionais
- **RF-004-01** Execução com `debug: true` e `breakpoints: [lines]` é
  sempre assíncrona e devolve `execution_id`.
- **RF-004-02** Ao atingir ponto de parada (ou concluir um passo), o runtime
  emite evento `pause` com `linha`, `pilha` (lista de `{funcao, linha}` do
  programa), `variaveis` (locais do quadro atual; `repr` truncado em 200
  caracteres, até 100 variáveis) e `reason` (`breakpoint` | `step`).
- **RF-004-03** Comandos (`action`): `continue`, `over` (próxima linha no mesmo quadro),
  `into` (entrar), `out` (sair), `stop`, `eval {expression}`, `breakpoints {lines}`.
- **RF-004-04** `eval` retorna `repr` do resultado ou a exceção, sem retomar
  a execução.
- **RF-004-05** Eventos (saída, pausa, avaliação, fim) ficam em sequência
  numerada; o cliente consulta com `since=N` e pode aguardar até 25 s por
  novos eventos (long polling).
- **RF-004-06** Opção `stop_on_entry: true` pausa na primeira linha de
  `main`.
- **RF-004-07** O depurador só para em linhas do programa depurado (não em
  bibliotecas internas do runtime).

## Requisitos não funcionais
- **RNF-004-01** (segurança) Execuções em depuração **sempre terminam em
  ROLLBACK**, salvo se iniciadas com `commit: true` por usuário
  `desenvolvedor`+. Evita gravações acidentais durante investigação.
- **RNF-004-02** (segurança) Só o usuário que iniciou a depuração (ou `admin`)
  pode enviar comandos ou ler eventos dela.
- **RNF-004-03** (robustez) Enquanto pausada, o tempo máximo de execução é
  suspenso; vale o tempo de ociosidade `ANA_DEBUG_IDLE_MS`
  (padrão 600000). Estourado, a execução é parada com ROLLBACK.
- **RNF-004-04** (robustez) No máximo `ANA_DEBUG_MAX` (padrão 8)
  depurações simultâneas — conexões em pausa seguram transação.
- **RNF-004-05** (performance) Sem pontos de parada e sem passo pendente o
  rastreamento é desligado para o quadro (custo ~zero fora das linhas
  relevantes).

## Critérios de aceite
- **CA-004-01** Programa de 5 linhas com ponto na linha 3: evento `pause` com
  `linha = 3` e variáveis das linhas 1–2.
- **CA-004-02** `over` leva à linha 4; `continue` termina com `end`.
- **CA-004-03** `eval "x * 2"` retorna o valor correto e a execução segue
  pausada.
- **CA-004-04** `stop` encerra com status `aborted` e nada é gravado.
- **CA-004-05** Programa que grava e termina normalmente em depuração sem
  `commit` → nada gravado.
- **CA-004-06** Outro usuário (não admin) recebe 403 ao comandar a depuração.
