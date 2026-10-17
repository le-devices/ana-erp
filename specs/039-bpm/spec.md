# 039 — BPM: modelar, simular, executar e acompanhar os processos da empresa

## Problema
O dono do produto quer gestão de processos de negócio (BPM) como recurso de
**primeira classe** do ERP: ajudar a empresa a **desenhar** como trabalha,
**simular** antes de mudar (gargalos, prazos, custo, pessoas necessárias),
**executar** o processo desenhado dentro do ERP e **acompanhar** como ele
realmente acontece. Os requisitos são alta usabilidade, flexibilidade e ótimo
acabamento.

Hoje existem peças soltas:
- as esteiras (spec 030): catálogo fixo de etapas lineares;
- as aprovações (spec 024);
- o agendamento (spec 018);
- os eventos dos documentos.

Falta o modelo do processo em si, com desenho, versões, ramificações,
tarefas humanas, prazos, papéis, simulação e medição.

## Princípios
- **Um modelo, três usos**: o mesmo desenho serve para documentar, simular e
  executar. Não há um modelo de documentação e outro de automação.
- **Nada solto (P17)**: tarefas automáticas são programas do ERP; esperas
  são fatos do ERP (pedido faturado, título pago, OS concluída); tarefas
  humanas abrem a tela do programa certo com os dados preenchidos.
- **Notação aberta**: elementos com o significado da BPMN 2.0, norma aberta
  da OMG. É possível importar e exportar o XML BPMN 2.0, para levar
  processos de e para outras ferramentas.
- **Para quem conhece o negócio, não só para TI**: modelos prontos,
  validação enquanto se desenha, linguagem simples, e nenhum código para os
  casos comuns.

## Histórias
- **H1** Como dono ou gestor, vejo o mapa dos processos da empresa
  (macroprocessos → processos → subprocessos), com dono, objetivo,
  indicadores e situação de cada um.
- **H2** Como analista de processos, desenho um processo arrastando
  elementos para raias (papéis, grupos ou áreas), com validação na hora,
  desfazer e refazer, zoom, minimapa e alinhamento automático.
- **H3** Começo de um modelo pronto do produto, por exemplo "Do pedido ao
  recebimento", "Da compra ao pagamento", "Atendimento em campo",
  "Projeto de P&D com protótipo" ou "Contratação". Também posso partir das
  esteiras que já existem.
- **H4** Simulo o processo antes de mudar: chegadas por dia, duração e
  probabilidade de cada caminho, pessoas por papel, custo por hora e
  calendário. Vejo prazo médio e de 90 % dos casos, filas, gargalos, uso das
  pessoas, custo por caso e casos concluídos por semana. Comparo cenários
  ("e se eu automatizar a aprovação?", "e se contratar mais um técnico?").
- **H5** Calibro a simulação com a realidade: durações, caminhos e
  volumes medidos nas execuções e nos documentos do próprio ERP.
- **H6** Publico uma versão e o ERP passa a executar o processo:
  - as tarefas humanas aparecem na lista "Minhas tarefas" de quem tem o
    papel, com prazo, prioridade e o formulário certo;
  - as tarefas automáticas rodam sozinhas;
  - os caminhos seguem as regras;
  - os prazos vencidos escalam.
- **H7** Acompanho cada caso: onde está, quem fez o quê, quanto tempo levou,
  o que está atrasado. O diagrama mostra, sobre cada elemento, volume, tempo
  médio e atrasos (mapa de calor).
- **H8** Descubro o processo real pelos dados: o caminho que os casos
  efetivamente seguiram, os desvios do modelo e os retrabalhos.
- **H9** Como auditor, vejo versões, quem publicou, o que mudou entre elas
  (comparação visual) e a trilha de cada caso.

## Requisitos funcionais

### Mapa e modelagem
- **RF-039-01** Catálogo de processos em árvore (cadeia de valor →
  processos → subprocessos). Cada processo tem dono, objetivo, gatilho,
  resultado, indicadores (metas de prazo, custo e qualidade), documentos
  relacionados, programas e tags.
