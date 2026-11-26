# 068 — Plano

As escolhas deste plano saíram de medições, não de preferência. Os roteiros estão em `bench/`: um esquema de
ensaio `bench068`, criado e apagado no banco de desenvolvimento, com uma cópia de 10 mil pedidos de venda.

Ambiente das medições (26/11/2026):
- PostgreSQL 16.6, `wal_level=replica`, `full_page_writes=on`, sem `data_checksums` e sem `wal_log_hints`;
- banco limitado a 0,6 CPU, com `nice 19`, num computador compartilhado com o NVR;
- regime estável: sem CHECKPOINT entre as rodadas, primeira rodada descartada, casos intercalados;
- mediana de 9 a 14 rodadas.

Os tempos absolutos são de uma máquina lenta e ocupada. O que vale é a comparação entre as formas, e os números
finais são medidos de novo na bateria (T-068-02).

## 1. O que foi medido

### 1.1 Atualização em lote de 10 mil linhas (RNF-068-02)

| Forma da verificação | Regra ligada | Campo alterado | Tempo (mediana) | vs. sem nada | WAL a mais |
|----------------------|--------------|----------------|-----------------|--------------|------------|
| Nenhuma (referência) | – | vigiado | 201–205 ms | – | – |
| Gatilho por linha, sempre instalado, consulta as regras | não | vigiado | 300 ms | **+46%** | 0 |
| Gatilho por comando (tabelas de transição), sempre instalado | não | vigiado | 211 ms | +3% | 0 |
| Gatilho por comando, sempre instalado | sim | outro campo | 217–262 ms | +10% a +27% | 0 |
| Gatilho por linha, com `UPDATE OF campo` e `WHEN` | sim | outro campo | 201 ms | **+2%** | 0 |
| Gatilho por linha, um evento por linha | sim | vigiado | 390–490 ms | +94% a +139% | +2,1 MB (≈ 213 B/linha) |
| Gatilho por comando, um evento por linha alterada | sim | vigiado | 293 ms | +43% | +2,1 MB |
| Gatilho por comando, **um evento por comando** com a lista | sim | vigiado | 276 ms (mín. 225) | **+37%** (mín. +14%) | **≈ 0** (+45 KB em 10 mil linhas, ≈ 4,5 B/linha) |

### 1.2 Edição de um documento (transações isoladas, 200 por medição)

| Forma | WAL por transação | A mais |
|-------|-------------------|--------|
| Sem verificação: 1 alteração | 126 B | – |
| Gatilho por comando ou por linha: 1 alteração | 338–342 B | +215 B (uma linha de evento) |
| Sem verificação: 3 alterações na mesma transação | 300 B | – |
| Gatilho por comando ou por linha: 3 alterações | 942 B | +642 B (três linhas) |
| Gatilho por linha com upsert (uma linha por documento e transação): 3 alterações | 835 B | +535 B |

O tempo por transação ficou igual em todas as formas (1,7 a 2,3 ms, dominado pela ida e volta).

### 1.3 Fila: descarte de 100 mil eventos processados (D8)

| Forma | Tempo | WAL |
|-------|-------|-----|
| `DELETE` em lotes de 1.000 | 1.122 ms | 7,4 MB |
| `VACUUM` depois do `DELETE` | 130 ms | 2,2 MB |
| `DROP` da partição do dia | 2 ms | 13 KB |

São ≈ 95 B por evento no `DELETE` mais o `VACUUM`, contra ≈ 0 na partição.

### 1.4 Trava ao instalar a verificação (D5, RNF-068-02)

