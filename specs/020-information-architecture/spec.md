# 020 — Arquitetura da informação e experiência de uso

Situação: implementada (RF-020-01..12); organização por áreas e categorias (RF-020-19..23) implementada; padrões de telas de produtividade: barra de tabela e painéis com estado (RF-020-17/18) implementados; RF-020-13..16 a implementar.

## Problema
A interface cresceu por acréscimo: propriedades acima do editor, versões e
execuções misturadas com a saída, administração numa lista longa e plana,
usuários comuns sem um lugar claro para trabalhar. O ANA precisa de uma
interface que **faça sentido para quem a usa** — operador do dia a dia,
desenvolvedor e administrador —, com as coisas relacionadas juntas.

## Princípios
1. **Organizar por tarefa, não por tecnologia.** Cada pessoa vê primeiro o que
   faz todo dia.
2. **Coisas relacionadas juntas.** Tudo sobre um programa fica no programa;
   tudo sobre uma execução fica na execução; tudo sobre uma pessoa fica na
   pessoa.
3. **Um lugar para cada coisa.** Nenhuma função aparece em dois menus com
   comportamentos diferentes.
4. **Descobrível e rápido.** Menus agrupados por módulo para quem está
   aprendendo; barra de comandos e atalhos para quem já sabe.
5. **Fluxo coerente e fluido.** Cada tela leva naturalmente ao próximo passo
   do processo (criar pedido → faturar → acompanhar recebimento), sem obrigar
   o usuário a lembrar onde fica a próxima tarefa.
6. **Contexto visível.** Onde estou, em qual empresa/ambiente, qual programa,
   qual versão, se há alterações não salvas, se algo está rodando.

## Áreas (espaços de trabalho)
| Área | Para quem | Conteúdo |
|------|-----------|----------|
| **Início** | todos | atalhos favoritos, recentes, minhas últimas execuções, avisos |
| **Operação** | operadores (todos) | módulos de negócio (Cadastros, Vendas, Estoque, Projetos, Financeiro, Analítico, …) com as rotinas de cada um; formulário → resultado → histórico |
| **Desenvolvimento** | `developer`+ | Programas (código, propriedades e limites, versões, execuções), Dados (catálogo, console SQL) |
| **Administração** | `admin` | Pessoas e acesso; Sistema; Operação do sistema |

## Requisitos funcionais
- **RF-020-01** Barra superior fixa: marca + empresa, seletor de área (só as
  áreas permitidas ao papel), barra de comandos global (abre rotina,
  programa, tabela ou seção administrativa por nome) e menu do usuário
  (trocar senha, sair).
- **RF-020-02** **Início**: favoritos do usuário (fixar rotina), rotinas
  usadas recentemente, últimas execuções próprias com status e acesso direto
  ao resultado.
- **RF-020-03** **Operação**: navegação lateral por **módulo** (derivado do
  namespace do programa: `sales.*` → Vendas, `projects.*` → Projetos…), listando
  as rotinas permitidas com nome amigável (descrição) e comando. Ao abrir uma
  rotina: título, descrição/documentação, formulário de parâmetros, botão
  Executar, resultado (tabelas, mensagens) e, na mesma tela, o histórico das
  execuções daquela rotina pelo usuário.
- **RF-020-04** **Desenvolvimento → Programa**: cabeçalho com nome, versão,
  estado (não salvo, aviso) e ações (Salvar, Executar, Depurar, Excluir); abas
  do programa: **Código** (editor + painel lateral Executar/Depurar com
  parâmetros, variáveis, pilha e console), **Propriedades e limites**,
  **Versões**, **Execuções** (só deste programa, com detalhe ao lado). O painel
  inferior do Código mostra só o que é da execução em curso: Saída e
  Resultado.
- **RF-020-05** **Desenvolvimento → Dados**: catálogo (esquemas e tabelas) e
  console SQL lado a lado; "consultar" de uma tabela preenche o console.
- **RF-020-06** **Administração** agrupada:
  - *Pessoas e acesso*: Usuários, Grupos de acesso, Limites e cotas;
  - *Sistema*: Empresa, Parâmetros, Contas padrão, Comandos, Sistemas remotos;
  - *Operação do sistema*: Monitor, Consumo, Auditoria.
  Na ficha do usuário: dados, papel, grupos, cota e ações (redefinir senha,
  encerrar sessões, desbloquear) — tudo junto.
- **RF-020-07** Estado e navegação preservados: área/seção/programa abertos
  voltam ao recarregar; endereço da página reflete a localização (`#/dev/
  program/sales.create_order`, `#/ops/projects/projects.log_time`) para
  favoritos do navegador e compartilhamento entre colegas.