- **RF-039-02** Editor visual no Estúdio, sem bibliotecas externas.
  - Elementos com significado BPMN:
    - eventos: início, fim, tempo, mensagem/fato do ERP e erro;
    - tarefas: humana, automática (programa), aprovação, envio (mensagem ao
      cliente ou fornecedor) e regra de decisão;
    - gateways: exclusivo, paralelo e inclusivo;
    - subprocesso (chama outro processo);
    - raias e anotações.
  - Ergonomia: arrastar e soltar, conexões inteligentes, alinhamento e
    distribuição, layout automático, desfazer e refazer, copiar e colar,
    teclado completo, zoom e minimapa.
  - Funciona com os temas claro e escuro e é legível no celular (no celular,
    só leitura).
- **RF-039-03** Validação enquanto se desenha, com a mensagem ao lado do
  elemento:
  - início e fim alcançáveis;
  - gateway sem saída padrão;
  - tarefa sem responsável;
  - programa inexistente ou sem permissão;
  - laço sem saída.

  Um processo com erro pode ser salvo como rascunho, mas não pode ser
  publicado.
- **RF-039-04** Propriedades por elemento, em painel lateral:
  - tarefa humana: papel ou grupo, programa ou formulário, campos
    preenchidos a partir dos dados do caso, prazo (SLA) e escalonamento,
    instruções;
  - tarefa automática: programa, parâmetros e novas tentativas;
  - fluxo: condição escrita com o construtor visual (campo, operador,
    valor), sem código;
  - evento de fato do ERP: qual fato (ex.: "título do documento pago");
  - simulação: duração (fixa, uniforme, triangular ou exponencial),
    probabilidade de cada saída e custo.
- **RF-039-05** Dados do caso: variáveis do processo, com tipos e campos
  como os PARAMS. Tarefas leem e gravam essas variáveis, e o documento do
  ERP fica ligado ao caso (pedido, OS, projeto…).
- **RF-039-06** Versões:
  - rascunho → publicada → aposentada;
  - comparação visual entre versões;
  - casos em andamento seguem a versão em que começaram; migrar casos é uma
    ação explícita, com verificação.
- **RF-039-07** Modelos prontos do produto (P13), entre eles: "Do pedido ao
  recebimento", "Da compra ao pagamento", "Atendimento em campo",
  "Produção", "Projeto de P&D com protótipo" e "Fechamento do mês".
  - As esteiras da spec 030 viram processos do catálogo e passam a ser
    executadas pelo motor BPM, com compatibilidade.
  - Importação e exportação de XML BPMN 2.0 (elementos suportados; o que
    não for suportado é avisado, nunca descartado em silêncio).

### Simulação
- **RF-039-08** Simulador de eventos discretos.
  - Entradas: chegadas (por dia ou por hora, com sazonalidade), durações e
    probabilidades por elemento, pessoas por papel com calendário (turnos,
    feriados da spec 018), custo por hora, custo fixo por tarefa e duração
    da simulação; várias repetições, com semente para reproduzir.
  - Saídas:
    - por caso: prazo médio, P50 e P90, custo e vazão;
    - por elemento: fila, espera e utilização;
    - por papel: utilização e horas extras necessárias;
    - gargalo apontado.
  - Animação dos casos no diagrama durante a simulação.
- **RF-039-09** Cenários: copiar o cenário base, mudar parâmetros (pessoas,
  durações, automatizar uma tarefa, mudar uma regra) e comparar lado a lado,
  com a diferença em prazo, custo e vazão.
- **RF-039-10** Calibração pela realidade: preencher durações, probabilidades
  e chegadas a partir das execuções (BPM e esteiras) e das datas dos
  documentos, em um período escolhido, mostrando a qualidade da amostra.

### Execução
- **RF-039-11** Motor de processos. Ele é a evolução do motor de esteiras,
  roda no líder e com caixa de saída (spec 017).
  - Cada caso tem tokens que percorrem o modelo.
  - Tarefas automáticas viram execuções de programas em nome do dono
    configurado (P14).
  - Gateways avaliam as condições sobre os dados do caso.
  - Gateways paralelos esperam todos os ramos; inclusivos esperam os ramos
    ativados.
  - Eventos de tempo usam o agendamento; eventos de fato reagem a NOTIFY e à
    verificação periódica.
  - Erro de negócio segue o caminho de erro do modelo, se houver; sem
    caminho, o caso para com o motivo. Falha técnica tem novas tentativas.
