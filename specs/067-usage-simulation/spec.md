# 067 — Uso simulado contínuo: usuários sintéticos percorrendo esteiras inteiras

Situação: fase 1 implementada (nov/2026), a pedido do dono do produto em 21/11/2026: personas robô percorrendo esteiras inteiras pela API com semente, erros humanos, oráculos de automação e de contas, relatório com tendência, rotina agendada fora da produção e workflow noturno no GitHub Actions com uma issue por achado. Fase 2 (telas, perfil real, trilhas) depois da 050 fase 3.

## Problema
Há defeitos que só aparecem usando o ERP com frequência, como gente de verdade: o passo de uma esteira que não dispara
o seguinte quando o pedido é parcial, o documento que fica no limbo depois de uma devolução, a conciliação que só fecha
quando nada é cancelado, a tela que pede cinco cliques para algo diário, o aviso que nunca chega, a lentidão que cresce
com o volume de um mês. As trilhas de processo (spec 042) seguem roteiros fixos; a regressão antes de atualizar (spec
053) repete o que o cliente gravou. Falta **uso contínuo e variado**, que ninguém roteirizou, procurando furos de
usabilidade e de automação — todo dia, sem gente.

## Decisões
- **D1 — Personas com acesso real.** Perfis de uso simulados — vendedor, comprador, almoxarife, financeiro, técnico de
  campo, gestor de projeto, aprovador, cliente no portal — cada um como **usuário robô** com papel e grupos de verdade
  (spec 011): esbarra nas mesmas permissões, escopos de dados e quatro olhos que uma pessoa. Cada persona tem um
  **dia de trabalho**: o que faz, com que frequência, e uma taxa de "erros humanos" (digitar errado, desistir no meio,
  cancelar, voltar, repetir).
- **D2 — Esteiras inteiras, com variação.** Cenários de ponta a ponta sobre as esteiras (spec 030) e os processos BPM
  (spec 039): venda (pedido → atendimento → compra ou produção → recebimento → expedição → fatura → cobrança → baixa →
  conciliação), serviço em campo, projeto (horas → aprovação → fatura), compras com alçada, fechamento do mês. Com
  variação gerada — itens, quantidades, clientes, entregas parciais, atrasos, cancelamentos, devoluções, condições de
  pagamento, filiais — por **semente registrada**: todo achado se reproduz.
- **D3 — Pelas mesmas portas que as pessoas.** Rotinas pela API e telas pelo Estúdio num navegador sem tela, com as
  variantes (spec 045), a paleta (spec 050), o assistente (spec 052, onde ligado) e o ensaio (spec 056). Assim mede-se a
  usabilidade de verdade: passos e cliques até concluir uma tarefa, telas visitadas, mensagens de erro vistas, estados
  vazios sem ação, próxima ação ausente (spec 020), tempo de tela acima do orçamento (spec 050).
- **D4 — Oráculos: o que é um furo.** Verificados durante e ao fim de cada simulação:
  - *automação*: esteira parada (passo concluído sem o seguinte disparar no prazo), documento sem estado final depois do
    prazo (limbo), tarefa de processo sem dono, agendamento que não rodou, mensagem de conector esgotada, aviso não
    entregue;
  - *contas*: conciliações de controle diferentes de zero (spec 042), título sem lançamento, saldo de estoque negativo,
    custo sem origem;
  - *usabilidade*: tarefa diária acima do número de passos de referência, erro sem orientação (spec 050), tela sem
    próxima ação, desistências por persona;
  - *desempenho e robustez*: tela ou rotina acima do orçamento, piora com o volume acumulado, erro novo (grupos de
    erro, spec 046), escrita de disco acima do orçamento (spec 063).
- **D5 — Só fora da produção.** Roda na instância de testes (spec 034), sobre cópia mascarada ou dados sintéticos;
  chamadas externas bloqueadas e efeitos retidos; nunca na produção (recusado). Dias de trabalho comprimidos: onde a
  rotina aceita data, a simulação passa a data simulada; o que depende do relógio do sistema é verificado pelo prazo
  real.
- **D6 — Periódica e com relatório.** Uma **rotina agendada** (spec 018) roda a simulação — por padrão toda noite, com
  duração e carga limitadas (para não competir com quem testa de dia). O relatório traz os achados por categoria, cada
  um com a semente, a persona, a sequência de passos, os documentos e as execuções ligadas, e a tendência entre
  simulações (novo, persistente, resolvido). Achado novo vira aviso ao responsável e, se for de um programa, achado da
  tela Qualidade (spec 064).
