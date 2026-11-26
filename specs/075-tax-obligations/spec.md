# 075 — Obrigações acessórias, apuração e agenda fiscal

Situação: especificada (nov/2026). Depende das specs 049 (motor de impostos), 059 (documentos fiscais), 072 (canal),
073 (folha) e 074 (eSocial).

## Problema
Além de emitir notas e pagar impostos, a empresa brasileira **declara**, e o
que declara depende do regime e das operações:
- **Simples Nacional:**
  - PGDAS-D e DAS todo mês;
  - DEFIS no ano;
  - DeSTDA quando há ST ou DIFAL;
  - EFD-Reinf e DCTFWeb quando há retenções ou folha.
- **Lucro Presumido e Lucro Real:**
  - EFD ICMS/IPI, quando contribuinte;
  - EFD-Contribuições;
  - EFD-Reinf;
  - DCTFWeb e as demais declarações federais vigentes;
  - ECD e ECF no ano.
- **Estados e municípios:** declarações próprias; a de serviços tomados varia
  por município.
- **Reforma tributária:** de 2026 em diante, a CBS e o IBS são apurados a
  partir dos documentos fiscais, com o governo fazendo parte da apuração, e as
  declarações antigas convivem com as novas até 2033.

Hoje cada declaração é montada a partir de relatórios, conferida em planilha e
entregue num programa do governo. O mesmo número (o faturamento do mês) é
digitado em lugares diferentes e pode divergir. Um prazo perdido é multa
automática. Uma correção num mês passado exige descobrir, à mão, o que precisa
ser retificado.

## Decisões
- **D1 — Catálogo de obrigações como dado (P21).** Cada obrigação tem:
  - órgão;
  - periodicidade;
  - regra de prazo (dia, dia útil, antecipa ou posterga com feriado);
  - **condição de aplicabilidade** (regime, contribuinte do ICMS, há folha,
    há retenção, há ST, faturamento, UF, município);
  - leiaute e forma de entrega (serviço do governo pelo canal da spec 072, ou
    arquivo para o programa oficial).

  O catálogo chega em pacotes com vigência (spec 072, D4). A vigilância da
  spec 070 aponta as mudanças.
- **D2 — Agenda fiscal e trabalhista da empresa.**
  - **Calendário.** Do catálogo e do perfil fiscal da empresa e das filiais
    (spec 043) sai o calendário do ano: o que entregar, quando, por quem, e as
    guias a pagar.
  - **Feriados.** Nacionais, estaduais e municipais são dados.
  - **Antes do prazo.** Cada item tem um passo de preparação que começa dias
    antes, sozinho.
  - **Risco.** Um item em risco (dado faltando, rejeição, prazo perto) vira
    tarefa urgente.
  - **Num só lugar.** A agenda junta tudo: eventos do eSocial (spec 074),
    contingência da NF-e (spec 059), DAS, DARF, guias do ICMS e do FGTS.
- **D3 — Um fato, uma fonte.**
  - **De onde vêm os livros.** Livros fiscais, apurações e declarações são
    **derivados**, nunca digitados:
    - dos documentos fiscais (spec 059);
    - dos cálculos do motor (spec 049, `tax.calculation`, com a explicação);
    - da contabilidade (spec 027, lançamentos);
    - da folha (spec 073);
    - do estoque e da produção (inventário e bloco K, specs 014 e 038).
  - **Ajuste manual.** Um ajuste é um lançamento de ajuste com motivo,
    documento de suporte e quatro olhos, rastreado até a declaração.
- **D4 — Apuração com conciliação automática (P17).**
  - **Tributos.** Por tributo e período:
    - ICMS (próprio, ST, DIFAL, FCP) e IPI;
    - PIS e COFINS cumulativos e não cumulativos, com créditos;
    - Simples Nacional (RBT12, anexo, fator R vindo da folha, repartição);
    - IRPJ e CSLL do Presumido;
    - CBS e IBS, com conferência contra a apuração do governo.
  - **Conferência.** O saldo apurado é conferido com o saldo contábil das
    contas do tributo. Uma divergência vira tarefa antes da entrega, com a
    origem.
  - **Débito.** O imposto a pagar vira título com a guia (DAS, DARF, GNRE e
    guia estadual), paga e conciliada pelo extrato.
