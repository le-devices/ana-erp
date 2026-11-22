# 048 — Plano

## Indicadores (T-048-01, D1)
- Um programa é indicador pela linha `# ana:indicator <segundos>` no cabeçalho (coluna `program.indicator_refresh_s`,
  de 60 s a 1 dia): o prazo do cache. Devolve `{"value", "status": ok|warning|critical, "text"}` — número, situação e
  linha curta (`status` sempre vem com texto e ícone na tela, nunca só cor).
- Executa **como o usuário** (P14, permissão, licença e escopo de dados — RNF-048-02) em transação **somente leitura**
  (o banco recusa qualquer gravação) e com tempo máximo de 5 s, mesmo que os limites do programa digam mais.
- Cache em memória em cada nó (`ana_home`, ETS), por usuário e bloco, com o prazo do indicador; nada gravado no disco
  (P15). "Atualizar" pede o valor de novo (no máximo um a cada 10 s por bloco e usuário).
- A tela pede cada indicador separadamente, em paralelo: um lento não atrasa os outros; um que falha mostra
  "indisponível" com o motivo, e o painel continua (CA-048-05).
- Indicadores do produto: pedidos com falta (`sales.indicator_shortages`), títulos a receber vencidos
  (`finance.indicator_overdue`), solicitações de compra aguardando aprovação (`supply.indicator_approvals`).

## Espaços da empresa (T-048-02, D2)
- Migração 071: `ana_system.home_space` (nome, descrição, ordem, grupos de acesso — vazio = todos) e
  `ana_system.home_block` (espaço, ordem, título, rotina que abre, variante e parâmetros, indicador e parâmetros
  dele, tamanho pequeno/médio/largo).
- Cada usuário vê os espaços dos seus grupos; um bloco só aparece se ele pode executar a rotina que o bloco abre, e o
  número só se pode executar o indicador. Administradores editam (Administração → Painel inicial) e veem "como o
  usuário X vê" (mesmas regras aplicadas àquele usuário).
- Espaço do produto: "Visão geral", para todos, com os três indicadores.

## Painel (T-048-03, T-048-06, D3, D6)
- Início: busca no topo (abre a paleta, spec 050), espaços da empresa, e o espaço pessoal com os blocos de antes
  (minhas tarefas, favoritas, categorias, recentes, avisos, execuções — RF-048-07).
- Personalizar: esconder, mover (botões ↑ ↓, por teclado) e mudar o tamanho dos blocos da empresa, por usuário
  (preferências no servidor, `home.layout`); "Restaurar padrão" volta ao da empresa (CA-048-03).
- Bloco abre a rotina com a variante (spec 045) e os parâmetros dele, ou um documento (RF-048-06).
- Grade que se ajusta ao celular; cada bloco é um botão com nome acessível que diz o número e a situação.

## Avisos (T-048-04, D4)
- Centro de avisos no sino do topo: tarefas dos processos, avisos das rotinas agendadas, avisos do sistema (para
  administradores) e aprovações que esperam o usuário (valores da empresa, spec 065) — cada um com contador e link.

## Busca (T-048-05, D5)
- A paleta (spec 050) é a busca global: também títulos (faturas e parcelas) pelo número e as **variantes** das
  rotinas (T-045-07b, parte da paleta e do painel). Busca de cadastros pelos índices de trigramas existentes.