- **Sem ninguém gravando:** `CREATE TRIGGER` mais `DROP TRIGGER` levam 88 ms.
- **Com uma transação aberta que gravou na tabela:** o `CREATE TRIGGER` espera por ela, porque precisa da trava
  `SHARE ROW EXCLUSIVE`. Com `lock_timeout = 100ms` ele desiste em 100 ms ("canceling statement due to lock
  timeout"). Enquanto espera, quem chega para gravar fica na fila atrás dele, por no máximo esses 100 ms.

## 2. Decisões tiradas das medições

### D5 — Documentos: verificação instalada sob demanda, por comando
- **Sob demanda.** A verificação só existe na tabela enquanto houver regra "alterado" ligada para aquela entidade.
  Sem regra, ela não existe, e o custo é **exatamente zero**, de tempo e de WAL (D3, CA-068-09). As duas formas
  "sempre instaladas" ficam de fora:
  - a por linha custa +46% sem regra nenhuma;
  - a por comando custa +3% sem regra, na beira do limite, e +10% quando há regra e muda outro campo.
- **Por comando, com tabelas de transição.** Um único evento por comando, com a lista de chaves e os valores de
  antes e de depois dos campos vigiados: arrays `key`, `old` e `new` por campo. Ele custa ≈ 4,5 B por linha
  alterada, contra 213 B do evento por linha. Isso já é o D6 (uma gravação por comando) e vale também para a
  edição de um documento (+215 B).
- **Só os campos vigiados.** A comparação usa só os campos das regras ligadas daquela entidade. Se nenhum deles
  mudou, não grava nada (CA-068-03).
- **Instalação segura:**
  - a função do gatilho é gerada por uma função do banco, `automation.install_watch(entity)`, que lê o catálogo
    (D2) e monta os nomes com `format('%I')`;
  - nada vem de texto digitado (RNF-068-03), e chamar a função com entidade ou campo fora do catálogo é
    recusado (CA-068-08);
  - a instalação roda com `lock_timeout = 100ms`; se não conseguir a trava, o `ana_rules` tenta de novo em segundo
    plano, com espera crescente, e a regra fica "aguardando instalação" na central;
  - a remoção é igual e preguiçosa: só 10 minutos depois da última regra desligada, para não alternar
    instala/remove.
- **Campos de item.** Um campo de item, como a data prometida de `sales.sales_order_item.promised_date`, é vigiado
  na tabela do item. O evento sai com a chave do **documento** (o número do pedido), por uma junção declarada no
  catálogo, de modo que três itens adiados no mesmo comando viram um evento do pedido.

### D8 — Fila: a de hoje (`automation.pending`), com apagar em lote
- A fila de eventos de documento já existe (spec 051) e é reaproveitada. Ela ganha:
  - o tipo `changed`;
  - as colunas `changes` (jsonb) e `xid` (`xid8`, de `pg_current_xact_id()`).
- **Apagar em lote, não partição.** Com um evento por comando, o volume é baixo, e o leitor já apaga o que leu na
  mesma transação em que registra os disparos, como faz hoje. As partições por dia exigiriam criar uma partição
  por dia, uma escrita de catálogo mesmo com o sistema ocioso, contra o D2 da spec 063.
- Fica no plano o ponto de troca: se a bateria de uso simulado (T-068-12) passar de 50 mil eventos por dia, a
  fila passa a ser particionada, e a partição só é criada quando chega o primeiro evento do dia.

### D4 — Cadastros: lidos do `master.change_log`, sem escrita a mais
- O evento **é** a linha do histórico, que já é gravada hoje. Vigiar um cadastro não muda nada na gravação:
  - zero bytes a mais por alteração (CA-068-02, CA-068-03);
  - sem gatilho novo nas tabelas de cadastro.
- **Leitura.** O líder lê `WHERE id > ponto ORDER BY id LIMIT 500` pela chave primária, só enquanto houver regra
  "alterado" ligada para algum cadastro:
  - a cada 1 s com regra ligada (p95 de 2 s, RNF-068-02), e nunca sem regra;
  - sem `data_checksums` e sem `wal_log_hints`, ler não gera WAL.
- **Buracos na sequência.** Um `id` menor pode ser confirmado depois de um maior, numa transação mais longa.
  - O leitor guarda, em memória, os `id` que faltam abaixo do maior já lido e os procura de novo a cada leitura.
  - Um buraco é esquecido depois de 15 minutos, o `idle_in_transaction_session_timeout` das execuções, ou quando
    a sequência é de uma transação desfeita.
- **Ponto processado.** Guardado em `automation.mark` (`change_log`), gravado só quando avança e uma vez por
  lote. O valor é o menor buraco ainda aberto menos um, ou o maior lido.
- **Retomada no líder (CA-068-11).** O novo líder relê do ponto gravado. O que já disparou não dispara de novo,
  porque `automation.fire` ganha `event_ref` (`log:<id>` ou `doc:<xid>:<pending id>`) com índice único parcial
  `(rule_id, event_ref)`.
- **Sem `pg_notify` no histórico.** Avisar a cada linha exigiria consultar as regras em cada alteração de
  cadastro, justamente o custo que o D3 proíbe. A espera de 1 s cabe no p95 de 2 s.

### D6 — Lote: agrupado por padrão para importação e rotina
- O evento por comando já traz a lista. O disparo **agrupado** gera uma ação com a lista inteira (CA-068-05); o
  disparo **por registro** passa pelo limite de disparos da spec 051, que pausa a regra quando excede.
- A origem vem de `ana.origin`, já gravada no histórico e definida pelo núcleo nas execuções (tela, API,
  importação, regra, integração, rotina). `master.import` define `import`.

### Um evento por documento e por transação (RNF-068-01, CA-068-04)
- O disparo é sempre um por documento e por transação. O leitor junta os eventos de mesmo `xid` e mesma chave,
  com o valor do primeiro "antes" e do último "depois".
- No armazenamento, cada **comando** grava uma linha: três `UPDATE` do mesmo pedido na mesma transação gravam
  três linhas, +642 B. O upsert gravaria uma, +535 B, mas faria de cada comando de uma transação longa uma
  regravação da linha que cresce. A diferença medida é de 107 B por transação com três comandos.
- Aprovado pelo dono do produto (26/11/2026), já no texto do RNF-068-01: "no máximo uma linha de evento por
  **comando**; um disparo por documento e por transação".

## 3. Onde o alvo não foi atingido (decidido)

**RNF-068-02 / CA-068-09, "com regra ativa, no máximo 15% mais lento".** Pior caso: todas as 10 mil linhas
mudam o campo vigiado.
- Melhor forma medida (por comando, um evento com a lista): +37% na mediana e +14% na melhor rodada, a
  0,6 CPU num computador ocupado.
- O custo é o PostgreSQL guardar as linhas de antes e de depois para o gatilho. A outra forma, por linha, custa
  +94%.

O que fazer:
1. medir de novo na bateria (T-068-02), sem limite de CPU;
2. se continuar acima de 15%, há duas saídas:
   - manter os 15% para o caso realista, em que só parte das linhas muda o campo vigiado (no CA-068-05, 312 de
     5 mil), e declarar um alvo próprio, por exemplo 40%, para o pior caso;
   - ou aceitar a forma por linha com `WHEN`, que custa +2% quando o campo vigiado não muda, mas +94% quando
     muda.

A recomendação é a primeira saída. **Aprovada pelo dono do produto (26/11/2026):** 15% no caso realista e 40% no
pior caso, já no texto do RNF-068-02 e do CA-068-09.

## 4. Lacunas do modelo de dados encontradas
- **Conta bancária do fornecedor (CA-068-01):**
  - não existe no cadastro;
  - entra `base.party_bank` (banco, agência, conta, chave PIX, principal), com o gatilho `master_log` e as colunas
    sigilosas mascaradas no histórico (`["***", "***"]`);
  - o evento sai como "alterado", sem valor (D10);
  - tarefa T-068-13.
- **Data de entrega do pedido (CA-068-04):** é do item (`promised_date`); vigiada como campo de item com a chave do
  pedido (D5, acima).

## 5. Segurança (D9, D10, RNF-068-03)
- **Catálogo** (`automation.watchable`: entidade, tabela, chave, junção ao documento, campo, rótulo, tipo,
  classificação `common`/`personal`/`secret`, classe de volume):
  - com `CHECK` e um teste que recusa os esquemas internos (`ana_system`, sessões, usuários, chaves, licenças),
    o próprio `master.change_log` e o esquema `automation`;
  - as extensões acrescentam linhas pelo portão da spec 064.
- **Alcance do dono:**
  - no disparo, a visibilidade é conferida como o dono, pelo mesmo caminho das execuções restritas da spec 042:
    `SET LOCAL ROLE ana_scoped` e uma consulta da chave;
  - se o dono não vê o registro, o resultado é `skipped` com `out_of_reach`, sem valores (CA-068-06).
- **Campo sigiloso:**
  - o valor nunca entra em `pending.changes`: a função gerada grava `"***"` para campos `secret`, como o
    histórico já faz;
  - também nunca entra em aviso, e-mail, conector, log ou ensaio.
- **Dado pessoal por conector:**
  - entra `integration.connector.personal_data` (finalidade, quem pediu, quem aprovou), exigindo uma segunda
    pessoa (quatro olhos), com auditoria da spec 024;
  - salvar uma regra que manda campo pessoal a um conector sem essa autorização é recusado (CA-068-07).
- **Laço:** a cadeia da spec 051 (`ana.rule_chain`) vai também nos eventos `changed`. O esquema `automation` nunca
  é vigiável.

## 6. Saída por conector (D11)
- A saída usa `integration.outbox`, que já tem:
  - `ordering_key`, com a chave do registro, o que garante a ordem por registro;
  - entrega ao menos uma vez.
- Ela ganha a chave de idempotência `rule:<id>:<event_ref>`, enviada no cabeçalho `X-Event-Id` do conector. O
  destino descarta a repetição.
- O corpo é limitado a 64 KB, com a lista agrupada cortada e "+N" no fim, e assinado com HMAC da chave do
  conector (no cofre), no `signature_header`.

## 7. Orçamento de escrita (T-068-02, `priv/disk_budget.json`)
Entradas novas, medidas por `TestDiskEndurance`:

| Operação | Orçamento inicial |
|----------|-------------------|
| `change_master_unwatched`: 1 alteração de cliente sem regra | igual a hoje (referência medida antes) |
| `change_master_watched`: 1 alteração de cliente com regra | igual a hoje, mais o avanço do ponto por lote |
| `change_document_unwatched`: 1 alteração de pedido sem regra | igual a hoje |
| `change_document_watched`: 1 alteração de pedido com regra no campo | hoje + ≈ 220 B, mais o disparo |
| ocioso com regras "alterado" ligadas | dentro do `idle_wal_bytes_per_hour` atual |

## 8. Ordem de construção
1. T-068-01 catálogo e T-068-13 conta bancária do fornecedor.
2. T-068-02 linha de base no orçamento, antes de qualquer gatilho.
3. T-068-04 instalação sob demanda e evento por comando, e T-068-09 fila.
4. T-068-03 leitor do histórico, com buracos e retomada.
5. T-068-06 gatilho "alterado" e T-068-05 lote.
6. T-068-07 segurança e T-068-08 conector.
7. T-068-10 telas, T-068-11 sugestão e T-068-12 uso simulado.

Migração prevista: `078_change_watch.sql`.

## 9. Feito: catálogo (T-068-01) e conta bancária do fornecedor (T-068-13)

Migração `078_change_watch.sql`, sem nenhum gatilho novo de vigilância.

**Catálogo** (`automation.watch_entity` e `automation.watch_field`, lidos pela visão `automation.watchable`):
- 16 entidades vigiáveis, 11 cadastros e 5 documentos, com 157 campos;
- os campos de item (pedido, solicitação, agenda da OS) levam a coluna de ligação ao documento;
- 3 entidades de muito movimento ficam só para explicar a alternativa (D7).

**O banco recusa**, por gatilho, quem quer que escreva:
- esquema fora dos de negócio, tabela ou coluna inexistente, coluna com nome de segredo;
- campo de cadastro numa tabela que não grava o histórico daquela entidade;
- campo em entidade de muito movimento.

O papel dos programas (`ana_exec`) só lê o catálogo.

**Extensão pelo cliente.** O produto não deixa o cliente criar tabelas: os dados da empresa são os campos próprios
dos cadastros (`master.custom_field`). Eles entram no catálogo sozinhos, pela visão, com a classificação escolhida
junto com o campo (comum, pessoal ou sigiloso). Ninguém precisa listá-los, e o portão da spec 064 continua valendo
para os programas que os usam.

**Classificação (D10):**
- sigiloso: dados bancários, custos e limite de crédito;
- pessoal: nome, documento, contato e localização de pessoas (LGPD).

**Conta bancária do fornecedor:**
- tabela `base.party_bank`, com formato conferido no banco;
- histórico com agência, conta e chave PIX mascaradas, inclusive para o administrador;
- aba "Dados bancários" na ficha;
- permissão por aba (`edit: admin`): só o administrador altera, os demais veem mascarado e só para leitura;
- programa `base.save_party_bank`.

## 10. Feito: linha de base (T-068-02)

`TestDiskEndurance` mede, antes de qualquer vigilância, duas operações novas do orçamento:
- `change_party`: alterar um cadastro de cliente, já com a linha do histórico;
- `change_order_field`: alterar um campo do pedido por rotina.

Medição local: 2.529 B e 6.647 B, com a rotina curta em 2.277 B. No orçamento entraram escaladas pela rotina curta
(5.259 B no CI): 5.841 B e 15.352 B.

Essas entradas não podem crescer sem regra (CA-068-02). As entradas "com regra" entram com a T-068-03 e a T-068-04,
porque precisam do leitor e da verificação.

A comparação de tempo do lote de 10 mil linhas (RNF-068-02, CA-068-09) também fica para a T-068-04: ela só faz
sentido medindo com e sem a verificação instalada, na mesma rodada.

## 11. Feito: documentos vigiados (T-068-04) e fila (T-068-09)

Migração `079_change_watch_documents.sql` e processo `ana_watch`.

**Regras.** `automation.rule` aceita o gatilho `changed`, com `watch_fields` (`esquema.tabela.coluna` do catálogo,
ou `custom.nome`).
- A ligação fixa a `bpm.document` saiu, porque um cadastro também pode ser vigiado.
- Um gatilho do banco confere a entidade e cada campo no catálogo e recusa o resto, mesmo por gravação direta.
- A tela e a API das regras "alterado" chegam com a T-068-06.

**Verificação:**
- `automation.watch_need` diz o que as regras ligadas pedem;
- `automation.install_watch(tabela)` gera a função a partir do catálogo, com `format('%I')`. Ela compara só as
  colunas vigiadas, e uma coluna sigilosa sai como `"***"`;
- a mesma função instala o gatilho por comando com `lock_timeout` de 100 ms, e só a função é trocada quando os
  campos mudam;
- o `ana_watch`, só no líder, reconcilia quando uma regra muda (NOTIFY `ana_wake/watch`) e a cada 30 s, sem gravar
  nada. Ele tenta de novo com espera crescente, de 1 s a 60 s, e remove o gatilho 10 minutos depois da última regra
  desligada; até lá, a função já não compara nada;
- só a instalação e a remoção do gatilho fazem DDL; ninguém (nem `ana_exec`) executa as funções diretamente.

**Itens.** Um campo de item, como a data prometida, sai com o número do pedido. Os valores de vários itens do mesmo
pedido viram um campo do evento do pedido: o primeiro "antes" e o último "depois".

**Fila:**
- `automation.pending` ganhou o tipo `changed`, com a lista em `changes` e o `xid`;
- `automation.take_changed` tira transações inteiras, apaga o que tirou e devolve um evento por documento e por
  transação. Um campo que volta ao valor na mesma transação não conta;
- a leitura antiga da spec 051 deixa esses eventos para ela;
- os disparos (`automation.fire`) entraram na retenção da spec 024, com o prazo das execuções. Faltava isso desde a
  spec 051.

**Medido na bateria** (`test_ca_068_09`: 10 mil pedidos, tempo medido dentro de uma rotina, com o gatilho
incluído):

| Caso | Tempo | Alvo |
|------|-------|------|
| Sem regra | sem verificação na tabela (0%) | 3% |
| Com regra, todas as linhas mudam o campo vigiado | +24% a +38% | 40% |
| Com regra, parte das linhas muda o campo vigiado | dentro do ruído | 15% |

Tirar a ordenação das chaves dentro do gatilho baixou o pior caso de +38% para +24%; a leitura da fila já ordena.

**Orçamento de escrita.** `change_order_field_watched` é `change_order_field` mais a linha de evento: ≈ 215 B, ou
≈ 508 B na escala do CI. O ruído do ocioso local é maior que essa diferença, e o CI confere.

## 12. Feito: cadastros lidos do histórico (T-068-03) e o disparo que não perde nem repete

Migração `080_change_watch_masters.sql` e processo `ana_watch_log`.

**Leitura** (`automation.read_log`):
- devolve todas as linhas do histórico depois do ponto (para distinguir um buraco de uma linha que ninguém vigia),
  mais os `id` que faltavam;
- só traz alterações das entidades vigiadas, nunca um pedido de alteração aguardando aprovação;
- as chaves são as referências do catálogo, e os campos próprios da empresa saem um a um;
- sigiloso sai `***`, e o que o histórico já mascara conta como alterado.

**Leitor** (`ana_watch_log`, só no líder):
- lê a cada 1 s, e só enquanto houver regra "alterado" sobre um cadastro;
- os buracos ficam em memória por 15 minutos; a conta é pura e testada em eunit (`advance/5`);
- o ponto é gravado com os disparos, ou a cada 5 minutos;
- sem regra, o ponto é apagado, e a próxima regra começa do seu próprio momento, nunca do passado;
- quem deixa de ser líder esquece tudo, e o novo líder retoma do ponto.

**Disparo sem perder nem repetir (RNF-068-04, CA-068-11):**
- o evento casado (entidade e campos da regra) é reivindicado como `running` em `automation.fire`, com
  `event_ref` único por regra (`log:<id>` ou `doc:<xid>:<chave>`);
- a reivindicação acontece na mesma transação que grava o ponto ou que tira os eventos da fila;
- o `ana_rules` age depois sobre as reivindicações, inclusive as que uma queda deixou para trás, passando por
  laço, limite e condições, como na spec 051;
- os fatos são os do documento, mais cada campo alterado (`campo` e `campo_before`), `changed_by` e `origin`.

**Lote (base do D6).** Uma transação que altera mais de 20 documentos de uma entidade vira um disparo agrupado por
regra, com `{{count}}` e a lista de até 1.000 chaves. O lote de 10 mil pedidos gera 15 disparos em 15 lotes, e a
regra não é bloqueada pelo limite.

**Defeito encontrado e corrigido no caminho.** Os eventos de documento saíam com o nome da coluna, e não com a
referência do catálogo. A regra não casava, e o evento se perdia sem disparo. O teste de ponta a ponta pegou o
defeito.

Medido de novo, com a fila vazia antes de cada rodada (o líder processa o lote anterior em segundo plano): +20% no
pior caso; o caso realista ficou dentro do ruído.

## 13. Feito: gatilho "alterado" pela API (T-068-06) e lote (T-068-05)

Migração `081_change_watch_rules.sql` e módulo puro `ana_watch_match`, com eunit.

**A regra "alterado":**
- campos do catálogo;
- filtro de/para, variação mínima com direção, campo esvaziado ou preenchido;
- origens (tela, API, importação, regra, integração, rotina, outra); a importação fica fora por padrão;
- registro específico;
- modo por registro, agrupado ou automático.

**Recusas na gravação:** campo sigiloso só como "alterado" (sem filtro de valor) e só com dono administrador; campo
fora do catálogo; entidade de muito movimento.

**Origem sem escrita a mais.** `automation.origin_kind` deduz a origem do que o banco já tem: o programa da execução
(importação), um disparo de regra, o programa de um conector, a origem da execução.

**Reivindicação e ação:**
- a reivindicação é uma por regra e por unidade: a transação do documento, a execução do cadastro (que cresce
  enquanto a importação lê) ou a linha do histórico;
- a ação espera a execução terminar, aplica a origem e decide entre um disparo agrupado e a divisão em disparos por
  registro, numa transação;
- a ação de uma regra que muda o que ela mesma vigia é bloqueada pela cadeia da execução.

**Ensaio.** Roda sobre as mudanças reais dos últimos 7 dias ("teria disparado N vezes") e executa a ação sobre a
última delas.

**Medido no CI** (26/11/2026, sem limite de CPU):
- lote de 10 mil pedidos: +25% com todas as linhas mudando o campo vigiado (alvo 40%) e +3% com parte delas (alvo
  15%);
- o orçamento de escrita foi trazido para os valores do CI.

## 14. T-068-07: segurança no disparo e na saída (verificação no CI)

Migração `082_change_watch_security.sql`.

**Alcance do dono (D9, CA-068-06):**
- antes de agir, o `ana_rules` confere quais registros o dono vê, numa transação só de leitura como `ana_scoped`
  com o escopo do dono (o mesmo das execuções dele, spec 009) e no padrão da prévia de escopo;
- o que ele não vê não dispara: o disparo fica `skipped`, "fora do alcance do dono", só com as chaves e nenhum
  valor;
- num lote, age sobre os visíveis e conta os demais;
- dono sem restrição: nenhuma consulta a mais.

**Dado pessoal (D10, CA-068-07):**
- o conector ganha a autorização com finalidade (pedido de uma pessoa, aprovação de outra, conferida pelo banco),
  com auditoria;
- salvar uma regra que manda campo pessoal a um conector sem autorização é recusado, com o caminho;
- no disparo, uma autorização revogada impede o envio.

**Conferência por outra pessoa (CA-068-01):**
- a ação "criar tarefa" tem a opção "exceto quem alterou" (`not_by_changer`);
- quem não pode concluir é gravado em `bpm.task.not_by` quando a tarefa nasce, por `automation.create_task` (a
  versão com 16 parâmetros, `SECURITY DEFINER`); nenhum programa pode mudar a coluna depois, porque `ana_exec` não
  tem `UPDATE` nela;
- uma tarefa sobre um cadastro abre um caso sem documento do BPM (`none`), com a chave no título;
- o banco recusa que essa pessoa assuma ou conclua a tarefa, administrador ou não;
- a tela de tarefas explica a recusa antes.
