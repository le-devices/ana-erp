# 049 — Plano (fase 1, com o Simples Nacional — D10)

## Visão geral
O motor é uma **biblioteca Python** (`tax.engine`) executada no runtime isolado,
com regras e tabelas no banco (esquema `tax`). Programas do produto chamam
`engine.calculate(documento)`; outros sistemas chamam o serviço exposto
`tax.calculate`. Cada cálculo de documento é guardado (`tax.calculation`) com a
entrada, as regras usadas e o resultado.

## Dados (migração `064_tax_engine.sql`, esquema `tax`)
- `tax.tax` — tributos: código (`iss`, `simples`, `irrf`, `pis_wh`,
  `cofins_wh`, `csll_wh`, `inss_wh`), nome, ordem de cálculo, escopo (`item`
  ou `document`), contas por papel (`expense_key`, `payable_key`,
  `withheld_key`: chaves de `finance.default_account`).
- `tax.rule` — regra com vigência: tributo, nome, `valid_from`/`valid_to`,
  `criteria` (jsonb), `formulas` (jsonb: nome → expressão, em ordem),
  `exception_program`, `status` (`draft`, `active`, `retired`), pacote de
  origem, motivo, autor e datas. Regra ativa é imutável (gatilho); mudança =
  cópia com nova data, que fecha a vigência da anterior.
- `tax.table_row` — tabelas de apoio com vigência: `table_name`, `key`,
  `valid_from`/`valid_to`, `value` (numeric) e `data` (jsonb). Ex.: faixas do
  Simples (`simples_bracket`, chave `III/1`), ISS por município (`iss_city`,
  chave `SP/sao paulo`), repartição do ISS no Simples.
- `tax.test_case` — caso: nome, documento (jsonb), resultado esperado (jsonb),
  data opcional.
- `tax.calculation` — registro reproduzível (RF-049-11): tipo e referência do
  documento, data do fato, entrada, regras (id e versão), resultado, hash.
- `tax.change` — histórico de ativações (RNF-049-03): regra, autor, motivo,
  casos executados e diferenças aceitas.
- `tax.setting` — prefixo das contas de receita (RBT12), contas de folha
  (fator R), limite do fator R (0,28) e margem de aviso (0,02).
- `tax.state` — contador de versão das regras e tabelas, incrementado por
  gatilho: a cache do motor é invalidada quando muda.
- Classificação: `base.product` ganha `ncm`, `nbs`, `service_code` (item da
  lista de serviços), `tax_group`; `projects.project` ganha `service_code`
  e `nbs`; `base.company` ganha `activity_start` (início de atividade).
- Contas novas no plano do produto: tributos retidos a compensar, Simples a
  recolher, deduções da receita (tributos sobre a receita), salários e
  encargos, pró-labore — com chaves em `finance.default_account`.
- Grupo de acesso `tax` (responsáveis tributários): só ele e administradores
  alteram regras, tabelas e casos.

## Linguagem de fórmulas (`tax.formula`, D4, CA-049-05)
Expressões de Python **analisadas** (`ast`) e aceitas só com nós permitidos:
números, textos, nomes conhecidos (`amount`, `quantity`, `rbt12`, `fator_r`,
`emitter.regime`, `recipient.kind`… e fórmulas anteriores da mesma regra),
`+ - * /`, comparações, `and/or/not`, `x if c else y` e as funções
`round(x, n)`, `floor`, `ceil`, `min`, `max`, `abs`, `table(nome, chave)`,
`field(nome, chave, campo)`, `simples_effective(anexo)`,
`simples_share(anexo, tributo)`, `tax(código)`. Tudo em `Decimal`
(RNF-049-02). Nada de atributo arbitrário, índice, chamada desconhecida,
lambda ou compreensão: recusado **ao salvar**, com a posição e o motivo.

## Seleção (D3, CA-049-03)
Critérios: `operation`, `purpose`, `ncm`/`nbs`/`service_code` (prefixo),
`item_group`, `origin_uf`/`origin_city`, `dest_uf`/`dest_city`,
`same_city`, `emitter_regime`, `dest_regime`, `dest_kind` (pessoa física,
jurídica, órgão público), `dest_taxpayer`, `final_consumer`, `cfop`,
`tax_class`, `party` (destinatário), `contract` (projeto). Especificidade =
(número de critérios, comprimento do prefixo de código). Empate entre as
melhores = conflito: **erro** no cálculo e **recusa** na ativação, mostrando
as regras.

## Motor (`tax.engine`, D1, RF-049-01, RNF-049-01)
1. Normaliza o documento (emitente = empresa; destinatário pelo cadastro
   fiscal da spec 043; itens com classificação).
2. Contexto do Simples: RBT12 dos 12 meses anteriores pelas contas de receita
   (início de atividade: média dos meses × 12; no primeiro mês, a receita do
   próprio mês × 12), folha pelas contas de folha, fator R.
3. Para cada tributo, na ordem: escolhe a regra por item (ou no documento),
   avalia as fórmulas e acumula base, alíquota, valor, retenção e a
   explicação (regra, critérios que casaram, valores das fórmulas).
4. Regras e tabelas em cache por versão (`tax.state`).
5. `record=True` grava em `tax.calculation`; recalcular um documento antigo
   usa as regras vigentes na data do fato (CA-049-02).

## Casos de teste e ativação (D6, CA-049-04)
`tax.activate_rule` valida as fórmulas, procura conflitos, roda **todos os
casos** com e sem a mudança e mostra as diferenças; com diferença, exige
`confirm` e motivo; sem diferença, ativa direto. Tudo fica em `tax.change`.
`tax.simulate` calcula qualquer documento numa data escolhida.

## Pacotes de regras (D5, RF-049-06)
O pacote do produto é uma biblioteca semente (`tax.package_br_services`) com
os tributos, as regras e as tabelas de exemplo ("conferir com o contador").
Ele chega pelas atualizações do produto (spec 028) como qualquer programa;
`tax.apply_package` compara com o que está ativo, roda os casos e aplica.
A rotina diária `tax.watch` avisa pacote não aplicado, vigência terminando
sem sucessora e fator R perto do limite (tarefa para o grupo `tax`).

## Integração (D7, T-049-06)
- `projects.invoice_project` chama o motor: Simples (despesa × a recolher),
  ISS (próprio ou retido), retenções federais; o título a receber fica pelo
  líquido; lançamentos nas contas por papel; cálculo registrado. O
  cancelamento (`projects.cancel_invoice`) estorna pelo lançamento.
- Migração do ISS por projeto: cada projeto com alíquota vira uma regra
  `contract` com a mesma alíquota e retenção (CA-049-01, "mesmo ISS").
- Vendas de mercadorias, compras, notas de fornecedor e devoluções entram com
  a fase 2/3 (ICMS, IPI, CBS/IBS), quando o motor tiver esses tributos.

## Verificação de cálculo fora do motor (RNF-049-04)
Teste que varre `priv/programs` procurando alíquota de tributo multiplicada
fora dos programas `tax.*`.

## Testes
- `tests/runtime/test_tax.py`: linguagem de fórmulas, seleção e cálculo puro,
  Simples (faixas, início de atividade, fator R), sem banco.
- Integração: CA-049-01..05 e 08, desempenho de 200 itens, reprodução.
