# 051 — Plano

Escopo deste item da fila: T-051-01..05 e T-045-07b (sugestão de variante depois de três usos iguais). A T-051-06
(auditoria de automação por área) vai junto com a 050 fase 3, como já está na fila.

O que se reaproveita, sem duplicar:
- **Documentos e fatos:** o catálogo de documentos da spec 039 (`bpm.document`: venda, compra, serviço, produção e
  projeto, cada um com a consulta de fatos).
- **Condições:** o construtor de condições da spec 020 (`conditions.js`) e o seu avaliador (`ana_flows:condition/2`),
  inclusive valores da empresa.
- **Execução:** o motor de execuções, com ensaio (spec 056), variantes (spec 045) e usuários robô (P14).
- **Tarefas:** as tarefas do BPM e a caixa "Minhas tarefas" (spec 039).
- **Avisos:** o sino.

## Regras "quando… então…" (T-051-02, D2, RNF-051-01)

### Tabelas (migração 076, esquema `automation`)
- `rule`:
  - nome e dono (pessoa ativa; P14);
  - gatilho e condições, no formato das esteiras;
  - ação, de uma lista fechada;
  - limite de disparos por janela;
  - `version`, que muda a cada alteração, e `rehearsed_version`;
  - ligada ou não, e o motivo do bloqueio.
- `fire`: o histórico — cada disparo com o documento, o resultado (`done`, `skipped`, `failed`, `blocked`,
  `rehearsal`), a execução e a cadeia.
- `pending`: a fila de eventos de documento.

### Gatilhos
- **Documento criado ou mudança de situação** (venda, compra, serviço, produção e projeto):
  - um gatilho no banco grava em `pending` só se houver regra ligada para aquele documento e evento;
  - sem regra, não há escrita nenhuma (P15);
  - depois do COMMIT, o NOTIFY `ana_wake/rules` acorda o processo `ana_rules`.
- **Horário:** cron, conferido pelo `ana_rules` a cada minuto, só no nó líder.
- **Limite de métrica:** lido das métricas que o núcleo já mantém (spec 019), disparando na passagem do limite, não a
  cada leitura.
- **Mensagem recebida:** inserção em `integration.inbox` de um conector.

### Ações (lista fechada)
- **Executar rotina:** com parâmetros, valores `{{campo}}` dos fatos e variante opcional, como o dono.
- **Criar tarefa:** para uma pessoa, grupo ou papel, com instruções, o documento e botões de ação.
- **Avisar:** pessoa ou grupo.
- **Enviar e-mail:** pelo conector SMTP, com assunto e corpo que aceitam `{{campo}}`.
- **Chamar conector:** sempre pela fila de saída, com nova tentativa (spec 017).

### Ensaio
- Toma o documento indicado ou o último daquele tipo.
- Avalia as condições e roda a ação em ensaio:
  - a rotina, desfeita (spec 056);
  - tarefa, aviso, e-mail e conector, só descritos.
- Mostra os fatos, o resultado das condições e o efeito.
- Só se liga uma regra ensaiada na versão atual (CA-051-01).

### Laço (RNF-051-01, CA-051-03)
- A execução da ação leva `ana.rule_chain` (SET LOCAL) com as regras da cadeia.
- O gatilho do banco copia a cadeia para o evento.
- Regra que reaparece na própria cadeia é bloqueada e desligada, com aviso ao dono.
- O limite de disparos por janela (padrão 20 por hora) também bloqueia, com aviso.

## Central de automações (T-051-01, D1, CA-051-04)

`GET /api/automations` junta numa lista só:
- agendamentos (`scheduler.job`), com a última execução, a próxima e as falhas;
- esteiras, com etapas automáticas e falhas;
- processos publicados, com casos com falha;
- regras;
- regras de alerta;
- conectores, com mensagens esgotadas;
- rotinas periódicas do produto.

Cada item traz tipo, nome, dono, situação, último resultado, próxima execução, falhas com o motivo e o caminho para o
histórico.

