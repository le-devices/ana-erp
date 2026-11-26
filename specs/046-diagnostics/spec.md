# 046 — Diagnósticos de programas

Situação: especificada (nov/2026); revisada em 26/11/2026 (D7–D12): todas as fontes de falha, assinatura
sem dados variáveis, aviso no primeiro erro e no pico, situação "conhecido", quem esbarrou no erro sabe que já se
sabe, coleta sem escrita por erro e grupos de erro antes do agregado de longo prazo.

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

### Revisão de 26/11/2026
Motivo: a lista de erros de execução dos ERPs de mercado mostra o mesmo erro
dezenas de vezes por minuto, e quem olha agrupa de cabeça. No ANA também é
uma linha por execução (Auditoria → Execuções). A ficha de cada execução já é
rica: pilha quadro a quadro, variáveis no ponto do erro, linha do tempo do
SQL, limites e parâmetros. Falta a visão do conjunto.

- **D7 — Todas as falhas num lugar só.** Além das execuções de programa, o
  grupo de erro recebe:
  - as rotinas agendadas e as etapas de esteira e de processo que falharam;
  - as entregas de conector que esgotaram as tentativas;
  - os disparos de regra com falha (spec 051);
  - as requisições HTTP que terminaram em erro 5xx;
  - as quedas de processo do núcleo (relatórios de falha do OTP, com o
    supervisor que reiniciou).

  Cada grupo diz a **fonte**, e a tela filtra por ela. Nada disso muda as
  telas atuais: Auditoria, Monitor e Automações continuam mostrando cada
  ocorrência.
- **D8 — Assinatura sem dados variáveis.**
  - **Composição.** A assinatura junta fonte, programa, código, tipo da
    exceção e o quadro mais interno do programa (função e linha).
  - **Mensagem normalizada.** A mensagem entra sem números, datas,
    identificadores, textos entre aspas e valores de parâmetros. Assim,
    "pedido 1234 não encontrado" e "pedido 5678 não encontrado" são o mesmo
    grupo.
  - **Versão.** Não entra na assinatura, para que o mesmo erro em versões
    diferentes seja um grupo só. As versões em que apareceu ficam no grupo.
  - **Regras da normalização.** Ficam como dado e são testadas com casos.
- **D9 — Avisar sem inundar.**
  - **Erro novo.** A primeira ocorrência de um grupo novo avisa o dono do
    programa, ou o administrador quando a fonte é o núcleo. O padrão é avisar
    já na primeira vez; o limite N de RF-046-06 continua configurável.
  - **Pico.** Avisa quando a taxa de um grupo passa de um múltiplo da sua
    própria linha de base (a média das últimas semanas no mesmo horário).
  - **Avisos possíveis.** Nunca sai um aviso por ocorrência: um grupo gera no
    máximo um aviso de "novo", um de "reapareceu" e um de "pico" por janela.
  - **Integração.** Os avisos usam as regras de alerta (spec 019) e viram
    gatilhos das regras "quando… então…" (spec 051): "erro novo",
    "reapareceu" e "pico".
- **D10 — Situação do grupo.** O ciclo de RF-046-03 ganha "conhecido",
  com motivo, prazo e quem responde. Exemplos: "falha do serviço da
  prefeitura" ou "corrigido na próxima versão".
  - **Corrigido.** Pode apontar a versão ou o transporte que trouxe a
    correção (spec 064, D6).
  - **Reapareceu.** Se o grupo volta depois dessa versão, a situação passa a
    "reapareceu" e o dono é avisado.
  - **Novo desde a versão.** Um grupo que surge logo depois de um transporte
    ou atualização mostra "apareceu depois de …", ligado ao pacote.
- **D11 — Quem esbarrou no erro sabe que já se sabe.** A pessoa que recebeu o
  erro, na tela ou na API, continua vendo a mensagem traduzida (spec 050).
  - **Grupo atribuído ou conhecido.** A mensagem acrescenta "este problema já
    é conhecido e está com {responsável}". Com prazo, mostra o prazo.
  - **Grupo novo.** Acrescenta "o responsável já foi avisado".
  - **Efeito.** Ninguém precisa abrir chamado para o que já está sendo
    tratado (spec 057).
  - **Sigilo.** O texto nunca mostra a pilha nem dados de outros usuários.
