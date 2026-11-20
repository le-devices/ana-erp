# 056 — Plano: ensaio universal

## Abordagem
O ensaio é uma **opção da execução** (`rehearse: true` em `POST /api/programs/:nome/run`), não um parâmetro de
cada rotina. O núcleo roda a rotina inteira na sua transação e, no fim, em vez do COMMIT:

1. lê o efeito **da própria transação** (D2), sem código de rotina nenhuma:
   - `pg_stat_xact_user_tables` diz quais tabelas a transação gravou e como (criou, alterou, excluiu);
   - `rehearsal.table_rows(tabela, n)` devolve as linhas que a transação deixou — linhas visíveis cujo
     `xmin` é uma transação em andamento só podem ser desta (as de outras transações em andamento são
     invisíveis), inclusive as gravadas em savepoints e programas chamados;
   - `ana_system.business_table` (dado, não código) dá o nome de negócio de cada tabela e o documento que
     abre cada linha no visualizador da spec 035;
   - a caixa de saída (`integration.outbox`) vira "e-mails que seriam enviados";
2. faz ROLLBACK.

O que sairia da transação é **retido** pelo núcleo e listado (D1): chamadas a conectores que não sejam leitura
(GET/HEAD passam), sistemas remotos, gravação de arquivos (achar pasta passa, criar não), agendamentos. O
programa recebe uma resposta marcada `held` no formato que espera e segue. Partes paralelas (spec 022) também
ensaiam e o efeito delas se junta ao da execução principal. `ana.context.rehearsal` diz ao programa que é um ensaio.

## Catálogo (RF-056-03)
A inspeção do programa (ao salvar e na atualização do produto) registra, por função, quais gravam
(`writing`) e as ligações com o que usa (`uses`: função de biblioteca, outro programa, função do banco).
`ana_system.writing_programs()` segue as ligações; uma função do banco grava quando é volátil e o corpo
tem INSERT/UPDATE/DELETE/MERGE. O catálogo de rotinas devolve `writes`, e só essas oferecem "Ensaiar (F9)".
Uma rotina com simulação própria (spec 020, parâmetro `simulate`) mantém o "Simular (F9)" (D4).

## Verificador (RF-056-04)
Na bateria, todas as rotinas do catálogo são ensaiadas: nenhuma pode falhar sem trazer o efeito, nada pode
ficar gravado, e uma rotina que o ensaio mostra gravando mas o catálogo toma por consulta é apontada.

## Desempenho e disco (P15)
O ensaio não grava nada além da linha de auditoria da execução (coluna `rehearsal`). A leitura de cada tabela
tem savepoint e limite de tempo próprios (3 s): numa tabela grande, fica só a contagem.

## Fora desta entrega
O "Ensaiar" do assistente (spec 052) e das regras de automação (spec 051) usa a mesma opção da execução quando
essas specs forem implementadas. Números de documento vindos de sequências podem pular no ensaio, como já
acontece quando uma execução falha.
