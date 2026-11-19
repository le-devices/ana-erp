# 049 — Tarefas

Fase 1 — motor e serviços
- [x] T-049-01 Modelo: tributos, regras e tabelas com vigência; cópia com nova data (RF-049-02, D2, D5)
- [x] T-049-02 Linguagem de fórmulas fechada com validação (RF-049-04, D4, CA-049-05)
- [x] T-049-03 Seleção por critérios, especificidade, conflitos e "Qual regra vale?" (RF-049-03, D3, CA-049-03)
- [x] T-049-04 Serviço `tax.calculate` / `tax.engine` com explicação, cache e registro reproduzível (RF-049-01, 11, RNF-049-01, 02, CA-049-02)
- [x] T-049-05 Casos de teste tributários, simulação por data, ativação com diferenças (RF-049-05, D6, CA-049-04)
- [x] T-049-06 ISS por município e retenções federais e municipais; migração do ISS dos projetos; títulos e lançamentos (RF-049-07, 08, CA-049-01)
- [x] T-049-06b Simples Nacional: RBT12 (com início de atividade), faixas, alíquota efetiva, repartição do ISS, fator R com aviso (RF-049-08, D10, CA-049-08)
- [x] T-049-07 Pacotes de regras pelas atualizações do produto; permissão e auditoria; verificação de cálculo fora do motor (RF-049-06, RNF-049-03, 04)

Pendências menores da fase 1 (fim da fila):
- [ ] T-049-07b Aviso da vigilância fiscal por e-mail ou tarefa ao grupo tax (hoje: tela Impostos e rotina diária; usuários ainda sem e-mail)
- [ ] T-049-07c Retirar regra roda os casos de teste antes, como a ativação

Fase 2 — tributos sobre mercadorias (depois da fase 3, D10)
- [ ] T-049-08 ICMS (próprio, ST, DIFAL, FCP), IPI, PIS/COFINS; vendas, compras, notas de fornecedor e devoluções (RF-049-07, 09, CA-049-06)

Fase 3 — reforma tributária (logo após a fase 1, D10)
- [ ] T-049-09 CBS, IBS e Imposto Seletivo na transição, alíquotas por ano e créditos (RF-049-10, CA-049-07)
