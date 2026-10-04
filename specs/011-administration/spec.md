# 011 — Administração do dia a dia

## Problema
Hoje usuários, sistemas remotos, comandos e parâmetros só são mantidos por API
ou variáveis de ambiente. Um ERP vendido a muitos clientes (P13) precisa que o
administrador de cada cliente faça a operação diária **pela interface**:
incluir e bloquear usuários, redefinir senhas, ajustar parâmetros, ver o que
está rodando, auditar acessos — sem acesso ao servidor nem ao banco.

## Histórias
- **H1** Como administrador, incluo, edito, bloqueio e reativo usuários,
  defino papel e grupos, e redefino senha (o usuário troca no próximo acesso).
- **H2** Como administrador, encerro as sessões de um usuário e desbloqueio um
  login bloqueado por tentativas.
- **H3** Como administrador, organizo permissões de negócio por **grupos de
  acesso**: quais programas (ou prefixos, ex. `projects.*`) cada grupo executa.
- **H4** Como administrador, ajusto parâmetros do sistema (prazos, limites,
  política de senha, sessão) e dados da empresa, com efeito imediato.
- **H5** Como administrador, mantenho comandos, sistemas remotos e contas
  contábeis padrão.
- **H6** Como administrador, monitoro o sistema: execuções em andamento (e
  posso pará-las), pools de banco e de Python, memória, saúde.
- **H7** Como administrador, consulto auditoria: execuções de todos os
  usuários (filtros), entradas e falhas de login, alterações administrativas.
- **H8** Como desenvolvedor, arquivo ou excluo definitivamente programas que
  não servem mais (ex.: testes), e escondo inativos da árvore.
- **H9** Como qualquer usuário, troco minha própria senha.

## Requisitos funcionais
- **RF-011-01** Área **Administração** no Estúdio, visível só para `admin`,
  com seções: Usuários, Grupos, Parâmetros, Empresa, Comandos, Sistemas
  remotos, Contas padrão, Monitor, Auditoria. (Clientes de API entram com a
  spec 010.)
- **RF-011-02** Usuários: listar (busca, filtro por papel/ativo), criar
  (senha inicial ou gerada, exibida uma vez), editar nome/papel/grupos/ativo,
  redefinir senha com `must_change_password`, encerrar sessões, desbloquear.
  O sistema impede remover ou rebaixar o **último** `admin` ativo.
- **RF-011-03** Troca de senha pelo próprio usuário (senha atual + nova);
  obrigatória no próximo acesso quando marcada. Política configurável:
  tamanho mínimo (padrão 10), não pode ser igual ao login.
- **RF-011-04** Grupos de acesso (`ana_system.access_group`): nome, descrição,
  lista de padrões de programa (`projects.*`, `sales.create_order`). Um
  programa com `restricted = true` só executa para quem pertence a um grupo
  que o cobre (além do `min_role`). `admin` passa sempre.
- **RF-011-05** Parâmetros (`ana_system.setting`): chave, valor, tipo,
  mínimo/máximo, descrição, padrão. Prazos e limites deixam de depender só de
  variáveis de ambiente: a variável vira valor inicial; o banco prevalece
  depois. Alteração vale em até 5 s em todos os nós (NOTIFY). Segredos e
  conexão continuam só no ambiente.
- **RF-011-06** Empresa: dados da(s) empresa(s) (`base.company`): razão social,
  documento, endereço, contato; usados em documentos e no título do Estúdio.
- **RF-011-07** Manutenção de comandos, sistemas remotos (senha nunca é
  exibida depois de gravada) e contas padrão (`finance.default_account`),
  validando que a conta existe e aceita lançamento.
- **RF-011-08** Monitor: execuções em andamento (programa, usuário, início,
  estado), com botão parar; pools; memória; versão; saúde. Atualiza a cada 5 s.
- **RF-011-09** Auditoria: execuções (todas, com filtros por usuário,
  programa, status, período), eventos de login (`ana_system.login_event`:
  usuário, IP, sucesso, motivo, quando) e alterações administrativas
  (`ana_system.admin_log`: quem, o quê, antes/depois — sem segredos).
- **RF-011-10** Programas: árvore oculta inativos por padrão (alternável);
  exclusão definitiva (`purge`) só para `admin`, com confirmação, removendo
  programa e versões — o histórico de execuções permanece.