- **D5 — Geração, validação e entrega.**
  - **Arquivo.** Gerado no leiaute oficial do pacote vigente:
    - EFD ICMS/IPI;
    - EFD-Contribuições;
    - EFD-Reinf;
    - ECD;
    - ECF;
    - DeSTDA;
    - declarações estaduais e municipais por pacote.
  - **Validação.** Contra as regras dos manuais, antes de entregar.
  - **Entrega por serviço.** Onde o governo oferece serviço (EFD-Reinf; PGDAS-D
    e DCTFWeb pelo serviço de integração da Receita, quando contratado;
    GNRE), o canal da spec 072 entrega e guarda o recibo.
  - **Entrega por programa oficial.** Onde a entrega só é feita pelo programa
    oficial (o PVA da escrituração), o ANA:
    1. gera e valida o arquivo;
    2. o entrega à pessoa responsável, com o passo a passo;
    3. recebe o recibo (arquivo);
    4. confere que o recibo é daquele arquivo (hash e totais);
    5. dá a obrigação por cumprida.
- **D6 — Retificação dirigida pelo impacto.**
  - **Quais.** Uma mudança em período já declarado (nota cancelada fora do
    prazo, lançamento corrigido, folha reaberta) mostra **quais declarações
    ficam diferentes** do entregue e quanto.
  - **Retificadora.** Gerada com o mesmo cuidado, mostrando a diferença de
    imposto (a pagar ou a compensar) com a guia complementar.
  - **Período fechado.** Nada muda em período fechado sem esse aviso
    (fechamento da spec 038 e da spec 055).
- **D7 — Simples Nacional sem digitação.**
  - **Base.** O PGDAS-D do mês sai da receita das notas por anexo e atividade,
    com o fator R da folha e as retenções e ST destacadas.
  - **Entrega.** Pelo serviço de integração da Receita (conector, quando
    contratado) ou por passo guiado com o recibo e o DAS de volta.
  - **Ano.** A DEFIS anual sai dos mesmos dados e da contabilidade.
  - **Uma fonte.** O valor do DAS é o mesmo que o motor de impostos usa para a
    alíquota efetiva (spec 049, D10). Não há dois cálculos.
- **D8 — Escritório contábil como usuário, não como planilha.**
  - **Acesso.** O contador da empresa entra com acesso de procurador, com
    escopo fiscal e contábil (spec 009), e trabalha nas mesmas telas.
  - **Assinatura.** Assina as escriturações que exigem o certificado dele,
    pelo agente da spec 072 ou pelo programa oficial.
  - **Várias empresas.** Um escritório que atende várias empresas no ANA vê a
    agenda de todas num painel (fase 2, com a spec 057).
- **D9 — Testes e homologação.**
  - **Casos de teste.** Cada obrigação tem casos de teste com o arquivo
    esperado para um conjunto fixo de documentos, que rodam a cada pacote novo
    (como na spec 049, D6).
  - **Homologação.** Onde há ambiente de teste oficial (EFD-Reinf), a bateria
    da spec 072 roda lá.
  - **Validador oficial.** Onde só há o validador oficial, a bateria do CI roda
    o validador oficial em contêiner, quando a licença dele permitir. Senão, o
    conjunto de regras do pacote.
- **D10 — Experiência premium (P18).**
  - **Painel "Obrigações".** Agenda do mês com status (a preparar, pronta para
    conferir, entregue, paga, em risco), valores, diferenças contra o mês
    anterior e contra a contabilidade, e a ação de cada item.
  - **Explicação.** Um valor da declaração abre a lista dos documentos que o
    formam, com a explicação do motor de impostos para cada um.
  - **Reforma.** "Quanto paguei de CBS e IBS e quanto creditei", lado a lado
    com os tributos antigos, durante a transição.
  - **Assistente (spec 052).** Responde "o que falta para fechar o mês fiscal?"
    e "por que o PIS de março subiu?".

