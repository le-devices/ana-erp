# 046 — Diagnósticos de programas

Situação: especificada (nov/2026).

## Problema
Cada execução já registra duração, CPU, memória máxima, comandos SQL, linhas
lidas, erro e pilha (specs 012, 019, 024), e há telas para o momento (saúde,
desempenho do SQL, dicas). Falta responder perguntas de **longo prazo** de
forma simples: "quais programas mais falharam nos últimos 6 meses?", "o que
mais consome CPU desde a última versão?", "este erro voltou?", "quem é o dono
disso e quem é afetado?". O registro detalhado expira pela retenção, e os
erros iguais aparecem como milhares de linhas soltas.

## Decisões
- **D1 — Agregado diário de longa duração.** Por dia, programa, versão e
  usuário: execuções por situação, erros por código, duração (soma, máx.,
  p95 aproximado), CPU, memória máxima, comandos SQL, tempo de SQL, linhas
  lidas e gravadas, chamadas externas, bytes de arquivos lidos/gravados
  (E/S). Pequeno (uma linha por combinação/dia), mantido por anos
  (parâmetro, padrão 3 anos), independente da retenção do detalhe.
- **D2 — Erro com assinatura.** Erros iguais (programa, código, arquivo/linha
  do quadro mais interno do programa, tipo da exceção) viram um **grupo** com
  primeira e última ocorrência, contagem, usuários afetados, versões e
  exemplos (as últimas execuções com pilha completa — o "dump"). Grupo
  resolvido que volta é marcado "reapareceu".
- **D3 — Dono e afetados.** Todo resultado mostra o **dono do programa**
  (responsável no cadastro do programa, obrigatório — spec 011) e **quem
  executou** (pessoas e robôs, P14), com contagem por usuário.
- **D4 — Busca intuitiva.** Uma tela "Diagnósticos" com perguntas prontas
  ("Mais falhas", "Mais CPU", "Mais memória", "Mais E/S", "Mais lentos",
  "Erros novos", "Pioraram desde a última versão"), período livre (de
  1 hora a anos), filtros por área/namespace, programa, dono, usuário,
  origem (tela, API, agendamento, esteira), e ordenação; resultado com
  tendência (gráfico, spec 026) e comparação com o período anterior.
- **D5 — Aprofundar.** Programa → versões → grupos de erro → execuções → pilha,
  rastro e perfil (spec 019); usuário → programas que ele mais roda e onde
  falha.
- **D6 — Ação.** Do grupo de erro: atribuir ao dono, marcar resolvido,
  silenciar por prazo, abrir em depuração por reexecução (spec 047).

## Requisitos funcionais
- **RF-046-01** Agregação diária (D1), incremental (a cada 5 min para o dia
  corrente, consolidação noturna), sem varrer o histórico inteiro.
- **RF-046-02** Medições de E/S por execução: linhas gravadas, chamadas
  externas, bytes de arquivos (runtime e núcleo).
- **RF-046-03** Grupos de erro com assinatura (D2), ciclo aberto → atribuído →
  resolvido → reapareceu, com histórico.
- **RF-046-04** Tela de busca (D4) com perguntas prontas, filtros, período e
  comparação; variantes de tabela (spec 020) e de busca.
- **RF-046-05** Aprofundamento (D5) até a execução individual enquanto o
  detalhe existir; depois dele, o agregado e os exemplos guardados do grupo.
- **RF-046-06** Dono e afetados (D3); "Meus programas" para o dono; aviso ao
  dono quando um grupo novo ou reaparecido passa de N ocorrências (regras de
  alerta, T-019-08b; e-mail, spec 044).
- **RF-046-07** Exportar o resultado (CSV) e API para administração.

## Requisitos não funcionais
- **RNF-046-01** Qualquer pergunta pronta sobre 12 meses responde em < 2 s com
  100 milhões de execuções no histórico (só agregados).
- **RNF-046-02** Coleta sem custo perceptível na execução (< 1 % de duração).
- **RNF-046-03** Acesso: administradores veem tudo; desenvolvedores, os
  programas de que são donos e os do seu namespace; valores de parâmetros
  sensíveis mascarados nos exemplos (spec 019).

## Critérios de aceite
- **CA-046-01** Um programa que falha 300 vezes com o mesmo erro aparece como
  1 grupo com 300 ocorrências, os usuários afetados e o dono.
- **CA-046-02** "Mais CPU" em 6 meses traz o programa mais pesado no topo com
  a tendência e o maior usuário dele.
- **CA-046-03** Grupo resolvido que ocorre de novo vira "reapareceu" e avisa o
  dono.
- **CA-046-04** Depois do expurgo do detalhe, o agregado do período continua
  igual e o grupo mantém seus exemplos.
- **CA-046-05** Desenvolvedor não vê programas de outros namespaces.
