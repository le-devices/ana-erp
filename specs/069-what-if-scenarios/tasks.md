# 069 — Tarefas

Antes do código: plan.md com o modelo da projeção (o que se lê, em que granularidade e como cada regra real é chamada em modo de simulação) e as medições da massa de referência.

- [x] T-069-01 Moeda nos documentos e cotações como valores da empresa com vigência, onde faltar (RF-069-07)
- [ ] T-069-01b Venda em outra moeda (exportação): faturamento convertido na data, com a nota em reais; até lá o pedido de venda fica em BRL
- [x] T-069-02 Projeção base de caixa, operação e resultado, com atrasos históricos medidos (RF-069-01, RNF-069-03)
- [x] T-069-03 Choques como dado, cenários combináveis e guardados (RF-069-02, D2)
- [x] T-069-04 Propagação em cascata pelas regras reais em simulação, com o caminho do efeito (RF-069-03, D3, D4, RNF-069-01, CA-069-02, CA-069-03) — o cache no núcleo e o recálculo parcial não foram necessários: a massa de referência fica abaixo de 1 s (plano, seção 6)
- [x] T-069-05 Tela de comparação, o que mais pesa e ações sugeridas; verificador da spec 050 (RF-069-04, D5, CA-069-01)
- [x] T-069-06 Escopo de dados e sigilo em todo resultado (D8, RNF-069-04, CA-069-05)
- [x] T-069-07 Cenário pelo assistente com conferência das premissas (RF-069-05, D6, CA-069-04)
- [x] T-069-08 Cenários vigiados: recálculo agendado, métricas para alertas e regras (RF-069-06, D7, CA-069-06)
- [x] T-069-09 Desempenho medido na bateria sobre a massa da simulação de uso (RNF-069-02, CA-069-07)
