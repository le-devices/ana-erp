# 065 — Plano: valores da empresa (fase 1)

## Modelo (T-065-01)
Migração `067_company_values.sql`, no esquema do núcleo (`ana_system`, que os programas não leem — P10):

- `company_value`: a **definição** — nome hierárquico (`financeiro.margem_minima`), descrição, área dona
  (o primeiro segmento do nome, por padrão), tipo (`text`, `integer`, `decimal`, `date`, `boolean`, `month`,
  `reference`), forma (`single`, `list`, `selection`), tipo de cadastro referenciado, sensível (quatro olhos),
  motivo obrigatório, igual em todos os ambientes (para o transporte da fase 2) e arquivado.
- `company_value_version`: o **conteúdo**, em versões com vigência (`valid_from`), opcionalmente só de uma
  instância (desenvolvimento, teste, produção) e/ou de uma empresa do grupo (`base.company`). Cada versão tem
  um conteúdo fixo (JSON tipado) **ou** uma expressão da lista fechada (D5). Situação: `pending` (aguarda a
  segunda pessoa), `active`, `refused`, `withdrawn`, `replaced` (outra versão ativa tomou o mesmo lugar). O
  histórico nunca é apagado.
- `company_value_change`: a trilha de cada mudança, com antes e depois, quem e o motivo (D9, spec 024).
- `value_reference_kind`: os cadastros que um valor pode apontar (centro de custo, depósito, parceiro, conta,
  produto, empresa), como **dado**. Um gatilho genérico em cada um desses cadastros recusa apagar ou renomear um
  registro enquanto uma versão em vigor ou futura apontar para ele, dizendo quais valores o usam (CA-065-03).

**Resolução** (D2, D3): entre as versões ativas com `valid_from` até a data de referência, vale a mais
específica (instância e empresa > só instância > só empresa > geral) e, entre as igualmente específicas, a mais
recente. A data de referência é hoje no fuso da empresa (`ANA_TIMEZONE`) ou a informada pela rotina
(reprocessar um mês antigo lê o valor daquela época).

## Expressões num só lugar (T-065-04)
`base.resolve_value_expression(expressão, data, fuso)` é a **única** implementação da lista fechada:
`today`, `yesterday`, `tomorrow`, `now`, `today±N` (dias), início e fim do mês e do ano (atual, anterior,
próximo mês), próximo e anterior dia útil (fins de semana e feriados do agendamento, spec 018),
`open_period±N` (meses, a partir de `financeiro.periodo_aberto`), `current_user` e `user_cost_center`. A
lista com rótulos e o tipo do resultado vem de `base.value_expressions()`, ao lado. O agendador passa a
resolver os modelos `{{today}}` etc. por ela (RF-065-11): os nomes de hoje são casos da lista e o texto
resolvido é o mesmo; o que não é da lista continua como estava.

## Rápido e sem escrita na leitura (T-065-02)
`ana_values` mantém as definições e versões ativas numa tabela ETS por nó, carregada na partida e por
nome quando chega o NOTIFY `ana_value` (emitido na mesma transação da mudança, logo só depois do COMMIT).
Valor fixo: leitura só em memória. Expressão: uma consulta de leitura à função acima. Nunca há escrita na
leitura nem ciclo periódico. O mesmo aviso acorda as telas abertas (evento `values` do fluxo ao vivo, spec
062). Medido na bateria: bytes de WAL de uma execução com centenas de leituras contra uma sem leitura, e o
tempo por leitura.

## Leitura (T-065-03)
- Python: `ana.value(nome, at=None, company=None)` devolve o valor já no tipo (inteiro, `Decimal`, `date`,
  `bool`, lista); a forma seleção chega como `ana.Selection` (`x in sel`). Nome inexistente:
  `VALUE_NOT_FOUND`.
