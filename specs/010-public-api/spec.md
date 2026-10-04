# 010 — API pública: chamadas pela internet por sites e sistemas

## Problema
Clientes do ANA querem que **sites e sistemas de terceiros** chamem programas
expostos pela internet: portal do cliente final consultando horas de projeto,
loja virtual criando pedidos, ferramenta de engenharia apontando horas, outro
ERP integrando faturas. A internet é hostil: credenciais vazam, tráfego é
repetido, robôs testam senhas, picos derrubam serviços. A spec 003 cobre
chamadas autenticadas por sessão de usuário; esta spec cobre a exposição
**pública**, com autenticação forte, robustez e boa performance.

## Atores e cenários
| Cenário | Exemplo | Mecanismo |
|---------|---------|-----------|
| **S1 Servidor → ANA** | backend de um site ou outro ERP | cliente de API confidencial: credenciais do cliente → token de acesso curto; opcionalmente requisição assinada |
| **S2 Navegador de usuário final → ANA** | portal onde o cliente final do licenciado entra e vê seus projetos | autorização com código + PKCE; usuário entra no ANA; token curto no navegador; origem do site na lista permitida |
| **S3 Navegador anônimo → ANA** | formulário público de contato ou de orçamento | chave publicável restrita a origens e a programas marcados `public`, limites rígidos |

Recomendação documentada: sempre que possível, **S1 com o backend do site
(BFF)** — segredos nunca chegam ao navegador.

## Histórias
- **H1** Como administrador, cadastro um cliente de API: nome, tipo
  (confidencial | navegador | publicável), origens permitidas, programas
  permitidos (escopos), IPs permitidos (opcional), limites de taxa e cota.
- **H2** Como integrador de servidor, troco `client_id`/`client_secret` por um
  token de acesso de curta duração e chamo `POST /rpc` com ele.
- **H3** Como desenvolvedor de portal, faço o usuário final entrar no ANA e
  recebo um token que só permite os programas do escopo concedido.
- **H4** Como desenvolvedor de site, uso uma chave publicável para um
  formulário público sem expor nenhum segredo.
- **H5** Como integrador, reenvio com segurança uma chamada que falhou por
  rede, sem duplicar o pedido (idempotência).
- **H6** Como administrador, revogo um cliente ou um segredo e o efeito é
  imediato; vejo uso, erros e bloqueios por cliente.

## Requisitos funcionais
- **RF-010-01** Cadastro `api_client`: `client_id` (público), segredo
  (guardado como hash; exibido uma única vez), tipo, origens (lista exata,
  `https://` obrigatório salvo `localhost`), escopos (lista de programas ou
  prefixos, ex. `projects.time_report`, `sales.*`), IPs/CIDRs permitidos,
  limites (`rate_per_minute`, `burst`, `daily_quota`), ativo, validade.
  Até 2 segredos ativos por cliente (rotação sem parada).
- **RF-010-02** `POST /oauth/token` com `grant_type=client_credentials`
  (S1): emite token de acesso assinado, validade padrão 10 min, contendo
  cliente, escopos e identificador único. Sem token de renovação para S1.
- **RF-010-03** Autorização com código + PKCE (S2): `GET /oauth/authorize`
  (tela de entrada do ANA, com consentimento dos escopos) →
  `POST /oauth/token` com `grant_type=authorization_code` e `code_verifier`;
  `redirect_uri` deve casar exatamente com uma cadastrada. Emite token de
  acesso (10 min) e token de renovação rotativo (uso único; reuso revoga toda
  a família).
- **RF-010-04** Chave publicável (S3): enviada em `X-Api-Key`; só vale com
  `Origin` permitido, só para programas com `public = true` no escopo, com
  limites próprios mais baixos.
- **RF-010-05** `POST /rpc` aceita, além da sessão de usuário (spec 003),
  tokens da API pública. A permissão efetiva é a **interseção**: programa
  exposto ∩ escopos do cliente ∩ (quando há usuário) papel do usuário.
- **RF-010-06** Requisições assinadas (opcional por cliente, obrigatório se
  configurado): cabeçalhos `X-Ana-Timestamp`, `X-Ana-Nonce`,
  `X-Ana-Signature` = HMAC-SHA256 sobre método, caminho, timestamp, nonce e
  hash do corpo. Janela de 5 min; nonce não pode repetir na janela.
- **RF-010-07** Idempotência: `Idempotency-Key` em chamadas de escrita; a
  primeira resposta é guardada por 24 h e repetida para a mesma chave e o mesmo
  corpo; mesma chave com corpo diferente → 422 `IDEMPOTENCY_MISMATCH`;
  chamada em andamento com a mesma chave → 409.
- **RF-010-08** CORS: só origens cadastradas do cliente recebem
  `Access-Control-Allow-Origin` (valor exato, nunca `*` para rotas
  autenticadas); pré-voo respondido sem tocar no banco, com `Max-Age`.
- **RF-010-09** Revogação: desativar cliente, segredo ou família de tokens tem
  efeito em até 5 s em todos os nós.