- **RF-039-12** Lista de tarefas ("Minhas tarefas", na área Início):
  - o que é meu e o que é do meu papel ou grupo (pegar e devolver);
  - prazo e prioridade, filtros e busca;
  - abrir a tarefa leva ao formulário ou programa com os dados do caso;
  - concluir avança o caso;
  - delegar, pedir ajuda e comentar.

  Avisos de tarefa nova e de atraso, por notificação no ERP e por e-mail
  pelo conector (spec 017).
- **RF-039-13** Prazos (SLA): tempo útil pelo calendário, alerta antes do
  vencimento e escalonamento após (para o gestor do papel, reatribuição ou
  caminho alternativo do modelo).
- **RF-039-14** Painel do caso: diagrama com o caminho percorrido e o ponto
  atual, linha do tempo (quem, quando, quanto tempo), dados, documentos
  ligados e ações permitidas (reprocessar, pular com justificativa, cancelar
  o caso).

### Acompanhamento e descoberta
- **RF-039-15** Painel do processo:
  - casos abertos, concluídos e atrasados;
  - prazo médio e P90 contra a meta, custo por caso e vazão;
  - mapa de calor no diagrama (volume, tempo e atraso por elemento);
  - tendência por semana.
- **RF-039-16** Descoberta e conformidade:
  - a partir dos eventos dos casos e dos documentos, desenha o fluxo real
    (variantes mais frequentes) e marca desvios em relação ao modelo
    publicado (etapas puladas, retrabalho, ordem trocada);
  - "transformar em modelo" cria um rascunho a partir do fluxo descoberto.

## Requisitos não funcionais
- **RNF-039-01 Usabilidade (requisito do dono):**
  - Qualquer gestor desenha um processo de 10 etapas em menos de 10 minutos
    partindo de um modelo pronto.
  - Nenhum termo técnico obrigatório na tela.
  - Tudo tem teclado, foco visível e leitores de tela (rótulos nos
    elementos).
  - Resposta do editor em menos de 16 ms por interação com 300 elementos.
- **RNF-039-02 Acabamento:**
  - Visual coerente com o Estúdio (ícones próprios, temas claro e escuro).
  - Diagramas exportáveis em SVG, PNG e PDF para documentação.
  - Impressão do mapa de processos.
- **RNF-039-03 Desempenho:**
  - Motor com 10 mil casos ativos e 100 avanços/s por nó, sem bloquear a
    operação.
  - Simulação de 1 ano com 50 mil casos em menos de 10 s, no processo
    isolado do Python, com limites (spec 007).
- **RNF-039-04 Robustez:**
  - Avanço idempotente: o mesmo evento aplicado duas vezes avança uma vez.
  - Queda de nó não perde nem duplica tarefa, graças ao líder com lease
    (como nas esteiras).
  - Modelo publicado é imutável.
- **RNF-039-05 Segurança:**
  - Desenhar exige o papel de desenvolvedor ou o grupo "processos"; publicar
    exige administrador ou dono do processo.
  - A tarefa humana só aparece para quem tem o papel e passa pelas
    permissões do programa.
  - Condições sem código arbitrário: o construtor gera uma expressão
    restrita, avaliada sem `eval`.
- **RNF-039-06 Rastreabilidade (spec 024):** versões, publicações e cada
  avanço de caso entram na trilha, com retenção configurável.

## Critérios de aceite
- **CA-039-01** Desenhar, a partir do modelo "Da compra ao pagamento", um
  processo com aprovação por alçada (gateway por valor), validar e publicar;
  uma solicitação real percorre o processo até o pagamento.
- **CA-039-02** A tarefa humana aparece em "Minhas tarefas" só para o papel
  certo; concluí-la avança o caso; o prazo vencido escala para o gestor.