- **RF-020-08** Mensagens consistentes: confirmações para ações destrutivas
  com o nome do alvo; erros com código e texto claro; avisos não bloqueantes
  (toast) para sucesso.
- **RF-020-09** Acessibilidade: navegação por teclado em menus e abas,
  rótulos em todos os campos, contraste adequado nos temas claro e escuro.

- **RF-020-10** Próxima ação sugerida: o resultado de uma rotina oferece as
  ações seguintes do processo com o contexto já preenchido (ex.: após
  `sales.create_order`, botão "Faturar este pedido" abrindo `sales.invoice_order`
  com o número). Programas declaram isso em `NEXT = [{"program": ...,
  "label": ..., "params": {"campo": "{{result.campo}}"}}]`.
- **RF-020-11** Fluxos guiados por processo: sequências de rotinas com etapas
  visíveis (ex.: "Venda": cadastrar cliente → pedido → faturar → receber;
  "Projeto": proposta → aprovação → execução → medição → faturamento),
  mostrando onde o caso está e o que falta.
- **RF-020-12** Continuidade: listas e detalhes ligados entre si (clicar num
  pedido no histórico abre o pedido; do pedido chega-se ao título e ao
  lançamento), e voltar preserva filtros e posição.

## Requisitos não funcionais
- **RNF-020-01** Sem dependências externas (mantém RNF-005-01) e conteúdo
  dinâmico sempre via `textContent`.
- **RNF-020-02** Layout estável: nenhum painel colapsa por elementos
  opcionais (mantém RNF-011-05); funciona de 1280 px a celular (operador).
- **RNF-020-03** Abrir uma rotina ou programa em < 300 ms com dados em cache.

## Critérios de aceite
- **CA-020-01** Usuário `user` entra e cai em Início/Operação, vê só as rotinas
  permitidas agrupadas por módulo, executa uma e vê o resultado e o histórico na
  mesma tela; não vê Desenvolvimento nem Administração.
- **CA-020-02** No programa, Versões e Execuções são abas do próprio programa;
  o painel inferior mostra apenas Saída e Resultado.
- **CA-020-03** Administração mostra três grupos de seções; a ficha do usuário
  reúne grupos, cota e ações de senha/sessão.
- **CA-020-04** Recarregar a página volta para a mesma área e item (endereço
  com `#/…`).
- **CA-020-05** Fixar uma rotina a coloca nos favoritos do Início.
- **CA-020-06** Após criar um pedido, a tela oferece "Faturar este pedido" e,
  ao clicar, abre o faturamento com o número preenchido.
- **CA-020-07** O fluxo "Venda" mostra as etapas e destaca a etapa atual de um
  pedido escolhido.

## Notas da implementação (T-020-07, 09..11)
- `NEXT` é declarativo: `{{result.campo}}` e `{{params.campo}}` preenchem os
  parâmetros, o rótulo e a confirmação; ação sem valor (ou com `when` falso)
  não aparece; só o programa da tela mostra os seus (chamadas aninhadas não).
  `ana.actions` continua para os casos dinâmicos.
- `flows.guide` calcula as etapas pelos fatos do próprio documento (as mesmas
  regras das esteiras), com a esteira ligada ou não; `ana.steps` desenha as
  etapas (`aria-current="step"` na atual). O documento e o pedido levam a ele.
- Acessibilidade: tokens de cor auditados nos dois temas (texto 4,5:1, partes
  da interface 3:1; borda dos campos escurecida; `--on-ok`); um só ponto
  (`AnaUI.enhance`) dá papéis e setas às abas, foco e Enter às árvores e nome
  acessível aos campos sem rótulo, também no que é desenhado depois.
- Voltar devolve a rolagem da tela de onde se saiu.

## Padrões de telas de produtividade (out/2026)
Referência de usabilidade pedida pelo dono do produto: telas de planejamento e
definição de conjuntos de ERPs de mercado (definição de um conjunto por
critérios com a simulação ao lado; grade de planejamento por período com
gráfico de consumo). O ANA adota os **padrões de uso**, com nomes e desenho
próprios (sem nomenclatura de terceiros). Valem para todo o ERP; cada um é um
componente único, usado por todas as telas que precisarem dele.