- **RF-010-10** `GET /rpc/functions` com token de API lista só os programas
  do escopo, com `PARAMS` e documentação (descoberta para integradores).
- **RF-010-11** Auditoria: toda chamada registra cliente, usuário (se houver),
  IP, programa, status, duração e chave de idempotência; consulta por cliente
  no Estúdio.
- **RF-010-12** Usuários com acesso pela internet podem ter 2º fator (TOTP);
  obrigatório para `admin` e `developer` quando `ANA_PUBLIC_MODE=true`.

## Requisitos não funcionais — segurança
- **RNF-010-01** TLS obrigatório na exposição pública: o núcleo recusa
  chamadas públicas sem HTTPS (direto ou atrás de proxy confiável declarado em
  `ANA_TRUSTED_PROXIES`, único caso em que `X-Forwarded-*` é aceito). HSTS em
  todas as respostas.
- **RNF-010-02** Tokens assinados com Ed25519, identificador de chave
  (`kid`) e rotação de chaves sem parada; validação de emissor, audiência,
  expiração (tolerância de 30 s) e escopos. Algoritmo fixo (nada de
  `alg` escolhido pelo token).
- **RNF-010-03** Segredos de cliente: ≥ 32 bytes aleatórios, armazenados com
  hash lento; comparação em tempo constante; prefixo identificável para
  detecção de vazamento (ex.: `ana_sk_`).
- **RNF-010-04** Limitação de taxa por cliente, por IP e por usuário (balde de
  fichas), cota diária, e proteção extra em `/oauth/token` e `/oauth/authorize`
  contra força bruta. Excesso → 429 com `Retry-After`.
- **RNF-010-05** Erros públicos nunca revelam se um programa existe fora do
  escopo, nem rastros internos; mensagens genéricas para falhas de
  autenticação.
- **RNF-010-06** Corpo máximo menor para rotas públicas (padrão 256 KiB) e
  limite de lote (20 chamadas); tempos máximos de leitura do corpo contra
  clientes lentos.
- **RNF-010-07** Escopos seguem menor privilégio: cliente novo nasce sem
  escopos; curinga só por prefixo de namespace.

## Requisitos não funcionais — robustez
- **RNF-010-08** Contrapressão separada: chamadas públicas usam uma fração
  configurável da capacidade (`ANA_PUBLIC_EXEC_SHARE`, padrão 50 %), para que
  um pico externo não impeça o uso interno do ERP.
- **RNF-010-09** Falha do armazenamento de idempotência ou de limites nunca
  executa uma chamada duas vezes: em dúvida, responde 503 (falha segura).
- **RNF-010-10** Disjuntor por cliente: excesso de erros 5xx ou de timeouts
  suspende o cliente temporariamente e registra alerta.

## Requisitos não funcionais — performance
- **RNF-010-11** Validação de token sem consulta ao banco (assinatura +
  cache em memória da configuração do cliente, invalidado por LISTEN/NOTIFY):
  sobrecarga da camada pública ≤ 2 ms p95 por chamada.
- **RNF-010-12** HTTP/2 e keep-alive; compressão de respostas > 1 KiB quando
  o cliente aceita; pré-voo CORS em memória.
- **RNF-010-13** Programas marcados `cacheable` (somente leitura) podem ter
  resposta em cache por cliente e parâmetros, com TTL declarado e `ETag`
  (304 quando não mudou).
- **RNF-010-14** Alvo: 1.000 chamadas/s de um programa trivial por nó de 4
  vCPUs, com p95 < 50 ms (medido por teste de carga versionado no repositório).

## Critérios de aceite
- **CA-010-01** Credenciais de cliente válidas → token; usá-lo em `/rpc` para
  programa no escopo → resultado; fora do escopo → `-32601` (como inexistente).
- **CA-010-02** Token expirado, adulterado ou assinado com chave desconhecida →
  401 genérico.
- **CA-010-03** Cliente desativado → chamadas falham em até 5 s, inclusive com
  token ainda dentro da validade.
- **CA-010-04** Origem não cadastrada não recebe cabeçalhos CORS; pré-voo de
  origem cadastrada responde sem acesso ao banco.
- **CA-010-05** Mesma `Idempotency-Key` repetida 5 vezes em paralelo cria um
  único pedido e as 5 respostas são idênticas.
- **CA-010-06** Assinatura com timestamp de 6 min atrás ou nonce repetido →
  401.
- **CA-010-07** 100 chamadas acima do limite em 1 s → 429 com `Retry-After`; o
  uso interno do ERP segue respondendo.
- **CA-010-08** Fluxo PKCE completo: `code_verifier` errado → falha;
  `redirect_uri` diferente → falha; token de renovação reutilizado → família
  revogada.
- **CA-010-09** Chave publicável só chama programas `public` e só de origem
  permitida.
- **CA-010-10** Requisição pública sem HTTPS (fora de proxy confiável) → 403
  quando `ANA_PUBLIC_MODE=true`.
- **CA-010-11** Teste de carga atinge RNF-010-14.

## Fora de escopo
Provedor de identidade externo (entrar com contas de terceiros) e webhooks de
saída — candidatos a specs futuras.
