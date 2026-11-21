# 038 — Processos integrados e conciliação automática

## Problema
O dono do produto exige que **tudo o que for construído seja integrado** e
automatizado no que for necessário, para eliminar reconciliações manuais que
expõem o ERP a erro humano (constituição P17). Uma auditoria módulo a módulo
(outubro/2026), com evidência no banco de demonstração, encontrou as lacunas
abaixo.

Evidência no banco de demonstração:
- **Clientes:** títulos a receber em aberto somam R$ 2.800.338,85; a conta
  1.1.2 tem R$ 2.795.238,85. A diferença vem de títulos sem lançamento.
- **Fornecedores:** títulos a pagar somam R$ 257.171,80; a conta 2.1.1 tem
  R$ 255.171,80. Créditos de devolução são títulos "a pagar" contabilizados em
  2.1.2, e o título não sabe a sua conta de controle.
- **Bancos:** a conta 1.1.1 está negativa (−R$ 20.861,78). Tarifas,
  transferências e aplicações do extrato são "ignoradas" sem lançamento, e o
  extrato não traz saldo.
- **Estoque:** as movimentações não têm valor. A conta 1.1.3 é debitada no
  recebimento de compras e nunca creditada nas vendas; a conta 5.1.1 (custo
  das mercadorias vendidas) existe, mas nenhum programa a usa.

## Inventário de lacunas (L-038-nn)

### Estoque e custos
- **L-01** Estoque sem valor: a movimentação guarda só a quantidade. Cada
  programa usa um custo diferente: preço do pedido de compra, custo padrão,
  preço de venda ou valor digitado. Não existe custo médio.
- **L-02** A venda (fatura de pedido e expedição) baixa o estoque sem lançar o
  custo da mercadoria vendida.
- **L-03** A entrada manual de estoque não gera lançamento. Também não existem
  ajuste de saída, perda, descarte nem inventário físico (contagem) com
  ajuste automático.
- **L-04** Peças usadas em OS e materiais de projeto baixam o estoque sem
  lançamento. Na OS de projeto, a peça vira despesa do projeto pelo preço de
  venda, não pelo custo.
- **L-05** A devolução de cliente entra no estoque sem valor e sem estorno do
  custo. A quarentena não tem liberação nem descarte.
- **L-06** Produção: a requisição usa o custo padrão, diferente do custo do
  estoque, e o produto acabado entra sem valor até o encerramento da ordem.

### Compras
- **L-07** O recebimento gera o título a pagar pelo preço do pedido. Não há
  registro da nota do fornecedor nem confronto pedido × recebimento × nota:
  divergência de preço, quantidade ou frete vira ajuste manual.
- **L-08** Não há devolução ao fornecedor (estorno do recebimento), nem frete
  e despesas acessórias da compra compondo o custo do estoque.
- **L-09** Despesa de projeto com fornecedor não gera título a pagar nem
  lançamento.

### Logística
- **L-10** O custo do frete fica só na expedição: não gera título para a
  transportadora nem despesa. O frete cobrado do cliente entra como receita
  de vendas.

### Financeiro
- **L-11** O título não sabe a sua conta de controle (clientes, fornecedores,
  créditos de clientes), o que impede conciliar o razão auxiliar com a
  contabilidade.
- **L-12** O pagamento a menor baixa o título inteiro e lança a diferença como
  tarifa: o saldo devedor do cliente some. O pagamento a maior vira juros sem
  regra.
- **L-13** O crédito de devolução não é compensado com títulos em aberto do
  mesmo cliente: fica um título a pagar e outro a receber.
- **L-14** Linhas do extrato sem título só podem ser "ignoradas", sem
  lançamento: tarifas, IOF, rendimentos, transferências entre contas próprias
  e aplicações.
- **L-15** O extrato não traz saldo inicial e final: não há confronto
  automático entre o saldo do banco e a conta contábil.
- **L-16** A conciliação bancária roda só por botão depois da importação, sem
  rotina agendada. O extrato entra só por arquivo, sem conector.
- **L-17** A cobrança paga no gateway é lançada direto no banco. O repasse do
  gateway (lote líquido de tarifas) não casa com nenhuma regra.
