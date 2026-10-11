# 035 — Plano técnico

- Runtime: em `ana.table`, a chave `_open` de cada linha (`{program,
  params}`) vira `row_open` (ação com `open`), fora das colunas.
- Tela (`ui.js` / `runner.js`): linha com `row_open` é clicável e focável
  (Enter), a primeira célula aparece como link; botões da linha continuam
  independentes. O portal abre o documento com os parâmetros.
- `docs.view` (comando `doc`, portal): pedido de venda, título, OS,
  solicitação e ordem de compra, ordem de produção, expedição,
  transferência, lançamento contábil — cabeçalho, itens, relacionados que
  abrem, próximo passo. Portal: só pedido, título e OS da própria empresa.
- Biblioteca `docs.common`: `link(kind, key)` e leitura de "ORD-12",
  "OS-5", "OP-3", "TR-7", "EXP-9".
- Listas ligadas: Minhas faturas, bancadas de expedição, campo, compras e
  produção, SLA, ordens geradas, faturamento de OS, quadro das esteiras,
  pedido recém-criado.
