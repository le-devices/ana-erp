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
