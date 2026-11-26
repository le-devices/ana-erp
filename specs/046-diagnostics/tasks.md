# 046 — Tarefas

- [ ] T-046-01 Medições de E/S por execução (linhas gravadas, chamadas externas, bytes de arquivos) (RF-046-02)
- [ ] T-046-02 Agregado diário incremental e consolidação, retenção própria (RF-046-01, D1, RNF-046-01, 02, CA-046-04)
- [ ] T-046-03 Grupos de erro por assinatura, ciclo de vida e exemplos guardados (RF-046-03, D2, CA-046-01, 03)
- [ ] T-046-04 Tela Diagnósticos: perguntas prontas, filtros, período, comparação, tendência (RF-046-04, D4, CA-046-02)
- [ ] T-046-05 Aprofundamento até execução, pilha, rastro e perfil; dono e afetados; "Meus programas" (RF-046-05, 06, D3, D5)
- [ ] T-046-06 Avisos ao dono por regra de alerta, exportação e API; acesso por papel e namespace (RF-046-06, 07, RNF-046-03, CA-046-05)

Revisão de 26/11/2026. Os grupos de erro vêm antes do agregado de longo prazo: dão a visão de conjunto que falta
hoje e não dependem do agregado.

Antes do código: plan.md com:
- a medição da coleta sob rajada (ETS, intervalo e orçamento de escrita);
- as regras iniciais de normalização, com casos;
- a fonte de cada tipo de falha.

- [ ] T-046-07 Coleta por nó em memória com gravação por lote, primeira ocorrência imediata e reconciliação pelo líder (D12, RNF-046-04, RNF-046-05, CA-046-07)
- [ ] T-046-08 Assinatura com mensagem normalizada, regras como dado e casos de teste (D8, RF-046-09, CA-046-06)
- [ ] T-046-09 Fontes além das execuções: agendamentos, esteiras e processos, conectores, regras, HTTP 5xx, quedas do núcleo (D7, RF-046-08, CA-046-10, CA-046-11)
- [ ] T-046-10 Situação "conhecido", "corrigido na versão" ligado ao transporte, "reapareceu" e "apareceu depois de" (D10, RF-046-11, CA-046-09)
- [ ] T-046-11 Avisos de novo, reapareceu e pico, limitados por janela; gatilhos nas regras da spec 051 (D9, RF-046-10)
- [ ] T-046-12 Mensagem ao usuário: "já é conhecido" ou "o responsável já foi avisado" (D11, RF-046-12, CA-046-08)
- [ ] T-046-13 Tela "Erros": um grupo por linha, por impacto, com tendência, filtros e aprofundamento até a execução; verificador da spec 050 (RF-046-13)
