# 040 — Plano técnico: dados mestres padronizados

## Visão
```
 master.entities (biblioteca)  ──►  ana_lib.master.core  ◄── programas master.* (expostos)
        │                               │  descrever · buscar · ler · validar · duplicados
        │                               │  salvar (escritor do cadastro) · desativar · apagar
        ▼                               │  mesclar · importar · exportar · pedidos · qualidade
 gatilho master.log_changes ─► master.change_log          ▲
 base.valid_tax_id (banco)                                │ /rpc (sessão)
                                          Estúdio: área "Cadastros" (masterdata.js)
```
- **Um registro, um serviço, uma tela.** Cada entidade é declarada uma vez
  na biblioteca do produto `master.entities`. Como é um programa-semente,
  melhorias chegam pela atualização do produto (spec 028) e o cliente pode
  adaptá-las. Campos próprios do cliente são dados (`master.custom_field`).
  A lista, a ficha, a busca, a importação, a exportação, o histórico e a
  qualidade saem dessa declaração.
- **Escritor.** Cada entidade aponta o programa que grava (os `save_*`
  atuais, que já têm as regras de negócio testadas). Sem escritor, o serviço
  faz o upsert genérico. Antes do escritor, o serviço valida, procura
  duplicados, confere a versão (`xmin`) e aplica a política de aprovação;
  depois, devolve o registro relido.
- **Nenhum caminho contorna (RNF-040-02).** As validações críticas também
  estão no banco: CPF/CNPJ com dígito verificador, por gatilho que só age
  quando o valor muda (registros antigos continuam editáveis). O histórico é
  gravado por gatilho, pegue a alteração a tela, a API, a importação ou um
  programa. O núcleo passa `ana.execution_id` e `ana.origin` à sessão, junto
  com `ana.username`.

## Dados (migração 038)
- **`base.valid_cpf`, `base.valid_cnpj`, `base.valid_tax_id` e
  `base.format_tax_id`.** O gatilho em `base.party` valida e formata o
  documento quando ele muda. O de `base.company` faz o mesmo.
- **`inventory.warehouse.active`**, a única entidade mestre que ainda não
  tinha o campo.
- **`custom jsonb`** em `base.party` e `base.product` (campos próprios do
  cliente) e **`master.custom_field`** com a definição desses campos.
- **`master.change_log`**: quando, entidade, chave, operação, alterações no
  formato `{campo: [antes, depois]}`, quem, origem e execução. Índice BRIN
  na data e índice por entidade e chave. Retenção pela spec 024.
- **`master.change_request`**: entidade, chave, alterações, situação
  (`pending`, `approved`, `rejected`, `applied`), quem pediu, quem decidiu,
  motivo e quando.
- **`master.log_changes()`**: gatilho genérico ligado, pela migração, a
  cada tabela registrada e às tabelas filhas. Ignora `updated_at` e
  `created_at`, mascara campos secretos e não registra nada quando nada
  mudou.
- **Mesclagem** no serviço (Python, com a autorização do contexto, que não
  pode ser forjada): descobre pelo catálogo as chaves estrangeiras que
  apontam para a tabela, move as referências, desativa o duplicado e
  registra tudo, numa transação. Se uma referência não puder mudar (por
  exemplo, a movimentação de estoque imutável), recusa dizendo qual.
- **Índices de trigramas** (`pg_trgm`) nos campos de busca de clientes e
  itens.

## Definição de uma entidade (dicionário em `master.entities`)
```json
{"fields": [{"name": "tax_id", "label": "CNPJ/CPF", "type": "text", "validator": "tax_id",
             "unique": true, "list": true, "search": true, "tab": "Geral"}],
 "tabs": [{"label": "Produção", "writer": "production.save_item_plan", "table": "production.item_plan",
           "fk": "product_id", "fields": [...]},
          {"label": "Fornecimento", "kind": "rows", "table": "supply.supplier_item", "fk": "product_id", ...}],
 "duplicates": [{"field": "tax_id"}, {"field": "name", "similarity": 0.6}, {"field": "email"}],
 "sensitive": ["price"], "permissions": {"view": "user", "edit": "user", "approve": "admin"},
 "quality": [{"label": "Sem CNPJ", "where": "tax_id IS NULL"}]}
```
Identificadores (tabela, colunas) são conferidos contra o catálogo do banco
antes de entrar em qualquer SQL. Valores sempre vão como parâmetros.

## Programas (expostos, chamados pela tela e pela API)
| Programa | Função |
|---|---|
| `master.describe` | Definições, para a tela, já com os campos próprios do cliente |
| `master.search` | Busca, filtros, ordenação e paginação por cursor |
| `master.lookup` | Busca única para os campos de escolha do ERP |
| `master.get` | Registro, abas, versão e pedidos pendentes |
| `master.save` | Validação, duplicados, versão, aprovação e escritor |
| `master.set_active` | Desativar e reativar, inclusive em lote |
| `master.delete` | Apagar só se nunca usado; senão diz onde está em uso |
| `master.history` | Histórico campo a campo |
| `master.duplicates`, `master.merge` | Possíveis duplicados e mesclagem |
| `master.import`, `master.export` | CSV com prévia, ensaio e confirmação; exportação para reimportar |
| `master.requests` | Pedidos de alteração de campos sensíveis: aprovar ou recusar |
| `master.quality` | Indicadores de qualidade, com a ação que corrige |

As buscas de clientes, itens e depósitos de `sales.lookup`,
`supply.lookup` e `production.lookup` delegam a `ana_lib.master.core`. O
formato do retorno não muda.

## Tela
A área **Cadastros** (`priv/www/masterdata.js`) tem:
- à esquerda, as entidades;
- a lista, com busca enquanto se digita, filtros, colunas escolhidas,
  exportação e ações em lote;
- a ficha, com abas geradas pela definição, validação no campo, "Salvar"
  só quando algo mudou, aviso de conflito de versão, aviso de duplicado e
  as abas Histórico e Uso (documentos que usam o cadastro);
- o assistente de importação e o painel de qualidade.

Os atalhos de teclado são os mesmos em todas as entidades.

## Verificação periódica
A regra `master_quality`, na categoria integridade, gera um achado
informativo por entidade quando um indicador de qualidade piora.