- **L-18** As faturas de pedido de venda e de OS não podem ser canceladas (só
  a de projeto): o estorno de título, lançamento e estoque é manual.
- **L-19** Não há fechamento de período: um lançamento pode entrar com data
  num mês já conciliado e alterá-lo sem aviso.
- **L-20** Nenhuma conciliação automática entre os subsistemas e a
  contabilidade.

### Projetos
- **L-21** O custo das horas (custo-hora × horas aprovadas) é só gerencial: o
  resultado do projeto no painel difere do contábil.
- **L-22** O aceite do entregável pelo cliente não conclui o marco ligado a
  ele. Concluir e faturar marcos, e faturar as horas do mês, é manual: não há
  esteira de projetos.

### Automação recorrente
- **L-23** As rotinas recorrentes não vêm prontas para agendar:
  conciliação bancária, rateio mensal, faturamento de horas, sugestão de
  reposição e encerramento de ordens concluídas.

## Requisitos funcionais
- **RF-038-01 (L-01, L-02, L-03, L-04, L-05, L-06)** Valorização permanente
  do estoque.
  - Cada movimentação tem motivo, custo unitário e valor.
  - O custo médio ponderado móvel por item é mantido pelo banco, sob trava
    da linha do item.
  - Entrada com custo informado (compra, produção) recalcula a média; saída,
    transferência e devolução usam a média vigente.
  - O banco lança a contabilidade de cada movimentação valorizada, em um
    lançamento por documento, na mesma transação, conforme a regra de
    contabilização do motivo, ajustável pelo cliente (P13). Nenhum programa
    consegue movimentar estoque sem o lançamento correspondente.
  - Motivos e lançamentos padrão:

    | Motivo | Débito | Crédito |
    |---|---|---|
    | compra | estoque | recebimentos a faturar |
    | venda | custo das mercadorias vendidas | estoque |
    | peça de OS | custo das mercadorias vendidas | estoque |
    | material de projeto | custos de projetos | estoque |
    | devolução de cliente | estoque | custo das mercadorias vendidas |
    | ajuste de entrada | estoque | ganhos de estoque |
    | ajuste de saída, perda, descarte | perdas de estoque | estoque |
    | requisição de produção | em elaboração | estoque |
    | entrega de produção | estoque | em elaboração |
    | transferência | sem lançamento | sem lançamento |

- **RF-038-02 (L-03, L-05)** Inventário físico e ajustes.
  - Contagem por depósito: a diferença vira movimentação de ajuste valorizada
    e lançada, com motivo e responsável.
  - Saída por perda ou descarte.
  - Liberação da quarentena: transferência para o depósito ou descarte.
- **RF-038-03 (L-10)** Frete.
  - Na expedição, o custo gera título a pagar à transportadora (despesa de
    frete × fornecedores).
  - O frete cobrado do cliente vai para conta própria de receita de frete.
- **RF-038-04 (L-11, L-20)** Conciliação automática dos razões auxiliares.
  - O título guarda a sua conta de controle.
  - O banco calcula, para cada razão auxiliar, o saldo auxiliar, o saldo
    contábil e a diferença: clientes, fornecedores, créditos de clientes,
    estoque (valor × conta), recebimentos a faturar, em elaboração e cada
    banco (último saldo do extrato × conta).
  - Também aponta documentos sem lançamento: faturas, recebimentos,
    expedições com frete e movimentações valorizadas.
  - Tela "Conciliações" com detalhamento até o documento.
  - Verificação periódica (spec 033, categoria integridade) que avisa o
    administrador quando uma diferença deixa de ser zero.
- **RF-038-05 (L-12, L-13)** Baixas exatas.
  - Pagamento a menor deixa o saldo em aberto num título residual (mesmo
    documento, com sufixo). A diferença só vai para tarifa ou desconto
    concedido se estiver dentro da tolerância configurada.
  - Pagamento a maior acima da tolerância vira crédito do cliente.
  - Créditos de cliente são compensados automaticamente com os títulos em
    aberto do mesmo cliente, do mais antigo ao mais novo, com lançamento
    (créditos de clientes × clientes) e registro da compensação. A
    compensação automática é ligável por política.