- SQL: `base.company_value(nome [, data [, empresa]])` (texto), `base.company_value_list(...)` (`text[]`,
  para `= ANY(...)`) e `base.company_value_matches(nome, candidato [, data [, empresa]])` — só leitura,
  `SECURITY DEFINER`, com a mesma resolução. A instância vem de `ana.instance`, fixada pelo núcleo no início
  de cada transação de execução.
- Cada valor lido por `ana.value` fica no registro da execução (`execution.values_read`: nome, versão,
  valor) — "com que margem mínima essa aprovação foi decidida" (RNF-065-02).

## Tela e governança (T-065-05, T-065-06)
Administração → **Valores da empresa**: agrupada por área, busca, valor vigente hoje, próxima vigência,
linha do tempo das versões, prévia de expressão, aprovações pendentes e histórico com antes e depois.
- Ver: qualquer pessoa da empresa. Alterar: administradores e grupos com o padrão do valor ou da área
  (`financeiro.*`) em "Valores da empresa que alteram" (novo campo do grupo).
- Sensível: a versão fica pendente até outra pessoa com permissão aprovar; o banco garante que quem pediu
  não decide. Motivo obrigatório quando marcado.
- Credenciais recusadas (`VALUE_SECRET`), pelo nome ou pelo conteúdo, apontando o cofre dos conectores.
- Versões passadas não se apagam; uma versão futura ou pendente pode ser retirada.

## Fase 2
- **Referências (T-065-07).** `{{valor:nome}}` nos parâmetros dos agendamentos (resolvido no dia, para o usuário
  da rotina; sozinho, chega no tipo do valor), nas condições e parâmetros das esteiras e processos (lido quando a
  regra roda), nas variantes (`company_value`, spec 045) e no limiar das regras de alerta de métrica (lido a cada
  verificação). Nas fórmulas do motor de impostos, `company_value('nome')` lê o valor na data do fato. As
  verificações periódicas (spec 033) não têm limiares configuráveis: nada a referenciar.
- **Mantidos por rotinas (T-065-08).** `ana.set_value(nome, valor)` — só uma rotina listada em "Mantido pelas
  rotinas" do valor. Conferido na hora (tipo, credencial) e gravado logo depois do COMMIT da rotina (falhou, nada
  muda; simulação, nada muda; ensaio, aparece entre os efeitos retidos), como versão a partir de hoje, com a
  rotina e o usuário na trilha. O fechamento (`finance.close_period`) mantém `financeiro.periodo_aberto` e a
  contagem confirmada (`inventory.count`) mantém `estoque.ultimo_inventario`.
- **Onde é usado (T-065-09).** Programas e bibliotecas que citam o nome literalmente (`ana.value`,
  `ana.set_value`, `base.company_value*`, `{{valor:}}`), rotinas que o mantêm, variantes, agendamentos, regras de
  alerta, processos, esteiras e regras de imposto, e as leituras registradas nas execuções dos últimos 180 dias —
  na tela do valor e antes de arquivar. No editor e no portão de qualidade (spec 064), nome inexistente é achado
  sério (`company_value_unknown`) e constante que já é valor da empresa vira sugestão (`company_value_constant`).
- **Transporte (T-065-10).** O pacote leva a definição dos valores que seus programas leem; o conteúdo, só dos
  marcados "igual em todos os ambientes" (versões gerais). A importação cria ou atualiza a definição sem tocar no
  conteúdo do destino; desfazer volta como era. A prévia avisa dos valores que os programas leem e que não existem
  no destino, com o atalho para criá-los.
- **Sugestões (T-065-11).** Uma versão que começa nos próximos 7 dias vira aviso (uma vez, pela tarefa diária do
  cluster); valor criado há mais de 180 dias que ninguém cita nem leu aparece como "sem uso: arquivar?".

## Fora desta fase
A leitura feita pelo SQL (`base.company_value`) não entra no registro da execução — só a de `ana.value`. O
assistente (spec 052), a paleta de comandos (spec 050 fase 2), a implantação guiada (spec 061) e o completar de
`ana.value("` no editor ficam para T-065-11b.
