# 044 — E-mail de saída (SMTP)

Situação: implementada (nov/2026).

Decisões de implementação: o envio é do núcleo (`ana_smtp`, cliente próprio sem dependência): os
programas nunca veem a senha nem abrem conexão. A configuração fica nas opções do conector (`host`,
`port`, `security`, `from`, `from_name`, `reply_to`, `ca_cert`, `allow_plain`); usuário e senha no cofre.
`ana.send_email` grava pela função `integration.enqueue_email` (SECURITY DEFINER), que resolve o conector
padrão. Na entrega, o trabalhador da integração lê os anexos com a permissão de quem enviou, respeita o
limite por minuto sem gastar tentativa e manda recusas permanentes (5xx, anexo não permitido) direto para
paradas. Conector sem criptografia exige `allow_plain` e vira apontamento "smtp_plaintext" nas
Verificações. Regra de alerta com conector SMTP exige destinatários e manda abertura e encerramento.

## Problema
O ANA só envia e-mail por um conector HTTP de gateway (spec 017, usado pelos
alertas da T-019-08b). Muitas empresas têm só um servidor SMTP (próprio,
Microsoft 365, Google Workspace, provedor). Sem SMTP, o envio de documentos ao
cliente (T-037-06b), os avisos de vulnerabilidade (T-033-09b), os alertas e os
relatórios agendados dependem de copiar e colar.

## Decisões
- **D1 — SMTP é um tipo de conector.** Novo tipo `smtp` no hub de integrações:
  servidor, porta, segurança (TLS direto, STARTTLS obrigatório; texto puro só
  com opção explícita e aviso nas Verificações), usuário, senha no cofre,
  remetente e nome, responder-para, limite por minuto. Herda fila, novas
  tentativas, mensagens paradas e auditoria.
- **D2 — Um caminho para todo e-mail.** `ana.send_email(...)` para os programas
  e o mesmo serviço para o núcleo (alertas, avisos): grava na fila de saída
  na mesma transação do negócio (só sai se a transação confirmar) e um
  entregador envia; a falha não desfaz o negócio.
- **D3 — Conteúdo seguro.** Texto e HTML (HTML vem de modelo com escape;
  nunca HTML montado com dados sem escape), anexos do repositório de arquivos
  por referência (spec 016) com limite de tamanho, destinatários validados,
  sem cabeçalhos injetáveis (quebra de linha recusada).
- **D4 — Conector padrão.** Um conector marcado como "e-mail padrão" atende
  quem não escolhe outro; regras de alerta (T-019-08b) podem usar SMTP
  diretamente.

## Requisitos funcionais
- **RF-044-01** Conector `smtp` com os campos de D1, teste de conexão e
  "Enviar e-mail de teste" na tela do conector.
- **RF-044-02** `ana.send_email(to, subject, text=None, html_template=None,
  data=None, attachments=None, cc=None, bcc=None, connector=None)` transacional
  (D2), devolvendo o identificador da mensagem.
- **RF-044-03** Entrega com novas tentativas e espera crescente, mensagens
  paradas visíveis e reprocessáveis (spec 017); respostas permanentes do
  servidor (5xx) não são repetidas.
- **RF-044-04** Destinos de alerta por SMTP (T-019-08b) e uso pelo envio de
  documentos (T-037-06b) e pelas verificações (T-033-09b).
- **RF-044-05** Registro: quem enviou (dono da execução), para quem, assunto,
  situação e identificador do servidor; corpo guardado conforme a retenção.

## Requisitos não funcionais
- **RNF-044-01** Senha nunca aparece em tela, registro ou rastro.
- **RNF-044-02** Certificado do servidor verificado (cadeia e nome); exceção
  só por CA própria cadastrada.
- **RNF-044-03** 1.000 mensagens enfileiradas sem bloquear execuções; entrega
  respeitando o limite por minuto do conector.

## Critérios de aceite
- **CA-044-01** Com um servidor SMTP de teste, "Enviar e-mail de teste" chega
  com o remetente configurado.
- **CA-044-02** Programa que envia e-mail e depois falha: nada é enviado.
- **CA-044-03** Servidor fora do ar: a mensagem é repetida e entregue quando
  ele volta; endereço recusado (5xx) vai direto para paradas.
- **CA-044-04** Assunto com quebra de linha é recusado; HTML do modelo escapa
  os dados.
- **CA-044-05** Regra de alerta com destino SMTP envia o aviso de abertura e
  de encerramento.
