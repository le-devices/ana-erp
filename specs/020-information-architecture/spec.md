# 020 — Arquitetura da informação e experiência de uso

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