- **RF-011-11** Testes automatizados limpam o que criam (exclusão definitiva
  ao final), para não poluir instâncias reais.

- **RF-011-12** **Usuários robô** (`kind = 'robot'`): contas não interativas
  para rotinas agendadas (spec 018, `run_as`) e para chamadores de programas
  expostos (`/rpc`, spec 003). Não entram pela tela de login nem têm senha;
  não podem ter papel `admin`; seguem grupos, limites e cotas como qualquer
  usuário; aparecem identificados como robô em listas e auditoria.
- **RF-011-13** Chaves de API por robô (`ana_system.api_key`): nome, prefixo
  visível, validade opcional, lista opcional de IPs/redes permitidos; a chave
  completa (`ana_rk_…`) é exibida **uma única vez**; guardada só como hash;
  revogação com efeito imediato; registro de último uso. Várias chaves por
  robô (rotação sem parada).
- **RF-011-14** Autenticação: `Authorization: Bearer ana_rk_…` vale onde vale
  uma sessão de usuário, com as permissões do robô; chave revogada, vencida ou
  usada de IP não permitido → 401.
- **RF-011-15** Criar robôs e gerar/revogar chaves exige `admin`; tudo em
  `admin_log` (sem o segredo).
- **RF-011-16** (P14) Toda execução e toda tarefa interna tem um usuário dono
  ativo, pessoa ou robô; sem dono → recusada (`NO_OWNER`). O ERP traz o robô
  interno `system` (`builtin`), dono das tarefas que ele mesmo dispara
  (sementes, atualização periódica do analítico): não pode ser desativado,
  mudar de papel, receber senha nem chaves de API. Tarefas internas ficam em
  `task_run` (tarefa, dono, origem, status, duração) e aparecem em
  Administração → Auditoria → Tarefas internas. Agendamentos têm dono
  (`owner`) e executor (`run_as`), ambos usuários cadastrados.

## Requisitos não funcionais
- **RNF-011-01** (segurança) Toda ação administrativa exige `admin`,
  confirmação explícita nas destrutivas e gera `admin_log`.
- **RNF-011-02** (segurança) Senhas e segredos nunca voltam em respostas;
  senha gerada aparece uma única vez.
- **RNF-011-03** (robustez) Parâmetros são validados por tipo e faixa no
  servidor; valor inválido é recusado (o sistema nunca fica com configuração
  quebrada).
- **RNF-011-04** (performance) Parâmetros e grupos em cache ETS; leitura sem
  ida ao banco por execução.
- **RNF-011-05** (usabilidade) Layout estável: editor e painéis não podem
  colapsar quando elementos opcionais aparecem/somem.

## Critérios de aceite
- **CA-011-01** Admin cria usuário pela UI; o usuário entra, é obrigado a
  trocar a senha e depois usa o sistema.
- **CA-011-02** Rebaixar o último admin → recusado com `LAST_ADMIN`.
- **CA-011-03** Encerrar sessões invalida o token do usuário em até 30 s.
- **CA-011-04** Programa `restricted` executa para membro do grupo e retorna
  `FORBIDDEN` para não membro.
- **CA-011-05** Alterar `exec_timeout_ms` para 2000 faz um laço infinito parar
  em ~2 s sem reiniciar o núcleo; valor fora da faixa → 400.
- **CA-011-06** Monitor mostra execução em andamento e o botão parar a
  encerra como `aborted`.
- **CA-011-07** Login errado aparece na auditoria com IP e motivo.
- **CA-011-08** `purge` remove o programa e as versões; execuções antigas
  continuam consultáveis.
- **CA-011-09** Após a suíte de integração, não restam programas `test.*`.
- **CA-011-10** Robô criado com chave chama `/rpc` com sucesso; a mesma conta
  não consegue entrar por login e senha; robô com papel `admin` é recusado.
- **CA-011-11** Chave revogada, vencida ou de IP não permitido → 401;
  chave válida atualiza o último uso.
- **CA-011-12** Rotina agendada com `run_as` robô executa e a auditoria
  registra o robô como usuário da execução.
- **CA-011-13** Execução pedida em nome de usuário inexistente ou inativo →
  `NO_OWNER`; o robô `system` não pode ser desativado nem receber chave;
  a atualização periódica do analítico aparece em tarefas internas com dono
  `system`, e a pedida pelo Estúdio, com o usuário que pediu.