- **D12 — Coleta sem escrita por erro (P15, P20).**
  - **Em memória.** Cada nó conta as ocorrências em memória (ETS), por
    assinatura.
  - **Gravação.** Grava no banco por lote, a cada poucos segundos, uma linha
    por grupo que mudou. Uma rajada de 10 mil erros iguais por minuto custa
    algumas gravações, não 10 mil.
  - **Primeira ocorrência.** Vai na hora, para o aviso de "novo" não esperar
    o lote.
  - **Queda do nó.** Perde no máximo as contagens do último intervalo. As
    execuções continuam sendo a fonte da verdade, e uma reconciliação do
    líder recompõe as contagens a partir delas enquanto o detalhe existe.
  - **Exemplos.** O grupo guarda as últimas execuções completas: no máximo 5,
    sempre substituindo a mais antiga.

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
- **RF-046-08** Fontes de falha além das execuções: agendamentos, etapas de
  esteira e processo, conectores, disparos de regra, HTTP 5xx e quedas do
  núcleo, com a fonte no grupo (D7).
- **RF-046-09** Assinatura com mensagem normalizada; regras da normalização
  como dado, com casos de teste (D8).
- **RF-046-10** Aviso no primeiro erro de um grupo e no pico sobre a linha de
  base, no máximo um por tipo e janela; gatilhos "erro novo", "reapareceu" e
  "pico" nas regras da spec 051 (D9).
- **RF-046-11** Situação "conhecido" com motivo, prazo e responsável;
  "corrigido na versão…" ligado ao transporte; "apareceu depois de…" (D10).
- **RF-046-12** A mensagem traduzida da spec 050 diz quando o problema já é
  conhecido ou o responsável já foi avisado (D11).
- **RF-046-13** Tela "Erros" na Administração, de abertura direta (sem montar
  filtro):
  - uma linha por grupo: fonte, programa, código, mensagem normalizada,
    situação, ocorrências, usuários afetados, primeira e última vez,
    tendência de 24 horas e de 7 dias;
  - ordenada por impacto (ocorrências × pessoas afetadas, e "nada foi
    gravado" pesa mais);
  - filtros por fonte, situação, programa, dono e período;
  - do grupo, abre a execução mais recente com pilha e variáveis.

## Requisitos não funcionais
- **RNF-046-01** Qualquer pergunta pronta sobre 12 meses responde em < 2 s com
  100 milhões de execuções no histórico (só agregados).
- **RNF-046-02** Coleta sem custo perceptível na execução (< 1 % de duração).
- **RNF-046-04 (escrita, P15).** Uma rajada de 10 mil ocorrências iguais em
  1 minuto grava no máximo uma linha por grupo a cada intervalo de coleta,
  mais os exemplos. Entra no orçamento de escrita da spec 063, medido na
  bateria.
- **RNF-046-05 (robustez).** A coleta nunca atrasa nem derruba a execução que
  falhou: é assíncrona, com fila limitada. Quando a fila enche, conta sem
  guardar exemplo. A queda de um nó perde no máximo um intervalo de
  contagem, e a reconciliação recompõe o que falta (D12).
- **RNF-046-06 (privacidade).** A mensagem normalizada do grupo não guarda
  valores. Os exemplos seguem a retenção e o mascaramento da spec 019, e o
  grupo sobrevive ao expurgo sem eles.
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
- **CA-046-06** "Pedido 1234 não encontrado" e "pedido 5678 não encontrado",
  vindos da mesma linha do mesmo programa, formam 1 grupo, e a mensagem do
  grupo não traz nenhum dos dois números.
- **CA-046-07** Uma rajada de 10 mil erros iguais em 1 minuto gera:
  - 1 grupo com 10 mil ocorrências;
  - 1 aviso de "novo";
  - gravações dentro do orçamento de RNF-046-04;
  - nenhuma piora no tempo das execuções que não falharam.
- **CA-046-08** Com o grupo marcado "conhecido" e atribuído a Fulano, a
  próxima pessoa que esbarra no erro vê "este problema já é conhecido e está
  com Fulano", sem pilha.
- **CA-046-09** Um grupo marcado "corrigido na versão 12" que ocorre na
  versão 13 vira "reapareceu" e avisa o dono. Um que ocorre só na versão 11
  (ainda em uso numa filial) não reabre.
- **CA-046-10** A queda de um processo do núcleo reiniciado pelo supervisor
  aparece como grupo da fonte "núcleo", com o supervisor e a contagem, e
  avisa o administrador.
- **CA-046-11** Um conector que esgota as tentativas 200 vezes contra o mesmo
  endereço forma 1 grupo da fonte "conector", com o conector e o código HTTP.

## Experiência e automação (P18, P19)
- Perguntas em linguagem natural pelo assistente (spec 052): "o que mais
  falhou este mês?" responde com a mesma consulta pronta.
- Grupo de erro novo ou reaparecido avisa o dono sozinho (regra de alerta e
  e-mail, specs 019 e 044) e vira tarefa (spec 051); "Depurar reexecução" a
  um clique (spec 047).
- Tela de abertura com as três respostas mais úteis já calculadas, sem
  precisar montar filtro.
