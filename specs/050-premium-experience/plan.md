# 050 — Plano

A fase 1 (padrão verificável) está descrita na própria spec, em "Decisões de implementação".

## Fase 2 — recursos transversais (T-050-05..08)

Tudo vale para todas as telas sem que cada uma precise lembrar (P19): a paleta lê o que já existe, o desfazer é
oferecido pelo programa e mostrado pelo Estúdio em qualquer tela, os valores padrão e a câmera vêm da declaração
dos parâmetros. Nenhuma facilidade contorna permissão, licença, auditoria ou validação (RNF-050-03).

### T-050-05 — Paleta de comandos e ajuda de atalhos (RF-050-04, D4, CA-050-02)
- `palette.js`: Ctrl+K (⌘K no Mac) em qualquer tela abre a paleta; setas escolhem, Enter executa, Esc fecha;
  lista com `role=listbox` e `aria-activedescendant` (leitores de tela).
- Fontes, nesta ordem de relevância:
  1. **Ir para**: rotinas, comandos, atalhos das categorias, programas, tabelas e seções da Administração — os
     mesmos alvos da barra "Ir para…" (já filtrados por papel, grupo e licença).
  2. **Nesta tela**: botões e links visíveis e habilitados da tela aberta, pelo nome acessível — toda tela ganha
     as suas ações na paleta sem declarar nada.
  3. **Documentos e cadastros**: programa `base.find` (rodando como o usuário): número de documento ("123",
     "ORD-12", "OC-5"…) → documentos daquele número; CNPJ/CPF (com ou sem pontuação) → cliente ou fornecedor;
     texto → clientes, fornecedores e itens pelo nome ou código. Documentos só para quem pode abrir documentos
     (`ana.can_run("docs.view")`); cadastros só os que o usuário pode ver (`core.can`).
- `ana.can_run(nome)` no runtime: a mesma verificação de papel, grupo e licença da execução.
- CNPJ/CPF só é tratado como documento quando tem a forma de um (sem espaços) e dígitos válidos; sem achado, o
  texto ainda é buscado como nome (um nome com números pode, por acaso, passar nos dígitos do CNPJ alfanumérico).
- Na paleta vazia, as ações do conteúdo da tela vêm antes das do menu da área.
- Tecla `?` (fora de campo de texto) ou "Atalhos do teclado" na paleta: lista os atalhos globais (Ctrl+K, F3,
  F8, F9, Esc, ?) e os da tela, lidos de `aria-keyshortcuts` dos elementos visíveis. Os botões com atalho
  (Executar F8, Simular/Ensaiar F9, Voltar F3, Novo N) passam a declará-lo.
- "Perguntar ao assistente" entra na paleta com a spec 052 (T-065-11b e a 052 usam a mesma paleta).

### T-050-06 — Desfazer padronizado e confirmação com consequência (RF-050-05, D5, CA-050-03)
- Migração 070: `ana_system.undo_offer` (id, execução, usuário, rotina, rotina que desfaz, parâmetros, texto,
  criado, vale até, usado em, execução do desfazer). Retenção: ofertas vencidas há mais de 30 dias são apagadas.
- `ana.offer_undo(programa, params, label, seconds=30)`: só a rotina principal oferece; a rotina que desfaz
  precisa existir e o usuário precisa poder executá-la; nada é oferecido em simulação, ensaio, depuração sem
  gravar ou licença somente consulta. A oferta é gravada logo depois do COMMIT do que ela desfaz, pelo próprio
  núcleo (os programas nunca escrevem em `ana_system`; não há oferta de algo que não foi gravado) e volta na
  resposta (`undo: {id, label, seconds}`).
- `POST /api/undo/:id`: só o próprio usuário, uma vez, dentro do prazo; a oferta é tomada antes de executar
  (dois cliques não desfazem duas vezes) e devolvida se o desfazer falhar. A rotina que desfaz roda como uma
  execução comum (permissão, auditoria, validação); os parâmetros vêm do servidor, nunca da tela.
- Estúdio: qualquer execução que traga `undo` mostra a barra "… — Desfazer (Ctrl+Z)" com contagem regressiva;
  desfeito, a tela atual é recarregada.
- O banco só aceita sair de "cancelado" nesse caso: solicitação de compra cancelada pelo cancelamento do pedido (o
  motivo diz) e ordem de produção do pedido sem consumo, com o pedido já reaberto na mesma transação; só a situação
  muda (migração 070, `supply.status_guard` e `production.order_guard`).
- Pedido: `sales.cancel_order` oferece `sales.reopen_order` com o estado anterior por documento (pedido volta a
  em aberto; solicitações de compra canceladas junto voltam à situação que tinham; ordens de produção
  canceladas junto voltam a planejadas). `sales.reopen_order` também é rotina (Reabrir pedido cancelado) e só
  mexe no que foi cancelado junto com o pedido.
- Confirmação com consequência: linha `# ana:confirm <consequência>` no cabeçalho do programa (coluna
  `program.confirm`). O Estúdio pede confirmação num diálogo dizendo a consequência antes de executar (não em
  simular nem ensaiar). As ações de próximo passo com `confirm` usam o mesmo diálogo.

### T-050-07 — Valores padrão por contexto e último uso (RF-050-06, D6)
- Parâmetro com `"default_from": "last"`: o último valor que o usuário usou naquela rotina, em qualquer computador
  (guardado por usuário nas preferências da tela, só os campos declarados, gravado só quando muda — P15). O
  formulário inteiro continua lembrando o último uso no próprio navegador, como antes. Depósito do inventário.
- Parâmetro com `"default_from": {"program", "params", "depends", "field"}`: quando o campo de que depende muda,
  o programa de consulta (rodando como o usuário) devolve os valores do contexto e o campo é preenchido — se a
  pessoa ainda não o mudou à mão.
- Ordem: o que veio da variante ou do endereço > contexto > último uso > `default`.
- Pedido de venda: cliente → condição de pagamento do cliente, depósito e centro de custo do último pedido do
  cliente (`sales.lookup kind=customer_defaults`).

### T-050-08 — Código de barras e QR pela câmera (RF-050-08)
- Parâmetro (ou coluna de linhas) com `"scan": true`: botão de câmera ao lado do campo, quando o navegador lê
  códigos (`BarcodeDetector`) e há câmera. O diálogo mostra a câmera, lê o primeiro código e preenche o campo;
  Esc ou Cancelar fecham e desligam a câmera. Leitor USB continua funcionando como teclado.
- Cabeçalho `Permissions-Policy` passa a permitir a câmera para a própria origem (`camera=(self)`).
- Campos marcados: item do pedido, documento aberto, itens de contagem e de recebimento, lote e série onde
  houver.

### Testes
- Integração: `base.find` (documento pelo número, cliente pelo CNPJ, nada para quem não pode), `ana.can_run`,
  oferta e uso do desfazer (só o dono, uma vez, no prazo; nada em simulação/ensaio), cancelar e desfazer o
  pedido restaurando o suprimento por documento (CA-050-03), `customer_defaults`, `ana:confirm` na lista de
  rotinas.
- Estúdio: Ctrl+K acha a rotina, o pedido pelo número e o cliente pelo CNPJ e executa (CA-050-02); `?` lista os
  atalhos; barra de desfazer após cancelar e desfazer pelo botão; diálogo de confirmação; padrão pelo cliente e
  último uso; câmera com leitor simulado.