- **RF-038-06 (L-14, L-15, L-16)** Extrato completo e conciliação agendada.
  - Regras de lançamento para linhas sem título: descrição ou documento →
    conta, centro de custo e memorando. Exemplos: tarifa, IOF, rendimento.
  - Transferências entre contas próprias são casadas automaticamente (mesmo
    valor com sinal oposto, ±2 dias).
  - O extrato guarda o saldo final informado. A importação concilia
    automaticamente, e uma rotina agendável concilia todas as contas.
- **RF-038-07 (L-17)** Gateway.
  - A cobrança paga vai para a conta "valores a receber do gateway".
  - O repasse no extrato casa com o conjunto de cobranças pagas daquele
    gateway cujo líquido soma o valor da linha.
- **RF-038-08 (L-18)** Cancelamento por documento das faturas de pedido e de
  OS, enquanto os títulos estiverem em aberto: estorno do lançamento, dos
  títulos e das cobranças, retorno do estoque com o mesmo valor e retorno do
  documento ao estado anterior. Nunca apaga histórico.
- **RF-038-09 (L-19)** Fechamento de período: o administrador fecha um mês e
  o banco recusa lançamentos com data até a data fechada. Reabrir exige
  administrador e fica auditado.
- **RF-038-10 (L-07, L-08, L-09)** Compras integradas.
  - Política de nota do fornecedor:
    - **pelo recebimento** (padrão atual): o título nasce no recebimento,
      pelo preço do pedido;
    - **por confronto**: o recebimento credita "recebimentos a faturar", e a
      nota do fornecedor (número, valor, vencimentos) baixa esse saldo e
      gera o título. Divergência dentro da tolerância é aceita
      automaticamente; acima dela, a nota fica pendente com motivo.
  - Devolução ao fornecedor: estorno do recebimento com valor e título de
    crédito.
  - Despesa de projeto com fornecedor gera o título a pagar e o lançamento.
- **RF-038-11 (L-21)** Custo das horas aprovadas apropriado ao projeto, em
  lançamento mensal agendável: custos de projetos × mão de obra apropriada.
- **RF-038-12 (L-22)** Projetos.
  - O marco pode estar ligado a uma atividade com entregável: o aceite do
    cliente conclui o marco.
  - Esteira de projetos: marco concluído → fatura → cobrança → recebimento;
    horas aprovadas do mês → fatura.
- **RF-038-13 (L-23)** Rotinas recorrentes do produto, oferecidas como
  agendamentos prontos (inativos até o administrador ligar):
  - conciliação bancária diária;
  - verificação das conciliações;
  - compensação de créditos;
  - rateio mensal;
  - apropriação das horas;
  - faturamento mensal de horas;
  - sugestão de reposição.

## Requisitos não funcionais
- **RNF-038-01** Contabilização no banco, por instrução e não por linha:
  inserir 10.000 movimentações num comando gera um lançamento por documento,
  em menos de 2 s.
- **RNF-038-02** Travas sempre na mesma ordem (item por id) para não haver
  impasse entre vendas e recebimentos simultâneos do mesmo item.
- **RNF-038-03** Dados existentes:
  - A migração valoriza as movimentações antigas, em ordem, pelo melhor
    custo conhecido: custo padrão, depois preço do fornecedor, depois zero.
    Não lança contabilidade retroativa.
  - O programa "ajuste inicial de estoque" lança, uma vez e auditado, a
    diferença entre o valor do estoque e a conta contábil.
