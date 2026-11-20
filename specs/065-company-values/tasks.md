# 065 — Tarefas

Fase 1 — valores, leitura em todo lugar, rápido
- [x] T-065-01 Modelo: valor, versões com vigência, variação por instância e empresa/filial, tipos e formas, validação de referência a cadastro (RF-065-01..03)
- [x] T-065-02 Cache em memória por nó, propagação por evento, nenhuma escrita na leitura; medição antes/depois (RF-065-06, RNF-065-01, P15, P20)
- [x] T-065-03 Leitura: `ana.value` no runtime Python, `base.company_value` no SQL, registro do valor lido na execução (RF-065-05, RNF-065-02)
- [x] T-065-04 Expressões dinâmicas de lista fechada num só lugar; modelos de data dos agendamentos migrados sem mudar o agendado (RF-065-04, RF-065-11)
- [x] T-065-05 Tela "Valores da empresa": área, busca, vigência, prévia, histórico (P18)
- [x] T-065-06 Permissão por área, quatro olhos para sensíveis, auditoria, recusa de credenciais (RF-065-09)

Fase 2 — integração e automação
- [ ] T-065-07 Referências `{{valor:nome}}` em variantes (spec 045), agendamentos, regras de alerta, verificações, esteiras, processos e impostos (RF-065-05)
- [ ] T-065-08 Valores mantidos por rotinas: período aberto e último inventário (RF-065-07, CA-065-02)
- [ ] T-065-09 "Onde é usado", impacto antes de mudar ou apagar, nomes no editor e no portão de qualidade (RF-065-08, spec 064)
- [ ] T-065-10 Transporte da definição e, quando marcado, do conteúdo; aviso de ausente na importação (RF-065-10)
- [ ] T-065-11 Sugestões: constante no código que já é valor da empresa, vigência próxima, valor sem uso; assistente, paleta e implantação guiada