- **RF-020-13 Definição com simulação ao lado.** Quem define algo que
  seleciona registros (regras do extrato, condições das esteiras, escopo de
  dados dos grupos, regras de rateio, reposição de estoque, público de uma
  campanha…) edita à esquerda e vê à direita, **sem salvar**, o resultado:
  "Simular" mostra a tabela dos registros que a definição pega (contagem no
  título, busca, colunas da entidade, chave clicável que abre o documento),
  com data e hora da simulação. Salvar é um passo separado. Painéis
  redimensionáveis e recolhíveis (o da simulação pode ocupar a tela).
- **RF-020-14 Construtor de condições padronizado.** Linhas "campo ·
  operador · valor", com o valor por ajuda de valores (a mesma busca dos
  cadastros, spec 040) e operadores do tipo do campo (é, não é, entre,
  contém, maior que…); adicionar e remover linha ao lado de cada uma;
  vários **critérios** (abas "Critério 1, 2…"): dentro de um critério as
  linhas valem juntas (E), entre critérios basta um (OU); **condições de
  exclusão** separadas ("exceto…"). O resultado vira a regra restrita já
  usada pelas esteiras e pelo BPM (nunca código); o texto da regra aparece em
  português ("Filial é AK01 ou AK02, exceto cliente bloqueado").
- **RF-020-15 Grade de planejamento por período.** Linhas = combinações de
  dimensões (ex.: canal × região, centro de custo × conta, item × depósito),
  com as colunas de dimensões **fixas à esquerda** e ajuda de valores nas
  células; colunas de **períodos** geradas pelo intervalo escolhido (mês,
  semana) com rolagem horizontal; colunas de situação e comentário; edição
  em linha com validação (números no formato brasileiro, negativos
  recusados onde não cabem); seleção de linhas para ações em lote (incluir,
  copiar, mudar situação, excluir); totais por período e por linha; colar um
  bloco vindo de planilha; exportar e importar planilha; salvar grava só o
  que mudou (com aviso de alterações não salvas e controle de edição
  concorrente).
- **RF-020-16 Gráfico ligado à grade.** Abaixo da grade, o gráfico da linha
  selecionada (ou da soma da seleção): por período, **planejado × consumido
  × disponível**, com o disponível negativo destacado (cor de alerta e
  rótulo), legenda e dica ao passar o mouse; **um só eixo** (as séries têm a
  mesma unidade — regra do guia de gráficos do ANA: nunca dois eixos);
  alternar gráfico/tabela, ampliar e tela cheia; seguir a seleção sem
  recarregar a tela.
- **RF-020-17 Barra da tabela padronizada.** Toda tabela de trabalho tem:
  título com contagem, busca, filtros por coluna, escolha e ordem das colunas
  e ordenação **lembradas por usuário** (variantes com nome, uma padrão),
  exportar planilha e ações sobre a seleção; o mesmo componente na Operação,
  nos Cadastros e na Administração.
- **RF-020-18 Cabeçalho e painéis com estado.** Cabeçalho da tela fixável
  (filtros e intervalo sempre à vista ao rolar), painéis com divisor
  arrastável e botão de recolher; a posição dos divisores e o cabeçalho
  fixado ficam lembrados por tela e usuário.

Decisões de implementação (RF-020-17/18): o estado deixado na tela (colunas, ordem,
ordenação, filtros; divisores, painéis recolhidos, cabeçalho fixado) fica **no
servidor, por usuário** — volta em qualquer computador; variantes são retratos
com nome desse estado (até 30 por tela, uma padrão). Filtro por coluna aceita
`texto` (contém), `=texto`, `!texto`, `>10`, `<=5`, `10..20`; números no formato
brasileiro. A tabela desenha 2000 linhas por vez ("Mostrar todas"); busca,
filtro e exportação valem para todas.

### Onde o ANA usa esses padrões primeiro
- Grade de planejamento + gráfico: orçamento por centro de custo × conta
  (spec 027, orçado × realizado × saldo), previsão de vendas e produção por
  item × semana (spec 014, previsto × consumido), alocação de horas por
  pessoa × semana (spec 021, planejado × apontado × disponível) e cotas de
  venda por canal × região (planejado × vendido × disponível).
- Definição + simulação: regras do extrato (quais linhas a regra pega),
  condições das esteiras e do BPM (quais documentos entrariam), escopo de
  dados dos grupos (o que o membro passaria a ver), regras de rateio (quanto
  iria a cada centro) e regras de reposição.

### Critérios de aceite (RF-020-13..18)
- **CA-020-08** Ao editar uma regra do extrato, "Simular" mostra as linhas
  abertas que ela pegaria, com contagem, sem gravar nada; salvar grava a
  regra.
- **CA-020-09** Duas linhas no critério 1 (E), um critério 2 (OU) e uma
  exclusão produzem a regra restrita equivalente e o texto em português; a
  mesma regra roda na esteira.
