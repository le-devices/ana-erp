# 059 — Documentos fiscais eletrônicos (NF-e, NFS-e)

Situação: especificada (nov/2026) — depende do motor de impostos (spec 049) e de decisões de infraestrutura (certificado digital, ambientes de homologação).

## Problema
No Brasil, vender exige emitir nota fiscal eletrônica: NF-e (mercadorias,
SEFAZ do estado) e NFS-e (serviços — com o padrão nacional avançando sobre os
padrões municipais). Sem isso o ERP depende de outro sistema para faturar, o
que quebra P17 (tudo integrado) e é motivo de não compra.

## Decisões
- **D1 — A nota nasce do documento.** Fatura de venda, de serviço e de projeto
  geram a nota com os dados do motor de impostos (spec 049) e do cadastro
  fiscal (spec 043); nada é redigitado.
- **D2 — Emissão pela fila de integração.** Transmissão por conectores
  (spec 017) com certificado A1 no cofre, nova tentativa, contingência e
  situação visível (autorizada, rejeitada com motivo, cancelada, inutilizada).
- **D3 — NFS-e pelo padrão nacional** primeiro; municípios fora dele por
  pacotes de conector (T-017-08b).
- **D4 — Documentos e envio.** XML e DANFE/DANFSE no repositório (spec 016),
  enviados ao cliente por e-mail (spec 044) e no portal (spec 037).
- **D5 — Entrada.** Notas recebidas de fornecedores (XML) importadas e
  confrontadas com o pedido e o recebimento (spec 038).

## Requisitos funcionais
- **RF-059-01** Geração da nota a partir dos documentos (D1).
- **RF-059-02** Transmissão, retorno, cancelamento, carta de correção,
  inutilização e contingência (D2).
- **RF-059-03** NFS-e padrão nacional (D3).
- **RF-059-04** XML, DANFE/DANFSE, envio e portal (D4).
- **RF-059-05** Importação de XML de entrada e confronto (D5).

## Critérios de aceite (a detalhar com o ambiente de homologação)
- **CA-059-01** Fatura de serviço gera NFS-e autorizada em homologação, com o
  ISS do motor de impostos, e o PDF chega ao cliente por e-mail.
