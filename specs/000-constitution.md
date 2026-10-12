# 000 — Constituição do ANA ERP

Princípios que toda especificação, plano e linha de código devem respeitar.

## P1. Especificação antes do código
Toda funcionalidade nasce em `specs/`. Testes citam IDs de requisito. Divergência
entre código e spec é bug — de um ou de outro.

## P2. Vocabulário próprio
O ANA usa terminologia original (ver glossário em [README](README.md)).
**Não se usa nomenclatura de produtos ERP de terceiros** — nem em código, nem
em tabelas, nem em telas, nem em documentação, em nenhum idioma — por razões
de propriedade intelectual. Nomes de conceitos são escolhidos pelo que fazem.
Em inglês, evitam-se em especial: *remote function call*, *destination*,
*business partner*, *material* (como tipo de item), *client* (como inquilino),
*logical unit of work*, *transaction code*, *function module*.

## P2a. Sintaxe em inglês
Todo o código é escrito em inglês: identificadores, API dos programas Python,
esquemas/tabelas/colunas, chaves JSON, rotas HTTP, códigos de erro, variáveis
de ambiente, nomes de arquivos e comentários de código. Textos exibidos ao
usuário final e a documentação (specs, README) permanecem em português até que
a internacionalização seja especificada.

## P3. Núcleo em Erlang/OTP
Concorrência, isolamento de falhas e supervisão ficam no Erlang. Cada execução
de programa é um processo supervisionado; a falha de um programa nunca derruba
o núcleo.

## P4. PostgreSQL é a fonte da verdade
Dados de negócio, programas, versões, execuções e metadados vivem no
PostgreSQL. Recursos analíticos usam o próprio PostgreSQL (visões
materializadas, extensões colunares quando disponíveis) — sem um segundo banco
obrigatório.

## P5. Lógica de negócio em Python, dentro do ERP
Programas são escritos em Python, armazenados e versionados no banco,
editados, executados e depurados no próprio Estúdio. Nada de deploy de arquivos
para mudar regra de negócio.

## P6. Toda execução é uma Unidade de Trabalho
Uma execução (incluindo programas que ela chama) roda em uma única transação:
ou tudo é confirmado, ou nada é.

## P7. Chamável de fora por padrão aberto
Programas expostos são chamáveis por protocolos abertos (JSON-RPC 2.0 sobre
HTTP e distribuição Erlang), inclusive **pela internet, por sites e sistemas de
terceiros**, com autenticação forte e limites por cliente de API (spec 010).
Sem formatos proprietários.

## P8. Rastreabilidade
Toda execução gera registro auditável: quem, quando, qual versão, parâmetros,
resultado, erro.

## P9. Simplicidade operacional
`docker compose up` deve subir um ambiente completo e funcional, com dados de
demonstração.

## P10. Segurança em profundidade
- Programas Python rodam em **processos do SO separados**, sem credenciais de
  banco, com limites de memória/CPU/arquivos e ambiente limpo. Todo acesso a
  dados passa pelo núcleo Erlang.
- O SQL dos programas roda sob um **papel PostgreSQL restrito** (`ana_exec`)
  que não enxerga o esquema interno (`ana_system`: usuários, sessões, segredos).
- Menor privilégio em tudo: papéis de usuário por rota, programas expostos só
  quando explicitamente marcados, chamadas de saída só para Sistemas Remotos cadastrados.
- Senhas com PBKDF2 e comparação em tempo constante; bloqueio contra força bruta;
  cabeçalhos HTTP de segurança e CSP estrita (Estúdio sem dependências externas);
  limites de tamanho de requisição.
- Erros para chamadores externos nunca expõem rastros internos.

## P11. Robustez
- Todo trabalho tem prazo: tempo máximo por execução, `statement_timeout` no
  banco, expiração de sessões de depuração ociosas.
- Contrapressão: limite de execuções simultâneas; excesso recebe 503, nunca
  degradação silenciosa.
- O registro de auditoria de uma execução é gravado fora da sua Unidade de
  Trabalho — sobrevive ao rollback.
- Conexões quebradas são recicladas; o núcleo aguarda o banco na partida.
- Saídas e resultados têm tamanho máximo.

## P12. Performance
- Processos Python **pré-aquecidos**: interpretadores prontos aguardam
  trabalho; cada um atende uma única execução (isolamento) e é reposto em
  segundo plano.
- Cache de fontes de programas (por versão) e de statements preparados por
  conexão.
- Operações em lote no banco (`sql_batch`) para cargas.
- Analítico sem impacto no transacional: visões materializadas atualizadas
  concorrentemente, índices BRIN em datas, armazenamento colunar quando a
  extensão estiver disponível.

## P13. Produto licenciável
O ANA é vendido a muitos clientes; cada implantação é de uma empresa diferente.
- **Nada específico de cliente no código**: contas contábeis, alíquotas, dados
  da empresa e regras variáveis são parâmetros em tabela, com padrões sensatos.
- **Customizações sobrevivem a atualizações**: o que o cliente altera no
  Estúdio nunca é sobrescrito por uma nova versão do produto (spec 009).
- **Módulos habilitáveis por licença**, sem jamais impedir o cliente de ler os
  próprios dados.

## P14. Toda execução tem dono
Nada roda no ERP sem um usuário responsável — pessoa ou robô — cadastrado e
ativo: execuções de programas (tela, RPC, agendamento, notificação, chamadas
aninhadas e paralelas), tarefas internas (sementes, atualização do analítico,
manutenção) e chamadas entre nós. O dono responde pelas permissões, limites,
cotas e pela auditoria. O que o próprio ERP dispara pertence ao robô interno
`system`; o banco garante o dono por chave estrangeira.

## P15. Amigo de SSD
Escrever em disco gasta a vida útil do SSD e pode reduzir sua
confiabilidade. O ERP só grava o que precisa, quando precisa, e do jeito que
custa menos ao disco:
- nada é regravado se não mudou (recálculos verificam mudança antes);
- registros de alto volume vão em lote e são expurgados descartando
  partições inteiras, não apagando linha a linha;
- dados descartáveis (sessões, contadores, caches) ficam em memória ou em
  tabelas sem WAL;
- atualizações frequentes são desenhadas para não reescrever índices (HOT);
- o PostgreSQL comprime o WAL e espaça checkpoints; logs têm rotação.
Segurança dos dados vem antes: `fsync` e `full_page_writes` nunca são
desligados.

## P16. Atualizar sem parar
O ERP é atualizado com os clientes trabalhando: vários nós atrás de um
balanceador, desligamento gracioso e migrações compatíveis com a versão
anterior (expandir → migrar → contrair). Remover ou renomear algo só numa
versão seguinte, quando nenhum nó antigo roda mais; a migração que quebra a
versão anterior se declara com `-- ana:breaking`. Toda falha prevista tem
teste de caos versionado.

## P17. Tudo integrado, nada a conciliar à mão
Todo processo construído no ERP nasce integrado aos demais subsistemas e
automatiza o que for necessário. Um fato de negócio é registrado uma vez e
gera, na mesma unidade de trabalho, tudo o que dele decorre: movimento de
estoque com valor, título, lançamento contábil, custo do projeto, documento
para o cliente. Nenhum subsistema guarda um saldo que precise ser
conferido à mão com outro: cada razão auxiliar (clientes, fornecedores,
estoque, bancos, em elaboração) tem conciliação automática contra a
contabilidade, com divergência zero esperada e aviso quando não for. Toda
spec declara o que gera automaticamente e qual conciliação a cobre;
estorno é sempre por documento (nunca lançamento manual corrigindo outro).
