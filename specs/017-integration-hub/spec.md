# 017 — Hub de integrações (bancos, pagamentos, serviços externos)

## Problema
Um ERP precisa conversar com bancos (extratos, cobranças, pagamentos),
gateways de pagamento (PIX, boleto, cartão), marketplaces, transportadoras e
prefeituras (NFS-e). Cada integração tem formato, autenticação, falhas e
reenvios próprios. Sem um padrão, cada uma vira um programa frágil, com
segredos espalhados e sem rastreabilidade.

## Histórias
- **H1** Como administrador, cadastro conectores (banco X, gateway Y) com
  credenciais guardadas num cofre — programas usam o conector, nunca a senha.
- **H2** Como financeiro, importo extratos bancários por **arquivo** (OFX,
  CNAB 240/400, CSV configurável) ou por **API**, sem duplicar lançamentos.
- **H3** Como financeiro, faço **conciliação bancária**: o ANA casa linhas do
  extrato com títulos a receber/pagar por regras (valor, data, documento,
  identificador da cobrança), eu confirmo os casos duvidosos e os títulos são
  baixados com lançamento contábil.
- **H4** Como financeiro, emito cobranças por gateway (PIX, boleto, link de
  cartão) a partir de um título; quando o gateway avisa o pagamento
  (webhook), o título é liquidado automaticamente.
- **H5** Como desenvolvedor, escrevo integrações novas em Python usando o
  conector (HTTP com autenticação, SFTP, pasta monitorada), com mapeamento e
  transformação versionados como qualquer programa.
- **H6** Como administrador, vejo cada mensagem enviada/recebida, seu estado,
  tentativas e erros; reprocesso as que falharam.

## Requisitos funcionais
- **RF-017-01** Conectores (`integration.connector`): tipo (`http_api`,
  `sftp`, `folder`, `webhook_in`, `email_in`), URL base/host, autenticação
  (`basic`, `bearer`, `oauth2_client`, `mtls`, `hmac`, `api_key`), limites de
  taxa, timeout, hosts permitidos; credenciais no cofre (RF-017-02).
- **RF-017-02** Cofre de segredos (`integration.secret`): cifrado com chave
  mestra do ambiente; segredos só são descriptografados no núcleo no momento
  da chamada; nunca chegam ao Python nem às respostas da API; rotação com
  data de validade e alerta.
- **RF-017-03** API para programas: `ana.http(connector, method, path, json=…,
  headers=…)`, `ana.sftp(connector).list/get/put`, sujeitas aos limites (spec
  012) e aos hosts permitidos do conector. Programas não fazem rede direta
  (P10).
- **RF-017-04** Webhooks de entrada: endpoint por conector
  (`/hooks/<connector>`), verificação de assinatura (HMAC/certificado),
  janela anti-repetição, idempotência por identificador do evento, resposta
  rápida (fila) e processamento por programa configurado.
- **RF-017-05** Mensageria confiável: caixa de saída transacional
  (`integration.outbox` gravada na mesma Unidade de Trabalho do negócio) e de
  entrada (`integration.inbox`); entrega com novas tentativas e recuo
  exponencial; fila de mortos com reprocessamento manual; ordem por chave
  quando exigido.
- **RF-017-06** Importação de extratos: leitores OFX, CNAB 240/400 e CSV com
  layout configurável; deduplicação por identificador da transação (ou hash
  data+valor+histórico+saldo); importação por arquivo enviado, pasta/SFTP
  monitorados ou API do banco agendada (spec 018).
- **RF-017-07** Conciliação (`finance.bank_statement_line` ↔ `finance.bill`):
  regras em ordem (identificador de cobrança exato → documento + valor →
  valor + data ± tolerância → sugestão por similaridade), com nível de
  confiança; automática acima do limiar, manual abaixo; baixa parcial e
  agrupada (1 linha ↔ N títulos); tarifas e juros lançados nas contas padrão;
  desfazer conciliação com estorno.
- **RF-017-08** Cobrança por gateway: `finance.create_charge(bill, method)`
  gera cobrança (PIX com QR, boleto com linha digitável, link de cartão),
  guarda identificador externo; webhook de pagamento liquida o título
  (idempotente); cancelamento e estorno; taxas lançadas.
- **RF-017-09** Painel de integrações: mensagens por conector e estado,
  latência, taxa de erro, últimas falhas com corpo (segredos mascarados),
  reprocessar/descartar.
- **RF-017-10** Modelos de conector reutilizáveis (pacotes com programas de
  mapeamento) para os casos mais comuns, instaláveis por cliente.

## Requisitos não funcionais
- **RNF-017-01** (segurança) Saída de rede só por conectores com hosts
  permitidos (sem SSRF); TLS verificado; mTLS quando exigido; segredos
  mascarados em logs e auditoria.
- **RNF-017-02** (robustez) Pelo menos uma entrega com idempotência
  ponta a ponta; nenhum evento de pagamento perdido nem aplicado duas vezes.
- **RNF-017-03** (performance) Importação de 100 mil linhas de extrato em
  < 60 s; conciliação automática em lote por consulta agregada.
- **RNF-017-04** (P13) Layouts, regras e contas configuráveis por cliente.

## Critérios de aceite
- **CA-017-01** Importar o mesmo extrato OFX duas vezes não duplica linhas.
- **CA-017-02** Linha com identificador de cobrança conhecido baixa o título
  automaticamente com lançamento balanceado.
- **CA-017-03** Linha de valor igual a dois títulos fica para conciliação
  manual com as duas sugestões.
- **CA-017-04** Webhook com assinatura inválida → 401; mesmo evento duas vezes
  → título liquidado uma vez só.
- **CA-017-05** Falha do gateway gera novas tentativas e, esgotadas, vai para
  a fila de mortos; reprocessar entrega com sucesso.
- **CA-017-06** Programa não consegue ler o segredo de um conector nem chamar
  host fora da lista.
