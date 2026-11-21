# 064 — Portão de qualidade dos programas antes da produção

Situação: especificada (nov/2026).

## Problema
Programas do produto e do cliente (P5) vão da instância de desenvolvimento
para a de testes e para a produção por pacote de transporte assinado (spec
034). O ANA já tem peças de qualidade, mas espalhadas e opcionais:
- análise estática **só do SQL** ao salvar (spec 019, RF-019-07b);
- rastreio do SQL por execução, desempenho por comando e plano dos lentos
  (RF-019-03, 06, 07a);
- perfilamento por função, CPU e memória por execução (RF-019-05, spec 012);
- pilha com variáveis do quadro em cada erro (RF-019-04) e grupos de erro de
  longo prazo (spec 046, na fila).
Nada disso **impede** um programa ruim de chegar à produção, não há regras de
segurança e robustez além do SQL, não há testes dos próprios programas, e
ninguém compara o desempenho da versão nova com a anterior antes de
transportar.

## Decisões
- **D1 — Inspeção automática com conjuntos de regras.** Regras por categoria,
  cada uma com severidade, explicação, exemplo e — quando mecânica —
  correção sugerida:
  - *segurança*: SQL montado com texto (f-string, concatenação, `%`) em vez
    de parâmetros; segredo ou senha no código; `eval`/`exec`/importação
    dinâmica; acesso à rede, a arquivos ou a processos fora das APIs do ANA;
    dado sensível em log ou saída; permissão verificada só na tela;
  - *desempenho*: SQL dentro de laço (N+1), `SELECT *`, `LIKE '%…'`, função
    sobre coluna no filtro, leitura sem limite de tabela que cresce (spec
    019, RF-019-07c), chamada externa dentro de laço;
  - *robustez*: exceção engolida (`except: pass`), erro de negócio sem código
    e mensagem, laço sem condição de parada evidente, recursão sem limite,
    `UPDATE`/`DELETE` sem `WHERE`;
  - *padrões do produto*: identificadores, SQL e códigos de erro em inglês,
    mensagens ao usuário em português (P2a), parâmetros com rótulo,
    nomenclatura própria (P2);
  - *experiência* (P18): rotina que grava sem suporte a ensaio (spec 056),
    erro sem orientação de como resolver;
  - *disco* (P15, spec 063): gravação linha a linha em laço em vez de lote,
    regravar linha sem mudança.
- **D2 — Enquanto se digita, não só depois.** O editor do Estúdio mostra os
  achados na linha, enquanto se escreve; salvar não é bloqueado, transportar
  é.
- **D3 — Configuração por instalação.** Conjuntos de regras (padrão do
  produto + ajustes da empresa), severidade que bloqueia, **linha de base**
  (só achados novos bloqueiam um programa antigo) e **isenção** por achado,
  com justificativa, prazo e aprovação de outra pessoa (nunca de quem pediu),
  tudo na auditoria.
- **D4 — Testes dos programas.** Cada programa pode ter testes declarados
  junto dele (casos com parâmetros e resultado esperado, ou funções de teste
  Python), rodados numa transação desfeita, com dados de teste; cobertura de
  linhas por programa. A instalação define o mínimo exigido (ex.: todo
  programa que grava precisa de ao menos um teste).
- **D5 — Desempenho comparado com a versão anterior.** Antes de transportar,
  os testes do programa e as trilhas que o usam (spec 053) rodam na versão
  anterior e na nova, na instância de testes com dados mascarados de
  produção (spec 034): número de comandos SQL, tempo, CPU, memória e escrita
  em disco (spec 063). Piora acima do limite configurado é achado.
- **D6 — Falhas ligadas à versão.** Depois do transporte, os grupos de erro
  (spec 046) de um programa mostram em que versão começaram, com o pacote e
  o resultado do portão daquela versão — e a reexecução para depurar (spec
  047) a um clique.
- **D7 — O portão no transporte.** Gerar um pacote para a produção exige
  portão verde (ou isenções aprovadas) para cada programa do pacote; o
  relatório do portão vai **assinado dentro do pacote**; a produção confere a
  assinatura e recusa, pela política da instalação, pacote sem portão.
- **D8 — Tela "Qualidade"** no Desenvolvimento: por programa (achados,
  testes, cobertura, desempenho comparado, histórico de versões e falhas) e
  por pacote (resultado do portão, isenções, aprovação); tendência de
  qualidade por programa e por dono. O assistente (spec 052) explica um
  achado e propõe a correção, que a pessoa aplica e revisa.

## Requisitos funcionais
- **RF-064-01** Motor de inspeção com as categorias de D1, extensível por
  regras da instalação; achados com linha, explicação e correção sugerida.
- **RF-064-02** Inspeção no editor enquanto se digita (D2).
- **RF-064-03** Conjuntos de regras, linha de base e isenções aprovadas (D3).
- **RF-064-04** Testes de programas, execução em transação desfeita e
  cobertura (D4).
- **RF-064-05** Comparação de desempenho com a versão anterior na instância
  de testes (D5).
- **RF-064-06** Falhas ligadas à versão e ao pacote (D6).
- **RF-064-07** Portão obrigatório na geração do pacote e conferência na
  importação (D7).
- **RF-064-08** Tela "Qualidade" e explicação pelo assistente (D8).
- **RF-064-09** Os programas do próprio produto passam pelo mesmo portão na
  bateria de testes do ANA.

## Requisitos não funcionais
- **RNF-064-01** Inspeção de um programa de 1.000 linhas em menos de 200 ms
  (no editor, sem travar a digitação).
- **RNF-064-02** Portão de um pacote com 200 programas em menos de 5
  minutos, comparação de desempenho incluída.
- **RNF-064-03** Testes e comparações nunca rodam na produção nem chamam
  sistemas externos (bloqueio da instância de testes, spec 034).

## Critérios de aceite
- **CA-064-01** Programa com SQL montado por f-string mostra o achado na linha
  enquanto se digita, com a correção sugerida; o pacote com ele é recusado.
- **CA-064-02** Isenção pedida e aprovada por outra pessoa libera o pacote;
  pedida e "aprovada" pela mesma pessoa, não.
- **CA-064-03** Versão nova que dobra os comandos SQL de um teste aparece como
  piora de desempenho no portão.
- **CA-064-04** A produção recusa um pacote sem relatório de portão assinado
  (com a política ligada).
- **CA-064-05** Um erro que começou após um transporte mostra a versão, o
  pacote e o resultado do portão daquela versão.
- **CA-064-06** Os programas do produto passam no portão na bateria do ANA.
