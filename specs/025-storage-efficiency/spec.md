# 025 — Uso eficiente de disco (amigo de SSD)

Situação: implementada · Princípios: P15, P11, P12

## Problema
SSDs têm um limite de escritas: gravar mais que o necessário encurta a vida
útil e a confiabilidade do disco, além de custar desempenho. O ERP roda 24/7
em servidores de clientes, muitas vezes num único SSD, e precisa ser
econômico em escrita sem abrir mão da segurança dos dados.

## Requisitos funcionais
- **RF-025-01 Analítico só recalcula o que mudou.** A atualização periódica
  verifica, sem gravar nada, se as tabelas de origem mudaram desde a última
  atualização (contadores de estatística do PostgreSQL); se não mudaram,
  não regrava visões nem a tabela colunar e registra `unchanged`. A
  atualização pedida no Estúdio sempre recalcula. Se as estatísticas
  estiverem desligadas no banco, recalcula sempre.
- **RF-025-02 Acessos particionados por dia.** A tabela de acessos (a de maior
  volume) é particionada por dia; o expurgo descarta partições inteiras
  (`DROP`), sem apagar linha a linha nem gerar trabalho de limpeza. As
  partições dos próximos dias são criadas com antecedência; uma partição
  padrão garante que nenhum registro se perca.
- **RF-025-03 Gravação em lote dos acessos.** Os acessos são gravados em lote
  (até 500 por comando, a cada 1 s), com confirmação assíncrona
  (`synchronous_commit = off` só nessa gravação): numa queda do servidor
  pode-se perder no máximo o último segundo de acessos, nunca dados de
  negócio nem execuções.
- **RF-025-04 Uma escrita por execução curta.** O registro da execução só é
  criado no início se ela durar mais de 1 s (ou for depuração/assíncrona);
  execuções curtas — a grande maioria — geram uma única escrita, ao final.
- **RF-025-05 Atualizações sem reescrever índices.** O fim da execução
  atualiza só colunas não indexadas, e as tabelas atualizadas com
  frequência têm espaço livre por página (`fillfactor`), permitindo
  atualizações HOT.
- **RF-025-06 Sem escrita desnecessária em autenticação.** "Último uso" de
  chave de API grava no máximo uma vez por minuto por chave; sessões
  continuam em tabela sem WAL, tentativas de login e caches em memória.
- **RF-025-07 Configuração do banco e dos logs.** O ambiente padrão sobe o
  PostgreSQL com WAL comprimido (`wal_compression = lz4`) e checkpoints
  espaçados (`checkpoint_timeout = 15min`, `max_wal_size = 2GB`), e os
  contêineres com rotação de logs (10 MB × 3). `fsync`, `full_page_writes`
  e `synchronous_commit` globais permanecem ligados.
- **RF-025-08 Orientação de implantação.** A documentação recomenda montar
  os volumes com `noatime`, manter TRIM periódico (`fstrim.timer`), evitar
  swap no disco de dados e monitorar o desgaste (SMART/`nvme smart-log`).

## Critérios de aceitação
- **CA-025-01** Duas atualizações periódicas seguidas, sem venda nova entre
  elas: a segunda devolve `unchanged` e não altera as tabelas analíticas; o
  Estúdio força o recálculo (`refreshed`).
- **CA-025-02** Acessos de dias com partição própria são expurgados por
  descarte da partição; os dias seguintes já têm partição.
- **CA-025-03** Uma execução curta gera um único registro gravado ao final,
  completo (status, consumo, dono).
- **CA-025-04** A configuração do PostgreSQL em execução tem
  `wal_compression = lz4`, `checkpoint_timeout = 15min`, `fsync = on` e
  `full_page_writes = on`.