- **RNF-038-05** Usabilidade (requisito do dono; spec 020):
  - Automático por padrão: o usuário não escolhe contas nem motivos nem
    custos nos fluxos do dia a dia; o programa sabe o motivo, e o banco
    calcula custo e lançamento.
  - Cada documento mostra o que gerou (movimentação com valor, título,
    lançamento) com link, e cada tela oferece o próximo passo.
  - "Conciliações" responde numa olhada "está tudo batendo?": verde quando a
    diferença é zero; quando não é, diz em português o que diverge e leva
    direto aos documentos e à ação que corrige (ex.: "3 títulos sem
    lançamento" → lista → abrir).
  - Contagem de estoque como planilha: digita só o contado; o ERP mostra
    saldo, diferença e valor antes de confirmar.
  - Erros de negócio dizem o que fazer (ex.: "mês de setembro fechado:
    peça ao administrador para reabrir ou use a data de outubro").
- **RNF-038-04** Compatibilidade (P16): programas de clientes que inserem
  movimentações sem motivo continuam funcionando, como ajuste. A divergência
  aparece na conciliação, nunca em silêncio.

## Critérios de aceite
- **CA-038-01** Comprar 10 un. a R$ 10 e depois 10 un. a R$ 20 → custo médio
  R$ 15. Vender 5 → custo das mercadorias vendidas de R$ 75 no lançamento da
  venda, e estoque 15 un. / R$ 225 igual à conta de estoque.
- **CA-038-02** Uma movimentação inserida por qualquer caminho (inclusive SQL
  direto) sem lançamento não existe: o lançamento é criado na mesma
  transação.
- **CA-038-03** A contagem com diferença gera ajuste valorizado e lançado; a
  conciliação de estoque fica zerada.
- **CA-038-04** A expedição com frete gera título da transportadora e
  despesa; o frete cobrado vai para a receita de frete.
- **CA-038-05** Depois de vender, receber, devolver, produzir e baixar em
  extrato, todas as conciliações dão diferença zero. Uma diferença
  provocada de propósito aparece na tela e gera aviso.
- **CA-038-06** Pagamento de R$ 90 sobre título de R$ 100 (tolerância de
  R$ 1) → título residual de R$ 10 em aberto.
- **CA-038-07** Uma devolução de R$ 50 com título de R$ 100 em aberto →
  compensação automática; o título fica com R$ 50.
- **CA-038-08** A linha "TARIFA PACOTE" do extrato vira lançamento de
  tarifa pela regra. A transferência entre duas contas próprias é casada sem
  intervenção. O saldo do extrato bate com a conta contábil.
- **CA-038-09** Repasse do gateway com três cobranças pagas → casado
  automaticamente; a conta do gateway zera.
- **CA-038-10** Cancelar a fatura de um pedido devolve estoque, títulos e
  lançamento ao estado anterior; as conciliações continuam zeradas.
- **CA-038-11** Com o mês fechado, um lançamento datado nele é recusado.
- **CA-038-12** Por confronto: a nota igual ao recebimento é aceita
  sozinha; a nota com diferença acima da tolerância fica pendente; a conta
  de recebimentos a faturar zera depois da nota.
- **CA-038-13** O aceite do entregável conclui o marco, e a esteira de
  projetos fatura o marco.

## Fases
1. **Fundação:** RF-01 a RF-04 e RF-09, mais o ajuste inicial. Estoque com
   valor e lançamento automático, inventário físico, frete, conciliações e
   fechamento.
2. **Financeiro:** RF-05 a RF-08.
3. **Compras e projetos:** RF-10 a RF-12.
4. **Rotinas:** RF-13.

## Decisões tomadas (podem ser revistas pelo dono do produto)
- **Custo médio ponderado móvel** por item, para a instância inteira (todos
  os depósitos e empresas). Custo por empresa ou estabelecimento fica para
  quando houver mais de uma empresa com estoque.
- A política de nota do fornecedor continua **pelo recebimento** por padrão;
  o confronto é opção do cliente.
- A compensação automática de créditos vem **ligada**.

## Situação
Implementada (fases 1 a 4). Notas da implementação das fases 2–4:
- Duas contas bancárias na mesma conta contábil não entram na conciliação
  "banco × extrato" (o saldo de um extrato só se compara com uma conta
  contábil própria).
- Repasse do gateway que casa com cobranças de dois gateways diferentes
  fica para a bancada (ambíguo).
- As rotinas do produto (conciliação diária, compensação, apropriação de
  mão de obra, rateio, faturamento de projetos, reposição) nascem
  **desligadas** em Agendamento, rodando como administrador; uma rotina
  apagada ou renomeada não é recriada.
- O modelo de processo "Faturamento do projeto" roda as tarefas
  automáticas como `admin` (faturar exige gestor ou administrador); a
  validação do BPM recusa publicar com usuário de execução inexistente.
