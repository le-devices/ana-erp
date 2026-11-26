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
- Proposta para o texto do RNF-068-01, a decidir com o dono do produto: "no máximo uma linha de evento por
  **comando**; um disparo por documento e por transação".

## 3. Onde o alvo não foi atingido (para decidir)

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

A recomendação é a primeira saída.

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
