# 078 — Formação de preço

Situação: especificada (27/11/2026); na fila depois da 077 fase 1.

## Problema
Hoje o preço de venda é **um número no cadastro do item**. O pedido usa esse
número ou o que a pessoa digitar; o único ajuste automático é o desconto ou
acréscimo da condição de pagamento (spec 031). Não há tabela de preço por
cliente, grupo ou região, preço por faixa de quantidade, desconto do cliente
ou do item, campanha com vigência, frete calculado nem limite de desconto. Na
compra, o catálogo do fornecedor tem um preço por item (spec 013), mas não há
**preço líquido** nem **custo efetivo** da aquisição (frete, seguro, impostos
que viram custo, créditos de impostos que não viram).

Na prática, cada empresa resolve isso fora do ERP: planilha de preços, desconto
combinado por telefone, vendedor que digita o preço "de cabeça", margem que
ninguém confere antes do pedido sair. E quem avalia um ERP para vender
pergunta logo: "como eu monto a minha política de preços aqui?".

O ANA já tem as peças: o **motor de impostos** (spec 049), que escolhe regras
por critérios, vigência e especificidade, calcula com fórmulas fechadas e
explica cada linha; o **construtor de condições** (spec 020); a **aprovação por
quatro olhos** de cadastros sensíveis (spec 040); os **valores da empresa**
com vigência (spec 065); o **ensaio universal** (spec 056). Falta uma
política de preço feita de dados, calculada por um único serviço e explicada
na tela.

## Decisões
- **D1 — Um único serviço forma o preço para todo o sistema.** Biblioteca
  `pricing.engine` (e rotina `pricing.calculate` para API, assistente e outros
  sistemas): recebe um documento (lado venda ou compra, data, parte, itens com
  quantidade e unidade, canal, região, condição de pagamento, frete pedido) e
  devolve, por item e no total, cada **componente** do preço com base, valor,
  de onde veio e a **explicação** (qual regra valeu e por quê). Nenhum
  programa calcula preço, desconto ou frete por conta própria: pedido de venda,
  orçamento, fatura, pedido de compra, nota do fornecedor, portal e API chamam
  o serviço.
- **D2 — O esquema de preço é dado.** Um **esquema** é a sequência de linhas
  que leva do preço de partida ao total, por exemplo:
  1. preço de tabela;
  2. desconto do cliente;
  3. desconto do item ou do grupo;
  4. desconto por quantidade;
  5. campanha;
  6. **subtotal (preço líquido)**;
  7. frete e seguro;
  8. acréscimo ou desconto financeiro da condição de pagamento;
  9. impostos (pelo motor da spec 049, sobre as bases que o esquema entrega);
  10. **total**.

  Cada linha diz:
  - o componente;
  - a base de cálculo: o preço, um subtotal ou a soma de linhas;
  - se soma, subtrai ou só informa;
  - se é obrigatória;
  - se a pessoa pode mudá-la no pedido, e até quanto.

  Esquemas têm vigência e versão e são escolhidos por critérios (lado, tipo de
  operação, canal). A empresa monta o seu; o produto entrega esquemas de
  exemplo.
- **D3 — Componentes são uma lista extensível por dado.** Um **componente**
  (preço de tabela, desconto do cliente, desconto do item, desconto por
  quantidade, campanha, frete, seguro, acréscimo financeiro, comissão…) diz:
  - como calcula: valor fixo, valor por unidade, percentual, faixa (por
    quantidade ou valor) ou fórmula fechada;
  - em que ordem procura as suas regras: da mais específica para a mais
    geral (cliente + item; grupo de clientes + item; cliente + grupo de itens;
    só item);
  - o arredondamento.

  Componente novo é dado, não programa. Os nomes são os do ANA (nada de
  códigos opacos): a tela mostra "Desconto do cliente", não um código.
- **D4 — Regras de preço: valor, vigência e critérios — o mecanismo da 049.**
  Uma **regra de preço** guarda, para um componente:
  - o valor, o percentual ou a faixa;
  - a moeda e a unidade;
  - o início e o fim da vigência;
  - os critérios: parte ou grupo de partes, item ou grupo de itens, região,
    canal, quantidade mínima e qualquer atributo do documento.

  A escolha usa a **mesma regra da spec 049**: vale a regra vigente na data do
  documento, a mais específica vence e empate é erro de configuração apontado
  na tela, nunca escolha silenciosa. Fórmulas usam a mesma linguagem fechada,
  as tabelas e as faixas da 049; nada de código livre. O motor de preço não
  conhece nenhum componente pelo nome (P21).
