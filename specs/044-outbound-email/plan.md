# 044 — Plano

- **Banco (migração 058).** `integration.connector.kind` aceita `smtp`; coluna `default_email` (no máximo um
  conector). Configuração SMTP nas opções do conector: `host`, `port`, `security` (`tls` | `starttls` |
  `none`), `from`, `from_name`, `reply_to`, `ca_cert` (PEM de CA própria), `allow_plain` (exigido para
  `none`); usuário e senha no cofre (autenticação "Usuário e senha"). `integration.enqueue_email(conector,
  mensagem)` (SECURITY DEFINER) resolve o conector padrão, confere tipo e situação e grava na fila de saída
  com o dono da execução.
- **Núcleo.** `ana_smtp`: cliente SMTP próprio (sem dependência): EHLO, STARTTLS, AUTH PLAIN/LOGIN (nunca
  em texto puro sem `allow_plain`), MAIL/RCPT/DATA com ponto duplicado, MIME (texto, HTML, anexos em
  base64, assunto e nomes em RFC 2047), TLS verificado (cadeia do sistema ou CA própria, nome do host).
  Respostas 5xx são permanentes. O trabalhador da integração entrega mensagens de conectores `smtp` pelo
  `ana_smtp` (anexos lidos com a permissão de quem enviou), respeita o limite por minuto sem gastar
  tentativa e manda as permanentes direto para paradas. `ana_connectors` valida as opções SMTP; rotas
  "testar conexão" e "enviar e-mail de teste".
- **Programas.** `ana.send_email(...)` no runtime: endereços e assunto validados (sem quebra de linha),
  HTML de modelo `string.Template` com escape de todos os dados, anexos por arquivo do repositório.
- **Alertas.** Regras de alerta aceitam conector SMTP (com destinatários); o aviso vira e-mail.
- **Verificações.** Conector SMTP sem criptografia aparece como apontamento de segurança (spec 033).
- **Tela.** Conector do tipo "E-mail (SMTP)" com campos próprios, "Testar conexão" e "Enviar e-mail de teste".
- **Testes.** Servidor SMTP de teste num container (biblioteca padrão do Python, com STARTTLS e certificado
  de CA própria): CA-044-01..05.
