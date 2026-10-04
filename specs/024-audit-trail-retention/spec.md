# 024 — Trilha de auditoria e política de retenção

Situação: implementada · Princípios: P8 (rastreabilidade), P10–P12, P14 (dono)

## Problema
Tudo o que um usuário — pessoa ou robô — faz no ERP precisa poder ser
rastreado depois: cada acesso, cada execução, quanto tempo e CPU consumiu, e o
stack trace de cada falha. Ao mesmo tempo esses registros crescem sem parar; o
administrador de cada cliente precisa decidir por quanto tempo guardar cada
tipo, de acordo com a política e a legislação dele, sem que o expurgo afete a
operação.

## Requisitos funcionais
- **RF-024-01 Registro de acessos.** Toda requisição à API (`/api/…`, `/rpc`)
  gera um registro: quando, usuário (quando identificado), forma de
  autenticação (`session`, `api_key`, `password` no login, `anonymous`),
  chave de API usada, IP, método, caminho, status HTTP, duração e nó.
  Credencial inválida também é registrada (sem usuário, status 401).
  Arquivos estáticos e `/health` não entram.
- **RF-024-02 Chamadas entre nós.** Chamadas pela distribuição Erlang
  (`ana_rpc:call/3`) geram registro de acesso com autenticação `node` e o nó
  de origem no lugar do IP.
- **RF-024-03 Detalhe do que foi executado.** O registro de acesso guarda um
  detalhe quando a ação não é uma execução de programa: o texto do comando
  no console SQL (até 4 KiB). Nunca guarda senhas, tokens, chaves ou corpos
  de requisição.
- **RF-024-04 Execuções completas.** Além do que já existe (programa, versão,
  dono, origem, parâmetros, resultado, saída, erro, duração, CPU, memória,
  comandos SQL, linhas lidas, limites aplicados), a execução guarda o IP e a
  chave de API do chamador, quando houver, e o nó que a executou.
- **RF-024-05 Stack traces.** O stack trace Python de erro de programa já é
  guardado no erro. Falhas internas do núcleo durante uma execução também
  guardam o stack trace Erlang, num campo visível só para administradores e
  nunca devolvido a chamadores externos.
- **RF-024-06 Trilha do usuário.** Na ficha de qualquer usuário ou robô, em
  "Ver trilha", o administrador vê numa linha do tempo única tudo o que ele
  fez: acessos, logins, execuções, tarefas internas e alterações
  administrativas, com filtro de período.
- **RF-024-07 Detalhe da execução na auditoria.** Na auditoria, clicar numa
  execução abre o detalhe completo: consumo, limites, parâmetros, resultado,
  saída, erro com stack trace e trace interno; se o conteúdo já foi
  expurgado, mostra quando.
- **RF-024-08 Política de retenção.** O administrador define, em
  Administração → Operação do sistema → Retenção, quantos dias guardar cada
  categoria:

  | Categoria | Padrão | Mínimo |
  |---|---|---|
  | Acessos (requisições, comandos SQL) | 90 | 1 |
  | Logins | 365 | 90 |
  | Execuções (registro) | 365 | 7 |
  | Conteúdo das execuções (parâmetros, resultado, saída, stack traces) | 30 | 1 |
  | Tarefas internas | 90 | 7 |
  | Ocorrências e avisos do agendamento | 90 | 7 |
  | Alterações administrativas | 1825 | 365 |

  O máximo é 36500 dias (na prática, guardar para sempre). O conteúdo das
  execuções é expurgado antes do registro: a execução continua visível (quem,
  quando, quanto consumiu, código do erro) sem os dados. Os mínimos protegem
  contra apagar rastros: alterações administrativas ficam pelo menos um ano.
  Mudanças na política ficam em `admin_log`.
- **RF-024-09 Expurgo automático.** Uma vez por dia, no horário configurado
  (padrão 3h, no fuso do cliente), o ERP expurga o que passou do prazo. Em
  cluster, só um nó executa por dia. O expurgo é uma tarefa interna do robô
  `system` (P14) e registra quantas linhas removeu de cada categoria. O
  administrador pode disparar "Expurgar agora"; nesse caso o dono é ele.
- **RF-024-10 Painel de retenção.** Para cada categoria: prazo configurado,
  quantidade aproximada de registros, espaço ocupado e registro mais antigo,
  mais o último expurgo (quando, quem, quantas linhas).

## Requisitos não funcionais
- **RNF-024-01 (performance)** Registrar acesso não pode atrasar a resposta:
  os registros vão para um buffer em memória e são gravados em lote (até 500
  por comando, a cada 1 s). Se o banco estiver indisponível e o buffer passar
  de 50 000 registros, os mais novos são descartados, contados e avisados no
  log; a requisição nunca falha por causa da auditoria.
- **RNF-024-02 (robustez)** O expurgo apaga em lotes pequenos (5 000 linhas
  por comando, com pausa entre lotes) para não segurar travas nem competir
  com a operação; falhas são registradas e tentadas de novo no dia seguinte,
  sem derrubar nada.
- **RNF-024-03 (segurança)** Só `admin` vê a auditoria, a trilha e o painel
  de retenção, e só ele muda a política. Os registros não guardam segredos.

## Critérios de aceitação
- **CA-024-01** Uma chamada RPC com chave de robô gera registro de acesso com
  o robô, `api_key`, a chave, IP, caminho, status e duração; uma credencial
  inválida gera registro 401 sem usuário.
- **CA-024-02** Um comando no console SQL aparece no acesso com o texto do
  comando; o login guarda o usuário sem a senha.
- **CA-024-03** Uma execução via RPC guarda IP, chave e nó; o detalhe na
  auditoria mostra CPU, memória, SQL e o stack trace do erro.
- **CA-024-04** A trilha do usuário reúne acesso, login e execução dele, em
  ordem de tempo.
- **CA-024-05** A política recusa valores abaixo do mínimo; com prazos
  reduzidos, "Expurgar agora" remove os registros antigos, limpa o conteúdo
  das execuções antigas mantendo o registro, e grava a tarefa interna com as
  contagens.
- **CA-024-06** O painel de retenção lista as categorias (agendamento em duas linhas: ocorrências e avisos) com prazo,
  volume e último expurgo.