- **D5 — Cadastro rápido, mudança segura.**
  - **Tabelas de preço** editadas em grade, com:
    - importação e exportação (CSV);
    - "copiar com nova vigência";
    - reajuste em lote (todos os itens do grupo X +4% a partir de 1º/1),
      ensaiado antes (spec 056).
  - Mudança de preço e de desconto acima de um limite passa por **quatro
    olhos** (spec 040), com antes e depois no histórico.
  - Casos de teste de preço ("cliente A, 10 unidades do item X em março dá
    R$ 1.234,00") rodam antes de publicar uma regra, um reajuste ou um
    esquema e mostram o que mudou (como na spec 049, D6).
  - A pergunta "qual preço vale?" responde para um caso informado, com cada
    linha e a regra de origem.
- **D6 — No pedido: preço explicado, desconto com limite.**
  - O preço vem sozinho ao escolher o item e a quantidade. Um clique mostra o
    **esquema aplicado**: cada linha, o valor e a regra de origem.
  - A pessoa só muda as linhas que o esquema permite, até o limite do papel
    dela. Por exemplo, o vendedor dá até 5% e o gerente até 12%.
  - Acima do limite, o pedido não é recusado: vira **tarefa de aprovação**
    (spec 039/051) com a margem resultante. O pedido segue retido até a
    aprovação.
  - Margem abaixo do mínimo da empresa (valor da empresa, spec 065) avisa
    antes de salvar, com o custo usado.
  - O preço calculado fica gravado no documento com as regras e versões
    usadas: recalcular depois dá o mesmo resultado (como RF-049-11). Mudar a
    tabela nunca muda um pedido já feito.
- **D7 — Compra: preço líquido e custo efetivo.** O mesmo serviço, no lado
  compra, parte do catálogo do fornecedor (spec 013) e calcula:
  - **preço líquido:** com o desconto do fornecedor por quantidade ou
    contrato;
  - **custo efetivo:** soma frete, seguro e os impostos que são custo, e tira
    os créditos (ICMS, PIS/COFINS, IPI conforme o regime, pela spec 049).

  O custo efetivo é o que entra no estoque (spec 038) e no custo dos cenários
  (spec 069). O preço líquido é o que a nota do fornecedor é conferida contra
  (spec 059, tolerância).
- **D8 — Integrado de ponta a ponta (P17).**
  - Fatura e nota eletrônica (spec 059) recebem o detalhamento já calculado:
    descontos, frete e seguro destacados, nas bases dos impostos certos.
  - Contabilidade recebe descontos concedidos, frete cobrado e acréscimo
    financeiro nas contas próprias (papéis declarados no componente, como os
    tributos da 049).
  - Condição de pagamento (spec 031): o acréscimo ou desconto financeiro sai
    da condição e passa a ser um componente do esquema. A condição continua
    sendo o lugar onde a pessoa o configura.
  - Cenários (spec 069) ganham os choques "preço de venda" e "desconto"
    (dado no catálogo de choques).
  - O uso simulado (spec 067) vende com tabelas, faixas e campanhas, com um
    oráculo de preço (o preço do pedido confere com os casos de teste).
  - O assistente (spec 052) responde "por que este preço?" com a explicação
    do serviço.
- **D9 — Permissões e sigilo.**
  - Custo e margem só aparecem para quem pode vê-los (como RNF-008-02): o
    vendedor vê o preço e o próprio limite de desconto, não o custo.
  - Quem cadastra regras de preço é um grupo de acesso próprio ("preços"),
    como o grupo "tax" da spec 049.
  - O portal do cliente (spec 016) vê só o preço final dele.
- **D10 — Fases.**
  1. Venda: serviço, esquema, componentes, regras com vigência e
     especificidade, tabelas em grade, casos de teste, explicação no pedido,
     limite de desconto por papel com aprovação, margem mínima.
  2. Compra: preço líquido e custo efetivo, conferência da nota do
     fornecedor.
  3. Campanhas e integrações restantes: campanhas com período e quantidade
     máxima, comissão como componente, choques nos cenários, oráculo no uso
     simulado.

## O que a pessoa deixa de fazer (P19)
- Manter a planilha de preços ao lado do ERP e copiar preço dela para o pedido.
- Ligar para o gerente para saber se pode dar mais 3% de desconto.
- Descobrir depois do faturamento que o pedido saiu com margem negativa.
- Calcular à mão o custo real de uma compra com frete e impostos.

## Requisitos funcionais
- **RF-078-01** Serviço de formação de preço (D1) com resultado por item e
  total e a explicação de cada linha.
- **RF-078-02** Esquemas de preço como dado, com vigência, versão e escolha
  por critérios (D2).
- **RF-078-03** Componentes como dado: tipo de cálculo, ordem de procura das
  regras, arredondamento, papéis contábeis (D3).
- **RF-078-04** Regras de preço com vigência, critérios e especificidade pelo
  mecanismo da spec 049; conflito apontado na tela (D4).
- **RF-078-05** Tabelas de preço em grade, importação e exportação,
  "copiar com nova vigência", reajuste em lote ensaiado (D5).
- **RF-078-06** Casos de teste de preço rodados antes de publicar; "qual
  preço vale?" para um caso informado (D5).
- **RF-078-07** No pedido: preço automático, esquema explicado, mudança
  limitada pelo esquema e pelo papel, aprovação acima do limite, aviso de
  margem mínima (D6).
- **RF-078-08** Registro do preço calculado com regras e versões; recalcular
  dá o mesmo resultado (D6).
- **RF-078-09** Compra: preço líquido e custo efetivo; custo efetivo no
  estoque e nos cenários; preço líquido na conferência da nota (D7).
- **RF-078-10** Integração com fatura, nota eletrônica, contabilidade,
  condição de pagamento, cenários, uso simulado e assistente (D8).
- **RF-078-11** Campanhas com período, público e quantidade máxima; comissão
  como componente (D10, fase 3).

## Requisitos não funcionais
- **RNF-078-01 (desempenho).** Medidos na bateria:
  - preço de um item no pedido em até 50 ms (a tela responde enquanto a
    pessoa digita, spec 050);
  - um pedido de 200 linhas em até 1 s;
  - reajuste em lote de 10 mil itens ensaiado em até 10 s.

  Regras e esquemas ficam em memória por versão, como o motor da spec 049.
- **RNF-078-02 (escrita).** Calcular preço não grava nada. Grava só o
  resultado no documento, junto com o documento, e as regras quando
  cadastradas. O valor fica no orçamento de escrita da spec 063.
- **RNF-078-03 (segurança).** Custo e margem nunca saem para quem não pode
  vê-los, nem na explicação nem na API (D9). Limite de desconto checado no
  servidor, nunca só na tela.
- **RNF-078-04 (legislação é dado, P21).** Nenhum componente, esquema ou
  regra no código. Teste de aceite: um componente novo ("taxa de
  urgência") entra só com dado e funciona no pedido, na fatura e na
  contabilidade.

## Critérios de aceite
- **CA-078-01** Cliente do grupo "distribuidor", 120 unidades do item X em
  março:
  - preço de tabela R$ 10,00;
  - desconto do grupo 8%;
  - desconto por quantidade de 5% (faixa de 100 a 499);
  - frete 2% sobre o líquido.

  O total bate com o caso de teste. A explicação mostra as quatro linhas e a
  regra de cada uma.
- **CA-078-02** Uma regra nova com vigência a partir de abril não muda o preço
  de um pedido de março, nem de um pedido já gravado.
- **CA-078-03** Duas regras igualmente específicas para o mesmo caso: a tela
  aponta o conflito e o cálculo recusa, com as duas regras nomeadas.
- **CA-078-04** O vendedor dá 4% (dentro do limite): o pedido segue. Ele dá
  9%: o pedido fica retido e o gerente recebe a tarefa com a margem; aprovado,
  segue.
- **CA-078-05** Reajuste de +4% no grupo Y a partir de 1º de janeiro:
  - o ensaio mostra quantos itens e quais casos de teste mudam, e nada é
    gravado;
  - confirmado, entra com aprovação de outra pessoa.
- **CA-078-06** Compra de 100 unidades a R$ 50,00 com frete de R$ 200,00 e
  ICMS recuperável: o custo efetivo no estoque é o líquido + frete − crédito,
  e a nota do fornecedor é conferida contra o preço líquido.
- **CA-078-07** O vendedor vê o preço e o limite de desconto, mas não o custo
  nem a margem; o gerente vê os três.
- **CA-078-08** Componente novo "taxa de urgência" (3% sobre o líquido) entra
  só com dado e aparece no pedido, na fatura e no lançamento contábil.
