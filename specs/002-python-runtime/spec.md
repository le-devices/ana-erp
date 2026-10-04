# 002 — Runtime Python

## Problema
A lógica de negócio do ANA é escrita em Python, guardada no banco, versionada e
executada pelo núcleo sem deploy de arquivos. Os programas precisam acessar
dados com segurança, chamar outros programas e produzir saídas (texto, tabelas,
resultado estruturado) — tudo dentro de uma Unidade de Trabalho.

## Histórias
- **H1** Como desenvolvedor, quero criar um programa Python no ERP, salvá-lo e
  executá-lo imediatamente.
- **H2** Como desenvolvedor, quero ler e gravar tabelas de negócio com SQL
  parametrizado.
- **H3** Como desenvolvedor, quero reaproveitar código: chamar outro programa e
  importar Bibliotecas.
- **H4** Como auditor, quero saber quem executou o quê, quando, com qual versão
  e com qual resultado.
- **H5** Como desenvolvedor, quero voltar a uma versão anterior de um programa.

## Requisitos funcionais
- **RF-002-01** Programa tem: `name` (namespace com pontos, ex.
  `sales.create_order`, regex `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`),
  `description`, `kind` (`program` | `library`), `exposed` (bool),
  `min_role`, `source`, `version`.
- **RF-002-02** Toda gravação de fonte cria nova versão imutável com autor,
  data e comentário. É possível listar versões e restaurar uma (gera nova versão).
  Gravação aceita `base_version`: se o programa já estiver em outra versão,
  responde 409 `CONFLICT` (controle otimista entre desenvolvedores).
- **RF-002-03** Ponto de entrada: função `main(**params)`; o valor
  retornado (serializável em JSON) é o resultado da execução.
- **RF-002-04** Declaração opcional `PARAMS = {"name": {"type": "int|float|decimal|str|bool|date|list|dict", "required": bool, "default": ...}}`.
  O runtime valida e converte antes de chamar `main`; violação gera erro
  `INVALID_PARAMETER` sem executar o programa.
- **RF-002-05** Módulo `ana` disponível ao programa:
  | API | Efeito |
  |-----|--------|
  | `ana.sql(q, *p)` | lista de dicts |
  | `ana.sql_one(q, *p)` | dict ou `None` |
  | `ana.sql_value(q, *p)` | primeira coluna da primeira linha |
  | `ana.sql_exec(q, *p)` | nº de linhas afetadas |
  | `ana.sql_batch(q, rows)` | executa em lote, retorna total afetado |
  | `ana.call(program, **p)` | executa outro programa na mesma Unidade de Trabalho |
  | `ana.remote(system, function, **p)` | chama programa exposto em Sistema remoto cadastrado |
  | `ana.log(msg, level="info")` | registra mensagem na saída |
  | `ana.table(rows, title=None)` | emite tabela na saída |
  | `ana.savepoint()` | gerenciador de contexto: falha dentro do bloco desfaz só o bloco |
  | `ana.context` | `user`, `role`, `execution_id`, `program`, `version`, `origin` |
  | `ana.Error(code, message, data)` | erro de negócio (desfaz a Unidade de Trabalho) |
  Parâmetros SQL usam `$1, $2, ...`. Resultados chegam tipados: `numeric` →
  `Decimal`, `date` → `date`, `timestamp[tz]` → `datetime`. No JSON de saída,
  `Decimal` é sempre texto (precisão exata, tipo estável).
- **RF-002-06** `print()` vai para a saída da execução.
- **RF-002-07** Bibliotecas são importáveis: `import ana_lib.util.format` ou
  `from ana_lib.util.format import money` carrega a Biblioteca
  `util.format` (versão atual).
- **RF-002-08** Toda execução é uma Unidade de Trabalho: sucesso → COMMIT;
  exceção, `ana.Error`, tempo esgotado ou abandono → ROLLBACK. Chamadas
  aninhadas (`ana.call`) compartilham a mesma transação, isoladas por
  SAVEPOINT: se a chamada falhar, só o que ela fez é desfeito e o chamador pode
  capturar o `ana.Error` e seguir.
