# 063 — Vida útil do disco: escrita medida, com orçamento e vigiada

Situação: fase 1 implementada (nov/2026); fase 2 pendente.

## Problema
SSDs têm um limite de escrita (TBW): cada byte gravado consome vida útil, e
um disco gasto perde desempenho e confiabilidade antes de falhar. O P15 e a
spec 025 já fizeram uma rodada de economia (analítico só recalcula o que
mudou, acessos particionados e em lote, uma escrita por execução curta, HOT,
WAL comprimido, logs com rotação). Mas:
- nada **mede** quanto o ERP escreve — nem por operação, nem parado;
- muita coisa veio depois da spec 025 e nunca foi revista com esse olhar
  (alertas, fila de integração, motor de processos e esteiras, verificações,
  estatísticas de SQL, preferências de tela, painéis, e-mail, cópias);
- o administrador não sabe quanto o disco está se gastando nem quando
  trocá-lo;
- uma mudança que dobre a escrita passa despercebida até o disco reclamar.

## Decisões
- **D1 — Orçamento de escrita.** Valores de referência, medidos e
  versionados, de bytes de WAL (e de arquivos, quando houver) para operações
  típicas — criar pedido, faturar, executar rotina curta, chamada da API
  pública, importar 1.000 cadastros, ciclo de alertas — e para o **sistema
  ocioso** (uma hora sem uso: perto de zero além do necessário). Um teste da
  bateria mede e falha acima do orçamento com tolerância declarada; baixar o
  orçamento é sempre bem-vindo.
- **D2 — Ocioso não escreve.** Nada de gravação periódica "por via das
  dúvidas": ciclos de saúde, alertas, verificações, agendamento, processos e
  integração só escrevem quando algo **mudou** (como a saúde já faz); quando
  precisam marcar presença, usam memória (ETS) ou tabela sem WAL.
- **D3 — Painel "Disco"** na observabilidade (spec 019): escrita do banco
  (WAL por hora e por dia, `pg_stat_io` do PostgreSQL 16 por tipo de
  operação, arquivos temporários, checkpoints forçados × programados),
  crescimento das tabelas (spec 019), repositório de arquivos, logs e
  cópias; tendência e **projeção de desgaste**: com a resistência informada
  do SSD (TBW) e a escrita média, quantos anos restam e quando planejar a
  troca.
- **D4 — Alertas de escrita.** Métricas de escrita (WAL por hora, arquivos
  temporários) entram nas regras de alerta (T-019-08b): salto de escrita vira
  incidente com o que mais escreveu (tabelas e programas — spec 046).
- **D5 — Estado de saúde do disco, quando disponível.** O `ana-ctl
  diagnóstico` (spec 036) lê o desgaste do SSD (SMART/NVMe) quando a
  instalação permite e o envia ao painel; o ERP nunca muda configuração do
  sistema operacional — sugere (TRIM periódico, `noatime`, WAL em volume
  próprio, cópias em outro disco).
- **D6 — Banco ajustado para durar.** Checkpoints espaçados com
  `max_wal_size` adequado, WAL comprimido, `wal_writer_delay` e confirmação
  assíncrona só onde a perda de um instante não importa (já usada em
  acessos), `work_mem` e `temp_buffers` para evitar arquivos temporários
  (com `log_temp_files` para achar quem derrama), autovacuum e fillfactor
  por tabela de alta atualização. `fsync` e `full_page_writes` nunca são
  desligados (P15).
- **D7 — Temporários em memória.** Arquivos temporários do runtime Python e
  dos processamentos de curta duração em memória (tmpfs) com limite; só o
  que precisa sobreviver a uma queda (uploads em partes, cópias) vai ao
  disco — e é apagado assim que termina.
- **D8 — Logs e contêineres.** Nível de log adequado (nada de depuração em
  produção), rotação com limite de tamanho no Docker e no Kubernetes, sem
  gravar a mesma linha em dois lugares.
- **D9 — Revisão de tudo o que já existe** (fase 2), procurando escrita
  desnecessária: reescrita de linhas que não mudaram, `UPDATE` de "visto em"
  a cada ciclo, contadores gravados em vez de mantidos em memória, expurgo
  linha a linha em vez de partição, índices que não pagam a escrita que
  custam, cópias que repetem o que não mudou.
- **D10 — Janela de perda do arquivo de WAL é da instalação.** O
  `archive_timeout` (de quanto em quanto tempo, havendo escrita, um segmento
  de 16 MB vai para o arquivo) é a perda máxima aceitável (RPO) se o servidor
  inteiro se perder, e troca durabilidade por escrita em disco. Cada cliente
  escolhe: `install.sh --archive-minutes N` (1 a 60, padrão 5) e
  `ana-ctl archive-minutes N` para mudar depois; o guia e o painel "Disco"
  mostram o custo de cada escolha. Nunca é desligado (RNF-063-01). Decisão do
  dono do produto em 19/11/2026.

## Requisitos funcionais
- **RF-063-01** Medição de escrita por operação e com o sistema ocioso (D1),
  com orçamento versionado e teste na bateria.
- **RF-063-02** Painel "Disco" com projeção de desgaste (D3).
- **RF-063-03** Métricas de escrita nas regras de alerta (D4).
- **RF-063-04** Saúde do disco pelo `ana-ctl` quando disponível, e sugestões
  de configuração do servidor (D5).
- **RF-063-05** Ajustes do banco, temporários em memória e logs (D6–D8),
  na instalação padrão (compose, Kubernetes e instalador), com a janela de
  perda do arquivo de WAL como parâmetro da instalação (D10).
- **RF-063-06** Revisão de todas as funcionalidades com relatório (D9).

## Requisitos não funcionais
- **RNF-063-01** Nenhuma economia de escrita troca segurança dos dados: o que
  foi confirmado ao usuário está no disco (P4, P15).
- **RNF-063-02** A medição custa quase nada (leitura das estatísticas do
  PostgreSQL e contadores em memória).
- **RNF-063-03** Sistema ocioso por uma hora grava menos do que o orçamento
  medido na fase 1, que a revisão da fase 2 deve reduzir.

## Critérios de aceite
- **CA-063-01** Uma mudança que faz uma operação típica escrever acima do
  orçamento faz a bateria falhar mostrando a operação e o quanto passou.
- **CA-063-02** Com o sistema ocioso por uma hora, o painel mostra a escrita
  do período dentro do orçamento e o que mais escreveu.
- **CA-063-03** Informando a resistência do SSD (TBW), o painel mostra a
  projeção de anos restantes no ritmo atual.
- **CA-063-04** Um salto de escrita (ex.: rotina que regrava uma tabela
  inteira a cada minuto) vira incidente com a tabela e o programa
  responsáveis.
- **CA-063-05** Relatório da revisão: cada escrita desnecessária encontrada e
  o que foi feito, com a escrita antes e depois.
