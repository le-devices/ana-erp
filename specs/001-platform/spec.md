# 001 — Plataforma (núcleo)

## Problema
O ERP precisa de um núcleo robusto que gerencie conexões com o banco, aplique
a estrutura de dados de forma reprodutível, autentique usuários e exponha uma
API HTTP para o Estúdio e para integrações.

## Histórias
- **H1** Como operador, quero subir o ERP com um comando e encontrá-lo pronto,
  com banco estruturado e dados de demonstração.
- **H2** Como usuário, quero entrar com login e senha e receber uma credencial
  de sessão.
- **H3** Como operador, quero saber se o sistema está saudável.

## Requisitos funcionais
- **RF-001-01** O núcleo aplica migrações SQL versionadas, em ordem, uma única
  vez cada, registrando-as no banco.
- **RF-001-02** O núcleo mantém um conjunto (pool) de conexões com o
  PostgreSQL configurável por variáveis de ambiente.
- **RF-001-03** Existem usuários com papéis `admin`, `developer` e
  `user`. Senhas são guardadas com PBKDF2-SHA256 e sal aleatório.
- **RF-001-04** Na primeira inicialização é criado o usuário `admin` com senha
  vinda de `ANA_ADMIN_PASSWORD` (padrão `admin`).
- **RF-001-05** `POST /api/session` com login/senha válidos retorna um token
  opaco; credenciais inválidas retornam 401.
- **RF-001-06** Rotas protegidas exigem `Authorization: Bearer <token>`;
  sem token válido retornam 401.
- **RF-001-07** `GET /health` retorna 200 com o estado do banco e versão.
- **RF-001-08** Sessões expiram após `ANA_SESSION_HOURS` (padrão 12) horas.
- **RF-001-09** Após 5 falhas de login seguidas para o mesmo login, novas
  tentativas são recusadas (429) por 5 minutos.
- **RF-001-10** Rotas exigem papel mínimo: edição de programas e console SQL
  exigem `developer`; gestão de usuários exige `admin`.

## Requisitos não funcionais
- **RNF-001-01** Falha de uma requisição ou execução não derruba o núcleo
  (supervisão OTP).
- **RNF-001-04** (segurança) Respostas HTTP levam `Content-Security-Policy:
  default-src 'self'`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`.
- **RNF-001-05** (segurança) Corpo de requisição limitado a `ANA_HTTP_MAX_BODY`
  (padrão 2 MiB); acima disso, 413.
- **RNF-001-06** (segurança) Comparação de hashes em tempo constante; tokens
  armazenados apenas como SHA-256.
- **RNF-001-07** (robustez) Na partida o núcleo tenta conectar ao banco com
  recuo exponencial por até 60 s antes de falhar.
- **RNF-001-08** (robustez) Conexão cujo cliente morreu volta ao pool somente
  após `ROLLBACK` bem-sucedido; caso contrário é substituída.
- **RNF-001-09** (performance) Statements preparados são reutilizados por
  conexão (cache por texto SQL).
- **RNF-001-02** Ambiente completo sobe via `docker compose up`.
- **RNF-001-03** Toda resposta da API é JSON UTF-8; erros seguem
  `{"error": {"code": "...", "message": "..."}}`.

## Critérios de aceite
- **CA-001-01** Após `docker compose up`, `GET /health` responde
  `{"status":"ok","database":"ok",...}`.
- **CA-001-02** Reiniciar o núcleo não reaplica migrações já aplicadas.
- **CA-001-03** Login `admin`/`admin` retorna token; senha errada retorna 401.
- **CA-001-04** `GET /api/programs` sem token retorna 401.
- **CA-001-05** 6ª tentativa de login errada seguida retorna 429.
- **CA-001-06** Usuário com papel `user` recebe 403 ao salvar programa.
- **CA-001-07** Corpo de 3 MiB retorna 413.
- **CA-001-08** Respostas trazem os cabeçalhos de segurança de RNF-001-04.