- **RF-002-09** Toda execução é registrada em `ana_system.execution` (id,
  programa, versão, usuário, origem, início, fim, duração, status, parâmetros,
  resultado, erro, saída) — inclusive as que falharam.
- **RF-002-10** Execução pode ser síncrona (aguarda resultado) ou assíncrona
  (retorna id; resultado e eventos consultáveis depois).
- **RF-002-11** Programa inativo ou inexistente → erro `PROGRAM_NOT_FOUND`.
  Chamada aninhada ao próprio programa além da profundidade 16 →
  `MAX_DEPTH`.

## Requisitos não funcionais
- **RNF-002-01** (segurança) O processo Python não recebe credenciais de banco
  nem variáveis de ambiente do núcleo; roda com limites `RLIMIT_AS`
  (`ANA_PY_MEMORY_MB`, padrão 512), `RLIMIT_CPU`, `RLIMIT_NOFILE`, `RLIMIT_FSIZE`.
- **RNF-002-02** (segurança) SQL de programas executa em conexões autenticadas
  como o papel `ana_exec` (sem acesso a `ana_system`; `RESET ROLE` não escala).
- **RNF-002-03** (segurança) `ana.remote` só alcança Sistemas remotos cadastrados — o
  programa não informa URLs.
- **RNF-002-04** (robustez) Tempo máximo de execução `ANA_EXEC_TIMEOUT_MS`
  (padrão 60000): ao estourar, o processo Python é morto e a transação desfeita.
  `statement_timeout` por comando SQL (`ANA_SQL_TIMEOUT_MS`, padrão 30000) e
  `lock_timeout` (`ANA_LOCK_TIMEOUT_MS`, padrão 10000). SQL em andamento no
  estouro do prazo é cancelado no servidor. A requisição pode pedir
  `timeout_ms` menor, nunca maior.
- **RNF-002-05** (robustez) Limite de execuções simultâneas
  `ANA_EXEC_MAX` (padrão 64); excedente recebe erro `OVERLOAD` (HTTP 503).
- **RNF-002-06** (robustez) Saída limitada a `ANA_OUTPUT_MAX_KB` (padrão 512 KiB)
  — o excedente é truncado com aviso; resultado limitado a 8 MiB.
- **RNF-002-07** (performance) Pool de `ANA_PY_PREWARM` (padrão 4)
  processos Python já iniciados; cada um serve uma execução e é descartado; a
  reposição é assíncrona. Latência de execução de um programa trivial < 50 ms
  com pool aquecido.
- **RNF-002-08** (performance) Fonte de programas em cache ETS por
  `name`; invalidado na gravação.

## Critérios de aceite
- **CA-002-01** Criar `demo.sum` com `def main(a, b): return a + b`,
  executar com `{"a":2,"b":3}` → resultado `5`, status `sucesso`.
- **CA-002-02** Salvar duas vezes gera versões 1 e 2; restaurar a 1 gera a 3
  com a fonte da 1.
- **CA-002-03** Programa que insere linha e depois lança exceção: a linha
  **não** existe após a execução; a execução consta com status `error`.
- **CA-002-04** `PARAMS` com `a` obrigatório e chamada sem `a` →
  `INVALID_PARAMETER`.
- **CA-002-05** Programa com `while True: pass` e timeout de 2 s termina em
  `timeout` e o núcleo continua respondendo.
- **CA-002-06** Programa que tenta `SELECT * FROM ana_system.app_user` recebe
  erro de permissão.
- **CA-002-07** Programa que lê `os.environ` não encontra `ANA_DB_PASSWORD`.
- **CA-002-08** `ana.call` de um programa que grava + programa chamador que
  falha depois → nada gravado.
- **CA-002-09** `from ana_lib.util.format import money` funciona quando a
  Biblioteca existe.