- **CA-039-03** O gateway paralelo espera os dois ramos; o exclusivo segue a
  condição; sem condição verdadeira, segue a saída padrão.
- **CA-039-04** Simular "Atendimento em campo" com 2 técnicos e depois com
  3 mostra a queda do prazo P90 e o aumento do custo. Com a mesma semente, o
  resultado se repete.
- **CA-039-05** A calibração preenche durações e probabilidades a partir dos
  casos reais, e a simulação calibrada reproduz o prazo médio real com
  diferença de até 15 %.
- **CA-039-06** Exportar e reimportar BPMN 2.0 preserva os elementos
  suportados e avisa o que não é suportado.
- **CA-039-07** As esteiras existentes rodam como processos, sem mudança de
  comportamento (suítes da spec 030 verdes).
- **CA-039-08** A descoberta mostra as variantes reais e marca os casos que
  pularam uma etapa do modelo.

## Fases
1. **Fundação:** catálogo, editor, validação, versões, modelos prontos,
   importação e exportação BPMN (RF-01 a RF-07).
2. **Simulação:** simulador, cenários e calibração (RF-08 a RF-10).
3. **Execução:** motor, tarefas, prazos e painel do caso, com as esteiras
   migradas (RF-11 a RF-14).
4. **Acompanhamento:** painel do processo, mapa de calor, descoberta e
   conformidade (RF-15 e RF-16).

## Decisões propostas (a confirmar com o dono do produto)
- **Editor próprio em SVG**, sem biblioteca externa (regra da interface,
  spec 020). É mais trabalho, mas garante acabamento, segurança (CSP
  estrita) e controle.
- **Simulador em Python**, dentro do ERP, nas mesmas execuções isoladas com
  limites. Assim, o próprio cliente pode estender distribuições e métricas.
- **As esteiras viram processos** de um único motor, em vez de manter os
  dois motores.

## Situação (implementação, outubro/2026)
Implementadas as quatro fases. Ficam pendentes T-039-16b e T-039-17b.

Decisões do dono (confirmadas): editor próprio em SVG, sem biblioteca externa;
simulador em Python dentro do ERP; esteiras executadas pelo mesmo motor.

Como ficou:
- **Motor único (`ana_bpm`).**
  - Roda no líder, com um executor só para casos BPM e para as esteiras:
    capacidade, lease, novas tentativas em falha técnica e varredura de fatos.
    `ana_flows` virou biblioteca do motor.
  - As esteiras continuam guardando a execução em `flow.*`, compatíveis com
    as telas e os testes da spec 030. No catálogo, aparecem como processos
    (somente leitura), com painel, calibração e descoberta.
- **Navegação num único lugar**, sob trava do caso (`ana_bpm_model`). Telas
  e programas apenas concluem tarefas.
- **Junções paralelas e inclusivas** esperam enquanto houver outro ponto
  ativo do caso capaz de alcançá-las (alcançabilidade calculada na
  publicação). Funciona também quando uma decisão anterior desviou um ramo.
- **Fatos do ERP** (`bpm.fact`, gerados das etapas das esteiras) completam
  tarefas "concluída quando" e esperas. Documentos seguidos: pedido,
  solicitação de compra, OS, ordem de produção e projeto, além do processo
  avulso.
- **Prazos em horas úteis** (seg–sex, 08–12 e 13–18, sem feriados do
  agendamento), com aviso antes do vencimento e escalonamento depois: avisar,
  passar a tarefa ou seguir o caminho de atraso.
- **Simulação de eventos discretos.** Os casos chegam aleatoriamente ao longo
  do tempo; pessoas por raia atendem em fila; repetições com semente; gargalo
  apontado; animação.
  - Na calibração, as durações medidas viram distribuição empírica e o tempo
    é de calendário: a simulação reproduz o prazo médio real.
- **BPMN 2.0** com o diagrama (BPMNDI). O que é próprio do ANA viaja em
  atributos `ana:*`. DOCTYPE/ENTITY é recusado por segurança.
- **Varredura** a cada `ANA_BPM_SWEEP_MS`: 30 s em produção, 5 s no
  ambiente de desenvolvimento.
