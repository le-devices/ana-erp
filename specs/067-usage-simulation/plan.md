# 067 — Plano

## Fase 1 — simular e achar (T-067-01..05, 05b)

### Personas (T-067-01, D1)
- Migração 074: `ana_system.sim_persona` (nome, rótulo, papel, grupos, taxa de erro humano) com oito personas — vendedor,
  comprador, almoxarife, financeiro, técnico de campo, gestor de projetos, aprovador de compras, planejador da produção.
- Cada uma roda como o usuário robô `sim_<nome>` (criado ou reativado na rodada, sem senha, nunca administrador): esbarra
  nas mesmas permissões, escopos e regras que uma pessoa. O aprovador entra no grupo `sim_aprovadores`, que recebe a
  alçada de compra no preparo da rodada.

### Cenários com semente (T-067-02, D2, RNF-067-02)
- O programa `simulation.scenario` (somente leitura) decide o próximo passo de um cenário a partir do estado (semente,
  instância, passo, resultados até aqui): venda (com serviço, cancelamento, entrega, devolução, pagamento pelo extrato),
  compra (aprovação, ordem — automática quando a esteira está ligada —, recebimento parcial, pagamento, devolução ao
  fornecedor), serviço em campo, produção, projeto e estoque — as mesmas rotinas das trilhas da spec 042, com variação.
- Erros humanos: com a taxa da persona, antes de um passo a persona erra (quantidade negativa, pedido sem itens). A rotina
  precisa recusar com mensagem de negócio; aceitar ou responder com erro técnico é achado.
- O dia é sorteado pela semente (mistura venda 4, compra 2, campo, produção, projeto e estoque 1 cada). Mesma semente,
  mesmos dados de partida, mesma versão: os mesmos passos — testado.

### Executor (T-067-03, D5)
- `ana_simulation` (núcleo): uma rodada por vez; recusa na produção; cada passo é uma execução da persona (o próprio
  COMMIT — as esteiras andam como no uso real); `simulation.probe` espera a automação (esteira) chegar ao estado, com
  prazo. Preparo da rodada (clientes, itens, estoques, técnico, alçada) como quem começou, com nomes da rodada
  (`SIM<nº>…`): nada da empresa é tocado. Opcionalmente liga os passos automáticos das esteiras de compra, campo e produção
  durante a rodada e restaura a configuração no fim.

### Oráculos (T-067-04, D4)
- Por passo: passo que uma pessoa faria recusado, erro técnico, acesso negado à persona, erro humano aceito ou respondido
  com erro técnico, esteira que não andou sozinha no prazo.
- No fim (`simulation.oracles`, somente leitura): conciliações de controle que mudaram (spec 042), lançamento
  desbalanceado, saldo de estoque negativo, etapa de esteira com falha ou automática parada; e, pelo núcleo (os programas
  não veem essas filas), mensagens a conectores esgotadas e rotinas agendadas com erro.
- Cada achado tem impressão digital (categoria + chave): o mesmo furo na rodada seguinte é "persistente"; o que sumiu,
  "resolvido".

### Rotina, relatório e aviso (T-067-05, D6)
- Rotina agendada `uso.simulado` (programa `simulation.start`, só administrador), desligada de fábrica: liga-se na
  instância de testes. Administração → Uso simulado: rodar agora (dias, cenários por dia, semente, esteiras), rodadas,
  relatório por categoria com tendência e os passos que reproduzem cada achado, personas. Achado novo vira aviso no sino.

### GitHub Actions (T-067-05b, D6a)
- `.github/workflows/simulation.yml`: toda noite (02:00 de Brasília) e à mão (com semente): sobe a pilha só com dados de
  demonstração, roda 3 dias × 12 cenários com as esteiras ligadas, publica o resumo e o relatório (artefato) e mantém uma
  issue por achado (`.github/simulation.py`, rótulo `uso-simulado`, impressão digital no título): abre as novas (no
  máximo 20 por noite), comenta as que persistem e fecha as que sumiram.

### O que a primeira rodada já mostrou
- `projects.save_project` é só do administrador: a persona gestor não cria projeto — regra do produto; o cenário passou a
  criar o projeto como administrador, e o gestor faz o resto.