- **D6a — No desenvolvimento do produto: GitHub Actions agendado** (decisão do dono do produto em 21/11/2026). Um
  workflow com `schedule` (cron, toda noite) sobe a pilha num executor padrão — gratuito para o repositório público —,
  carrega dados de demonstração e **sintéticos**, roda a simulação dentro do tempo do executor (até 6 horas por job) e:
  - publica o relatório como artefato da execução e como resumo do job;
  - abre (ou atualiza) uma *issue* por achado novo, com a semente e os passos para reproduzir, e fecha a do achado
    resolvido;
  - pode ser disparado à mão com uma semente (reproduzir um achado) e em pull requests para `qa`/`master`.
  Como o repositório é público, **logs, artefatos e issues são públicos**: só dados sintéticos e de demonstração, nunca
  cópia de dados de cliente, nunca segredo. A máquina de desenvolvimento não precisa ficar ligada.
  Nas instalações dos clientes, a mesma simulação roda como rotina agendada da instância de testes (D6), com a cópia
  mascarada deles — lá os dados não saem da casa do cliente.
- **D7 — Parecida com o uso real.** As frequências das personas podem vir do **perfil de uso da produção** (quantas
  vezes cada rotina, área e esteira roda por dia), agregado e sem dados pessoais (P14), para a simulação exercitar o
  que a empresa de fato faz — e também o que quase nunca faz (cauda).
- **D8 — Aproveitar o que achar.** Um cenário que encontrou um furo vira, com um clique, trilha de regressão (spec 053)
  — o furo consertado nunca volta sem ser visto; os furos de automação alimentam as sugestões de automação (spec 051).

## Requisitos funcionais
- **RF-067-01** Personas (D1): usuários robô com papel e grupos, dia de trabalho, frequências e taxa de erro;
  cadastro e edição na Administração.
- **RF-067-02** Gerador de cenários das esteiras e processos com variação e semente reproduzível (D2).
- **RF-067-03** Executor pelas rotinas (API) e pelas telas (navegador sem tela), com medida de passos, cliques, telas,
  erros e tempo (D3).
- **RF-067-04** Oráculos de automação, contas, usabilidade, desempenho e robustez (D4), extensíveis por programa da
  instalação.
- **RF-067-05** Rotina agendada com duração e carga limitadas; recusa na produção (D5, D6).
- **RF-067-06** Relatório por simulação e tendência; aviso de achado novo; ligação com a tela Qualidade (D6).
- **RF-067-07** Perfil de uso real agregado da produção para calibrar as personas (D7).
- **RF-067-08** Achado → trilha de regressão (spec 053) e sugestão de automação (spec 051) (D8).
- **RF-067-09** Workflow agendado do GitHub Actions para o produto: pilha com dados sintéticos, simulação, relatório
  como artefato, issue por achado novo e fechamento do resolvido, disparo manual com semente (D6a).

## Requisitos não funcionais
- **RNF-067-01** Nunca roda na produção nem chama sistemas externos (spec 034); dados pessoais nunca saem da produção.
- **RNF-067-02** Reproduzível: a mesma semente, os mesmos dados de partida e a mesma versão dão a mesma sequência.
- **RNF-067-03** Carga limitada (CPU, conexões, escrita de disco — P15) e duração máxima configurável.
- **RNF-067-04** Uma simulação de um "mês" de 8 personas termina numa noite (menos de 4 horas) na instância de testes
  dimensionada como a produção.

## Critérios de aceite
- **CA-067-01** A simulação agendada roda 8 personas por uma semana simulada e entrega o relatório com os achados e a
  tendência.
- **CA-067-02** Uma esteira com um passo automático desligado de propósito aparece como "esteira parada", com o
  documento, o passo e a semente.
- **CA-067-03** Uma tela com estado vazio sem ação, ou uma tarefa diária que exige mais passos que a referência,
  aparece como achado de usabilidade.
- **CA-067-04** Rodar de novo com a semente de um achado reproduz o mesmo achado.
- **CA-067-05** Na produção, a rotina é recusada.
- **CA-067-06** Um achado vira trilha de regressão com um clique, e a trilha falha enquanto o furo não for consertado.
- **CA-067-07** O workflow noturno do repositório roda sem a máquina de desenvolvimento, abre uma issue para um achado
  novo (com semente e passos) e a fecha quando o achado some; nenhum dado que não seja sintético aparece nos logs.

## Relação com outras specs
- **042 (trilhas)**: roteiros fixos com conciliações; aqui, uso variado e contínuo — os oráculos de contas reaproveitam
  as conciliações de controle.
- **053 (regressão do cliente)**: ensaio antes de atualizar; aqui, uso todo dia — os achados viram trilhas da 053.
- **051 (automação por padrão)**: a 067 encontra onde a automação falha ou falta.
- **034 (instância de testes)**, **050** (orçamentos de tela), **056** (ensaio), **063** (disco), **064** (Qualidade).