## O que a pessoa deixa de fazer (P19)
- Montar declarações a partir de relatórios e planilhas.
- Conferir a apuração contra a contabilidade.
- Controlar prazos em calendário à parte.
- Descobrir à mão o que retificar depois de uma correção.
- Lançar as guias no contas a pagar.

## Requisitos funcionais
- **RF-075-01** Catálogo de obrigações com prazo, aplicabilidade, leiaute e
  forma de entrega, em pacotes (D1).
- **RF-075-02** Agenda da empresa e das filiais, com feriados, preparação
  antecipada e risco como tarefa (D2).
- **RF-075-03** Livros, apurações e declarações derivados das fontes; ajuste
  com motivo e quatro olhos (D3).
- **RF-075-04** Apurações por tributo com conciliação contábil e guias como
  títulos (D4).
- **RF-075-05** Geração, validação e entrega por serviço ou programa oficial,
  com recibo conferido (D5).
- **RF-075-06** Impacto de mudanças em períodos declarados e retificadora com
  diferença de imposto (D6).
- **RF-075-07** PGDAS-D, DAS e DEFIS sem digitação, com a mesma fonte do motor
  (D7).
- **RF-075-08** Acesso do contador com escopo e assinatura (D8).
- **RF-075-09** Casos de teste por obrigação e homologação onde houver (D9).
- **RF-075-10** Painel "Obrigações", valores explicados até o documento,
  transição da reforma e assistente (D10).

## Requisitos não funcionais
- **RNF-075-01 (desempenho).**
  - A EFD de um mês com 50 mil documentos é gerada e validada em até 3 min,
    em segundo plano e sem segurar quem está usando o sistema.
  - A apuração de um mês com 50 mil documentos leva até 60 s.
  - O painel abre em até 1 s no p95 (orçamento da spec 050).
- **RNF-075-02 (robustez).**
  - Gerar de novo a mesma obrigação com os mesmos dados dá o mesmo arquivo,
    byte a byte.
  - O que foi entregue é imutável (spec 072, guarda legal).
  - Uma geração interrompida não deixa obrigação "pronta" pela metade.
- **RNF-075-03 (correção).** Cada obrigação da fase de entrega tem casos de
  teste conferidos por um especialista antes de ser oferecida em produção. É
  uma pendência do dono, registrada.
- **RNF-075-04 (escrita, P15).** A apuração e a geração gravam o resultado
  uma vez por período e versão. A agenda é calculada, sem gravação diária.

## Critérios de aceite
- **CA-075-01** Uma empresa do Simples com serviços e folha tem a agenda do
  ano montada sozinha (PGDAS-D, DAS, DCTFWeb, FGTS, eSocial, EFD-Reinf quando
  há retenção, DEFIS). Um item a 3 dias do prazo e não pronto vira tarefa
  urgente.
- **CA-075-02** O PGDAS-D do mês é gerado a partir das notas, com o fator R
  da folha. O DAS bate com a alíquota efetiva usada nas notas e vira título
  pago e conciliado. Nenhum número é digitado.
- **CA-075-03** Uma empresa do Presumido gera a EFD-Contribuições do mês. O
  saldo apurado de PIS e COFINS bate com a contabilidade; uma diferença
  plantada no teste vira tarefa com a origem. O arquivo passa nas regras do
  pacote.
- **CA-075-04** Cancelar uma nota de um mês já declarado mostra as declarações
  afetadas e a diferença de imposto. A retificadora é gerada com a guia
  complementar ou o crédito.
- **CA-075-05** A EFD-Reinf com retenções de serviços tomados é enviada no
  ambiente de testes oficial, o fechamento (R-2099 e R-4099) é aceito e a
  DCTFWeb do mês (spec 074) fica completa.
- **CA-075-06** O recibo de entrega da ECD é conferido com o arquivo gerado:
  um recibo de outro arquivo é recusado.