- **CA-020-10** No orçamento, escolher o intervalo gera as colunas de meses;
  editar células, colar um bloco da planilha e salvar grava só as mudadas; o
  total por mês acompanha a edição.
- **CA-020-11** Selecionar uma linha da grade mostra o gráfico planejado ×
  consumido × disponível dessa linha, com o disponível negativo em
  destaque, em um só eixo.
- **CA-020-12** Colunas escolhidas, ordem e uma variante salva voltam ao
  reabrir a tela; o divisor dos painéis volta à posição deixada.

## Organização das rotinas por áreas e categorias (out/2026)
Hoje a Operação mostra todas as rotinas numa grade só, com o módulo técnico
como rótulo, e os favoritos do Início são uma lista sem divisão. Quem usa o
ERP pensa por **área do negócio** e pelo **próprio trabalho** ("fechamento do
mês", "rotina da expedição") — e cada empresa e cada pessoa organiza isso do
seu jeito.

- **RF-020-19 Áreas do negócio e categorias do produto.** A Operação agrupa
  as rotinas por **área do negócio** (Vendas, Compras, Estoque, Produção,
  Logística e campo, Projetos, Financeiro, Contabilidade, Cadastros,
  Processos, Analítico, Integrações) e, dentro de cada área, por
  **categoria** (ex.: Financeiro → Contas a receber, Conciliação bancária,
  Contabilidade, Fechamento). Cada programa do produto declara área e
  categoria no cabeçalho (`# ana:category Financeiro/Conciliação bancária`);
  sem declaração, vale a área do namespace. Nenhum rótulo técnico aparece
  ("bpm", "master"): sempre o nome da área.
- **RF-020-20 Categorias criadas pela empresa e pela pessoa.** Qualquer
  usuário cria **categorias pessoais** (só ele vê); o administrador — ou quem
  tiver a permissão — cria **categorias da empresa**, visíveis a todos ou a
  grupos de acesso escolhidos. Categorias podem ser renomeadas, reordenadas
  (arrastar), recolhidas e excluídas (excluir a categoria nunca exclui a
  rotina).
- **RF-020-21 Copiar rotinas para uma categoria.** Na grade da Operação (e
  na lista lateral) o operador **seleciona uma ou mais rotinas** e escolhe
  "Copiar para categoria…" — uma existente ou uma nova criada ali mesmo.
  Copiar cria um **atalho**: a rotina continua uma só (mesma versão,
  permissões e histórico) e passa a aparecer também na categoria; o mesmo
  atalho pode estar em várias categorias. Opcionalmente o atalho guarda
  **parâmetros pré-preenchidos** e um nome próprio ("Faturar pedidos da
  filial SP"), abrindo a rotina com eles.
- **RF-020-22 Favoritos por categoria no Início.** Os favoritos do Início se
  organizam nas mesmas categorias (pessoais e da empresa): ☆ fixa em
  "Favoritas" com um clique e, ao lado, "Copiar para categoria…" leva a
  rotina a qualquer outra categoria; a tela de Início mostra as
  categorias como seções recolhíveis, com arrastar para reordenar e mover
  atalhos entre elas, e o mesmo "Copiar para categoria…" com seleção de
  várias.
- **RF-020-23 Nunca mostra o que a pessoa não pode usar.** Uma categoria da
  empresa só exibe as rotinas que o usuário pode executar (papel, grupos de
  acesso, licença — spec 009); uma rotina desativada ou excluída some do
  atalho com aviso discreto; a busca do topo ("Ir para…") encontra também os
  atalhos pelo nome dado.

### Critérios de aceite (RF-020-19..23)
- **CA-020-13** A Operação abre agrupada por área do negócio e categoria; o
  rótulo de cada rotina é o nome da área (nenhum "bpm" ou "master").
- **CA-020-14** O operador seleciona três rotinas, escolhe "Copiar para
  categoria…", cria "Fechamento do mês" e as três aparecem lá, continuando
  nas áreas de origem; remover a categoria não remove as rotinas.
- **CA-020-15** O administrador cria a categoria da empresa "Expedição" para
  o grupo da logística: quem é do grupo a vê; quem não é, não; uma rotina
  sem permissão para o usuário não aparece nela.
- **CA-020-16** No Início, uma rotina copiada para uma categoria aparece nela; arrastar
  muda a ordem e move entre categorias; a ordem volta ao recarregar.
- **CA-020-17** Um atalho com parâmetros pré-preenchidos e nome próprio abre
  a rotina com esses parâmetros e é encontrado pela busca do topo.
