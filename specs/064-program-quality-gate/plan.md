# 064 — Plano (fase 1: inspeção e portão)

## Inspeção (T-064-01, RF-064-01)
- O runtime Python já inspecionava sintaxe, `PARAMS` e o SQL (spec 019). A análise vira
  `lint_program`: as regras de SQL continuam e entram as de segurança (SQL montado com
  valor recebido, segredo no código, `eval`/`exec`, importação dinâmica, módulos de
  rede/arquivos/processos, `open()`, segredo no log), desempenho (chamada externa em
  laço), robustez (exceção engolida, erro sem código, `while True` sem saída), padrões
  (código de erro, rótulo de parâmetro, nomenclatura de outro fornecedor) e disco
  (gravação em laço).
- Cada achado tem categoria, severidade (informação, atenção, sério, crítico),
  explicação, sugestão e **impressão digital** = regra + texto da linha (estável quando
  as linhas mudam de lugar).
- Aceitação no código com motivo: `# ana:lint-ok regra — motivo` (já existia na 019).

## No editor (T-064-02, RF-064-02)
- `POST /api/programs/inspect {source}` inspeciona sem salvar. O Estúdio chama meio
  segundo depois da última tecla (a anterior é cancelada), marca os achados na margem
  (forma + cor) e mostra uma faixa abaixo do editor: o que bloqueia o transporte, como
  resolver, ir para a linha e "Pedir isenção".

## Linha de base e isenções (T-064-03, RF-064-03)
- Migração 065: `ana_system.quality_baseline` (achados antigos que não bloqueiam) e
  `ana_system.quality_exemption` (motivo, prazo, situação). O banco recusa que quem pediu
  decida (`decided_by <> requested_by`).
- Parâmetros da instalação: `quality_gate_level` (severidade que bloqueia, padrão
  "sério"), `quality_exemption_max_days` (padrão 90) e `quality_gate_required`.
- Transportes → Isenções: aprovar/recusar e registrar a linha de base.

## Portão no transporte (T-064-04, RF-064-07)
- `ana_quality:gate/1` reinspeciona os programas do pacote e desconta linha de base e
  isenções aprovadas e vigentes. A exportação recusa (`QUALITY_GATE`, com o relatório)
  quando algo bloqueia; verde, o relatório vai **dentro do manifesto assinado**.
- Na chegada, com `quality_gate_required = 1`, o pacote precisa de relatório verde que
  cubra cada programa com o mesmo hash do item.

## Produto pelo portão (T-064-05, RF-064-09)
- `tests/runtime/test_quality.py` passa todos os programas do produto pela inspeção:
  nenhum achado sério ou crítico sem aceitação com motivo.

## Fase 2 — testes, desempenho comparado e falhas (T-064-06..09)

### Testes dos programas (T-064-06, D4)
- Declarados junto do programa: `TESTS = [{"name", "params", "expect"}]` (o resultado **contém** `expect`: mapas pelas
  chaves, listas item a item, números pelo valor) ou `{"name", "params", "error": "CODIGO"}` (a rotina falha com esse
  código); e funções `def test_<nome>():` com `assert` (rodam no lugar do `main`, com `ana` disponível).
- Cada teste roda num **ensaio** (spec 056): tudo é desfeito e efeitos externos ficam retidos. Cobertura de linhas pelo
  runtime (`sys.settrace` só no arquivo do programa; linhas executáveis a partir do código compilado), unida entre os
  testes. Execução com as opções `entry` e `coverage` do núcleo; a listagem usa `entry = "__list_tests__"`.
- Histórico em `ana_system.program_test_run` (migração 073). Nunca na produção (RNF-064-03).

### Desempenho comparado (T-064-07, D5, CA-064-03)
- Os mesmos testes rodam na versão anterior (opção `version` do núcleo, só em ensaio). Piora por teste que passou nas duas:
  comandos SQL acima de `quality_perf_sql_pct` (padrão 50%, e ao menos +2) e CPU do programa acima de
  `quality_perf_time_pct` (padrão 100%, e ao menos +50 ms). CPU e não tempo de relógio: o relógio inclui a partida do
  processo e a carga da máquina e daria alarme falso.

### No portão (D4, D5)
- O relatório do portão de um programa inclui a última rodada do **mesmo código** (mesmo sha): teste falhando
  (`tests_failed`) e piora de desempenho (`performance_regression`) são achados sérios, com isenção como os demais; com
  `quality_tests_required = 1`, programa que grava sem teste passando também (`tests_missing`).

### Falhas por versão (T-064-08, D6, CA-064-05)
- Erros dos últimos 90 dias agrupados por versão e código, com a versão em que o código começou e o pacote de transporte
  que trouxe a versão (`transport_item.created_version`), com o resultado do portão daquele pacote para o programa.
  A reexecução para depurar fica com a spec 047.

### Tela Qualidade (T-064-09, D8)
- Aba "Qualidade" do programa no Desenvolvimento: achados do portão (bloqueia, isento, linha de base), "Rodar os testes",
  resultados com motivo, cobertura, pioras, falhas por versão e versões com o pacote. "Explicar" abre o assistente
  (spec 052) com o achado e as linhas ao redor; a pessoa aplica e revisa a correção.
