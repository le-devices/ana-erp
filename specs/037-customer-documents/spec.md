# 037 — Documentos para clientes (e fornecedores) em PDF, com download controlado

## Problema
Só faturas (e faturas de projeto) geram PDF. Outros documentos que o cliente
precisa receber — confirmação do pedido, comprovante de entrega, relatório
de atendimento da OS, recibo de pagamento, extrato — não existem em PDF, e
não há um jeito controlado de entregá-los pela web. Regra do dono: **o
cliente nunca tem acesso a documento interno da empresa.**

## Histórias
- **H1** Como cliente, no portal vejo e baixo todos os meus documentos
  (pedidos, faturas, entregas, atendimentos, recibos, extratos).
- **H2** Como vendedor/financeiro, gero o PDF de um documento do cliente e,
  se ele não tem conta no portal, mando um link de download com validade,
  limite de downloads e senha opcional.
- **H3** Como comprador, a ordem de compra sai em PDF para o fornecedor.
- **H4** Como dono, tenho a garantia de que lançamentos, ordens de produção,
  transferências, relatórios gerenciais e pastas internas nunca chegam ao
  cliente.

## Requisitos funcionais
- **RF-037-01** Tipos de documento **externos** (lista fechada do produto):
  cliente — pedido de venda, fatura, comprovante de entrega, relatório de
  atendimento (OS), recibo de pagamento, extrato; fornecedor — ordem de
  compra. Qualquer outro tipo é interno e não pode ser publicado.
- **RF-037-02** Publicação: o PDF vai para uma subpasta compartilhada da
  pasta do parceiro (Pedidos, Faturas, Entregas, Atendimentos, Recibos,
  Extratos, Ordens de compra), criada pelo núcleo com acesso "baixar" só
  para as contas daquele parceiro; o resto da pasta do parceiro continua
  interno.
- **RF-037-03** Geração automática nos eventos (pedido criado, expedição
  despachada, OS aceita, ordem de compra enviada, faturamento) e sob demanda
  (recibo de título pago, extrato do período, regerar).
- **RF-037-04** Portal "Meus documentos": lista e download apenas das
  subpastas compartilhadas da própria empresa.
- **RF-037-05** Link de download sem conta (spec 016: validade, limite,
  senha), só para arquivos em subpasta compartilhada de cliente/fornecedor;
  o núcleo recusa link para arquivo interno.
- **RF-037-06** (T-037-06b) "Link para o cliente" pode enviar o link por
  e-mail (spec 044): ao e-mail do cadastro do parceiro ou aos endereços
  informados, com mensagem opcional; a senha do link nunca vai no e-mail (o
  texto avisa que será informada por outro meio); o envio só sai se a
  execução confirmar e fica registrado com o dono.

## Critérios de aceite
- **CA-037-01** Pedido criado, expedição despachada e OS aceita geram os PDFs
  nas subpastas compartilhadas; a conta do portal do cliente baixa os três.
- **CA-037-02** Pedir o PDF de um lançamento, ordem de produção ou
  transferência é recusado (`INTERNAL_DOCUMENT`).
- **CA-037-03** Link de download de arquivo de subpasta interna é recusado
  pelo núcleo; o de um documento externo baixa e respeita validade e limite.
- **CA-037-04** A conta do portal não vê a pasta interna do cliente nem a de
  outro cliente.
