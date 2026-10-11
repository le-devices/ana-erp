# 037 — Plano técnico

## Regra no núcleo (migração `033_customer_documents.sql`, `ana_files`)
- `files.folder.external` + `files.is_external(pasta)` (herdado pelas
  filhas). Pastas externas: as criadas pelo núcleo para documentos
  publicados (Faturas, Pedidos, Entregas, Atendimentos, Recibos, Extratos,
  Ordens de compra; Entregáveis de projeto) ou marcadas por um
  administrador (auditado; desmarcar remove os acessos externos).
- Acesso concedido a parceiro (party), papel `external` ou conta externa só
  em pasta/arquivo externo; link de download só para arquivo em pasta
  externa (`INTERNAL_DOCUMENT`).
- Operação de programa `publish` (`ana.files.publish`): o tipo decide a
  subpasta numa lista fechada; tipo fora da lista é recusado. `link`
  (`ana.files.link`) cria link com validade, limite e senha.
- `ANA_PUBLIC_URL` no contexto (`ana.context.public_url`) para endereços
  absolutos nos links.

## Programas
- `docs.pdfs` (biblioteca): pedido, entrega/romaneio, atendimento da OS,
  recibo, extrato, ordem de compra (+ fatura via `finance.invoice_pdf`);
  `publish_quietly` em savepoint (falha no PDF nunca desfaz o documento).
- Geração automática: pedido criado, expedição despachada e entregue, OS
  aceita, ordem de compra enviada, cobrança paga, faturamento.
- `docs.pdf` (portal: só publicados da própria empresa), `docs.share_link`
  (`link_doc`), `files.my_documents` (`documentos`, portal),
  `files.download`; botões PDF/Link no visualizador de documentos.
- Tela de Arquivos: selo "para parceiros", aviso na pasta e botão do
  administrador para marcar/desmarcar.
