# 049 — Plano (fase 1 com o Simples — D10; modelo genérico — D11, P21)

## Princípio
O motor só conhece **mecanismos genéricos**: atributo com vigência, lista de
códigos, tabela com vigência, faixa progressiva, indicador apurado da
contabilidade, fórmula fechada, papel contábil. Nenhum nome de tributo,
regime ou alíquota aparece no código (RNF-049-05). O Simples, o ISS, as
retenções e, na fase 3, CBS/IBS/IS chegam como **pacotes de regras** (dados).
Teste de aceite do desenho: a fase 3 entra sem migração e sem mudar programa.

## Dados (migração `064_tax_engine.sql`, esquema `tax`)
- `tax.tax` — tributo: código livre, nome, ordem de cálculo, escopo (`item` ou
  `document`) e **papéis contábeis** (`roles` jsonb: `expense`, `payable`,
  `withheld`, `credit` → chave de `finance.default_account` ou conta).
- `tax.attribute` — definição de atributo fiscal: código, entidade
  (`company`, `party`, `item`, `contract`), tipo (`text`, `number`, `boolean`,
  `date`), lista de códigos opcional e **fonte** opcional (coluna do cadastro
  já existente, ex.: o regime da spec 043 em `base.party.tax_regime`, numa
  lista fechada de colunas permitidas).
- `tax.attribute_value` — valor por entidade **com vigência** (`valid_from`,
  `valid_to`): o regime da empresa num ano, o código de serviço de um
  produto ou projeto, o NCM de um item, a classificação da reforma. Sobrepõe
  a fonte do cadastro quando existe.
- `tax.code` — listas de códigos com vigência (NCM, NBS, itens da lista de
  serviços, CST, cClassTrib, regimes…): `list`, `code`, `description`.
- `tax.table_row` — tabelas de apoio com vigência: `table_name`, `key`,
  `value` (numeric) e `data` (jsonb). Faixas progressivas usam `key` =
  grupo/ordem, `value` = limite superior.
- `tax.indicator` — indicador apurado: `account_sum` (contas por prefixo,
  natureza credora ou devedora, janela de meses antes da data, regra de
  início de atividade: anualizar a média) ou `formula` sobre outros
  indicadores. Ex.: receita de 12 meses, folha de 12 meses, fator R.
- `tax.rule` — regra com vigência: tributo, nome, `criteria` (jsonb: caminho
  do documento → valor, lista ou `{"prefix": …}`), `formulas` (lista
  ordenada de `[nome, expressão]`), `exception_program`, `status` (`draft`,
  `active`, `retired`), pacote, motivo, autor. Ativa é imutável (gatilho);
  mudança = cópia com nova data, que fecha a anterior.
- `tax.test_case`, `tax.calculation` (registro reproduzível, RF-049-11),
  `tax.change` (ativações com autor, motivo e casos — RNF-049-03),
  `tax.package` (pacotes aplicados e hash) e `tax.state` (versão para a cache).
- Empresa: `base.company.activity_start`. Contas novas no plano do produto
  (tributos sobre a receita, a recolher, retidos a compensar, a recuperar,
  salários e encargos, pró-labore) com chaves em `finance.default_account`.
- Grupo de acesso `tax`: só ele e administradores alteram o cadastro.

## Documento normalizado
`doc.operation`, `doc.date`, `doc.total`, `emitter.*` (empresa),
`recipient.*` (pessoa), `contract.*` (projeto) e, por item, `item.code`,
`item.quantity`, `item.unit_price`, `item.amount`, `item.discount` e os
atributos. Todos os atributos de cada entidade (fonte + valores vigentes na
data do fato) entram pelo código do atributo: `emitter.regime`,
`recipient.kind`, `item.service_code`… Derivados genéricos: `same_city`,
`same_uf`.

## Linguagem de fórmulas (`tax.formula`, D4, CA-049-05)
Expressões analisadas por `ast`, aceitas só com nós permitidos: números,
textos, nomes (`amount`, `quantity`, `total`, caminhos `emitter.regime`…,
fórmulas anteriores da regra), `+ - * /`, comparações, `and/or/not`,
`x if c else y`, e as funções genéricas `round`, `floor`, `ceil`, `min`, `max`,
`abs`, `table(tabela, chave[, campo])`, `bracket(tabela, grupo, valor, campo)`,
`indicator(código)`, `tax(código, campo)` (resultado de tributo anterior) e
`has(caminho)`. Tudo em `Decimal`. Validação ao salvar com posição e motivo.

## Seleção (D3, CA-049-03)
Critério = caminho do documento → igual, um de vários, ou prefixo.
Especificidade = (número de critérios, soma dos comprimentos de prefixo).
Empate entre as melhores = conflito: erro no cálculo e recusa na ativação.

## Saídas e contabilização
Saídas reconhecidas de cada regra: `base`, `rate`, `amount` (devido pelo
emitente), `withheld` (retido pelo tomador), `credit` (a recuperar); qualquer
outra saída (CST, código, texto para a nota) vai junto no resultado. O
lançamento usa os papéis do tributo: `amount` → despesa × a recolher;
`withheld` → retido × clientes (o título fica pelo líquido); `credit` →
a recuperar × custo.

## Motor (`tax.engine`, RF-049-01, RNF-049-01/02)
Normaliza, calcula indicadores pedidos pelas fórmulas, escolhe regras por
item/documento, avalia na ordem dos tributos, acumula, explica; regras,
tabelas e atributos em cache pela versão de `tax.state`; `record=True` grava
`tax.calculation`. Data do fato decide as vigências (CA-049-02).

## Programas
`tax.calculate` (serviço exposto), `tax.save_rule`, `tax.copy_rule`,
`tax.activate_rule` (valida, conflitos, roda casos, diferenças, confirmação),
`tax.which_rule`, `tax.save_case`, `tax.run_cases`, `tax.simulate`,
`tax.save_attribute`/`tax.set_attribute`, `tax.import_table` (CSV),
`tax.apply_package`, `tax.watch` (rotina diária: pacote pendente, vigência
terminando sem sucessora, indicador perto de limite declarado na regra) e
o pacote de exemplo `tax.package_br_services` (Simples anexos III e V, ISS,
retenções; "conferir com o contador").

## Integração (T-049-06)
`projects.invoice_project` chama o motor e lança por papéis; título pelo
líquido; cálculo registrado; o cancelamento estorna. As alíquotas de ISS já
gravadas nos projetos viram regras com critério `contract.code` (mesmo ISS de
antes, CA-049-01). Vendas, compras e notas de fornecedor entram nas fases 3/2.

## Verificações (RNF-049-04, 05)
Teste que varre `priv/programs` (fora do pacote) e `src` procurando nomes de
tributo/regime e alíquota multiplicada.

## Testes
`tests/runtime/test_tax.py` (linguagem, seleção, cálculo, faixas, indicadores
com início de atividade, sem banco); integração CA-049-01..05, 08, 09,
desempenho de 200 itens e reprodução.