Ações:
- ligar e desligar, num só endpoint por tipo, que usa o mesmo caminho e as mesmas permissões de cada tela;
- ensaiar, para regras (o agendamento é ensaiado na tela dele);
- abrir o histórico.

Tela: Administração → Automações, com filtros (tipo, situação, dono, com falha) e a aba de regras com o construtor.

## Toda rotina automatizável (T-051-03, RF-051-04)

Teste sobre o catálogo: para cada rotina do menu,
- o agendador aceita um agendamento desligado dela;
- o validador de regras a aceita como ação;
- o compilador de processos a aceita como tarefa automática.

O que falhar é corrigido no produto, não no teste.

## Sugestões a partir do uso (T-051-04, D3, RNF-051-02, T-045-07b)

O processo `ana_suggestions` roda de hora em hora, no líder e em segundo plano:
- lê as execuções novas desde a última marca, sem custo para as execuções;
- mantém o agregado diário `automation.usage_day` (pessoa, rotina, parâmetros, primeira hora, quantidade);
- só conta execuções de pessoas: nada de robôs, ensaios, depurações ou simulações.

Padrões nesta fase:
- **Agendar (CA-051-02):** a mesma rotina com os mesmos parâmetros em 4 dias úteis seguidos, na mesma hora (±1 h).
  Aceitar cria a variante pessoal e o agendamento de segunda a sexta naquela hora, como a pessoa.
- **Salvar como variante (T-045-07b):** os mesmos parâmetros, 3 vezes em 30 dias, sem variante. Aceitar salva a
  variante.

Cada sugestão traz uma explicação em português ("você executou X com estes valores nas últimas 4 segundas às 8h").
Também tem uma impressão digital por pessoa: recusada, não volta. Aparece no centro de avisos do painel e na central.

Ficam para a T-051-04b: a sequência repetida de rotinas virar regra e a correção manual repetida virar política, que
precisam do agregado da spec 046.

## Exceções como tarefas (T-051-05, D4)

- Tarefas do ERP num processo embutido, `erp.tarefa` (início → tarefa → fim), criadas direto pela função
  `automation.create_task`, com:
  - documento;
  - contexto (os fatos);
  - instruções;
  - botões de ação (rotina e parâmetros);
  - condição de resolução.
- Fontes nesta fase:
  - a ação "criar tarefa" das regras;
  - a etapa automática de esteira que falhou depois das tentativas, que vira tarefa para os administradores (a esteira
    roda como robô, sem pessoa dona), com o erro e os botões "Tentar de novo" e "Pular a etapa" (com motivo).

  A tarefa se conclui sozinha quando a etapa sai da falha, seja tentada de novo por alguém, seja feita fora.
- "Minhas tarefas" mostra o contexto e os botões de ação.

## O que a pessoa deixa de fazer (P19)
- Configurar automação em seis lugares.
- Conferir à mão se o agendamento, a esteira ou o conector falhou.
- Repetir toda manhã a mesma rotina com os mesmos valores.
- Remontar os mesmos parâmetros.
- Vigiar etapa de esteira parada.

## Testes (rastreados)
- **CA-051-01:** regra de pedido acima de R$ 50 mil cria tarefa para o grupo; recusa ligar sem ensaio; o ensaio
  mostra o efeito sem gravar; aparece na central com dono e histórico.
- **CA-051-02:** a sugestão de agendar com execuções de 4 dias úteis; aceitar cria a variante e o agendamento;
  recusada, não volta.
- **CA-051-03:** regra cuja ação cria o mesmo documento é bloqueada e desligada, com aviso; o limite por janela também.
- **CA-051-04:** a central lista agendamentos, esteiras, processos, regras e alertas com a última execução e as
  falhas.
- **RF-051-04:** o catálogo inteiro passa no teste de automatizável.
- **RF-051-05:** a etapa automática que falha vira tarefa com contexto e se conclui sozinha ao ser resolvida.
- **T-045-07b:** a sugestão de salvar como variante depois de três usos iguais.
- **Escrita:** sem regra ligada, criar um pedido não grava nada no esquema `automation`.
