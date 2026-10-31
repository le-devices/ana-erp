# 039 — Tarefas: BPM

## Fase 1 — modelagem
- [x] T-039-01 Esquema `bpm`: catálogo, modelo (JSON canônico dos elementos), versões, variáveis (RF-039-01, 05, 06)
- [x] T-039-02 Editor visual SVG no Estúdio: elementos, raias, conexões, desfazer/refazer, teclado, zoom/minimapa, layout automático, temas (RF-039-02, RNF-039-01/02)
- [x] T-039-03 Validação ao desenhar e painel de propriedades com construtor de condições (RF-039-03, 04)
- [x] T-039-04 Versões, publicação e comparação visual (RF-039-06)
- [x] T-039-05 Modelos prontos e importação/exportação BPMN 2.0 (RF-039-07, CA-039-06)

## Fase 2 — simulação
- [x] T-039-06 Simulador de eventos discretos, repetições e semente (RF-039-08, CA-039-04)
- [x] T-039-07 Cenários e comparação; animação no diagrama (RF-039-08, 09)
- [x] T-039-08 Calibração pelos casos e documentos reais (RF-039-10, CA-039-05)

## Fase 3 — execução
- [x] T-039-09 Motor com tokens, gateways, eventos de tempo e de fato, caminho de erro (RF-039-11, CA-039-03)
- [x] T-039-10 Minhas tarefas, formulários com dados do caso, delegar, avisos (RF-039-12, CA-039-02)
- [x] T-039-11 Prazos em tempo útil e escalonamento (RF-039-13)
- [x] T-039-12 Painel do caso e ações (RF-039-14)
- [x] T-039-13 Esteiras da spec 030 como processos (CA-039-07)

## Fase 4 — acompanhamento
- [x] T-039-14 Painel do processo e mapa de calor (RF-039-15)
- [x] T-039-15 Descoberta, variantes e conformidade (RF-039-16, CA-039-08)
- [ ] T-039-16b Arrastar elementos da paleta direto para a tela (hoje: clicar adiciona ligado ao elemento selecionado) e alinhar/distribuir uma seleção de vários elementos
- [x] T-039-17b Início de caso por agendamento (cron) e por mensagem de integração (spec 017) — publicar cria a rotina `bpm.<código>` no agendador (`ana.schedule_job`, só do próprio módulo); `bpm.message_start` como programa de entrada do conector
