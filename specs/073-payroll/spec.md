# 073 — Folha de pagamento (Brasil)

Situação: especificada (nov/2026). Instalações no Brasil. É a base do eSocial (spec 074) e alimenta as obrigações
(spec 075), o financeiro, a contabilidade e os custos de projeto.

## Problema
Uma empresa brasileira com uma pessoa registrada já precisa de folha:
- salário, adiantamento, férias com um terço, 13º e rescisão;
- INSS, IRRF e FGTS;
- holerite;
- guias;
- eventos do eSocial.

Sócios recebem pró-labore. Autônomos e estagiários recebem por outras regras.
Hoje o ANA não tem folha. A empresa usa outro sistema ou um escritório
contábil, e o resultado volta ao ERP **digitado**: o custo da hora nos projetos
fica estimado, os encargos entram como um lançamento só e os pagamentos são
feitos à mão no banco.

A legislação trabalhista e previdenciária muda todo ano: tabelas do INSS e do
IRRF, salário mínimo, teto, regras do eSocial. As convenções coletivas mudam
pisos e adicionais por sindicato. Um cálculo errado vira passivo trabalhista.

## Decisões
- **D1 — Quem entra na folha.** Cada vínculo tem categoria (a tabela de
  categorias do eSocial, como dado), e a categoria decide incidências,
  documentos e eventos:
  - empregado CLT (prazo indeterminado, determinado, intermitente);
  - sócio com pró-labore;
  - contribuinte individual (autônomo, com recibo de pagamento);
  - estagiário;
  - jovem aprendiz.
- **D2 — O colaborador é um só no ERP.** O cadastro de colaborador
  (`projects.employee`, spec 021) passa a ser o cadastro de pessoa do ERP, com
  as abas trabalhistas:
  - documentos;
  - endereço;
  - dependentes (IRRF, salário-família, plano);
  - contrato (admissão, cargo e CBO, jornada, salário, sindicato,
    estabelecimento, lotação, centro de custo);
  - conta para pagamento;
  - histórico contratual com vigência.

  Os apontamentos de horas, as ausências (`projects.absence`), a agenda de
  campo e o acesso ao sistema continuam ligados à mesma pessoa. Nada é
  cadastrado duas vezes.
- **D3 — Rubricas e tabelas são dados (P21).**
  - **Rubricas.** Proventos, descontos e bases: cada rubrica tem a fórmula na
    linguagem fechada do motor de impostos (spec 049, D4) e as incidências
    (INSS, IRRF, FGTS, contribuição sindical) ligadas à natureza da rubrica do
    eSocial.
  - **Tabelas com vigência.** INSS progressivo, IRRF (com a dedução
    simplificada), salário mínimo, teto, salário-família, percentuais de FGTS,
    alíquotas patronais (RAT, FAP, terceiros pelo FPAS) e a regra do regime da
    empresa (Simples por anexo, Presumido, Real).
  - **Entrega.** Tudo chega por **pacotes** pelas atualizações do produto, como
    os pacotes de regras da spec 049. Mudou a lei: um pacote novo com a data.
  - **Convenções coletivas.** São dados por sindicato (piso, reajuste com data,
    adicionais, horas extras, auxílios), versionados.
- **D4 — Cálculo explicado e reproduzível.**
  - **Valores.** Cada valor do holerite diz de onde veio: rubrica, fórmula,
    tabela e vigência, base, dias e horas.
  - **Reprodução.** O mesmo colaborador e a mesma competência com os mesmos
    dados dão sempre o mesmo resultado.
  - **Casos de teste trabalhistas.** Têm resultado esperado (como na spec 049,
    D6): "salário de R$ 5.000 com 2 dependentes", "férias com abono",
    "rescisão sem justa causa com aviso indenizado". Eles rodam a cada pacote
    ou mudança de rubrica **antes de valer**, mostrando o que mudou.
- **D5 — Processos cobertos.**
  - **Fase 1:**
    - folha mensal e adiantamento;
    - pró-labore e pagamento de autônomo;
    - estágio;
    - férias (cálculo, aviso, abono, programação e vencimentos);
    - 13º em duas parcelas;
    - rescisão (aviso trabalhado ou indenizado, multa do FGTS, saldo,
      proporcionais);
    - afastamentos vindos das ausências;
    - horas extras, adicional noturno e DSR a partir de lançamentos variáveis;
    - provisões mensais de férias e 13º.
  - **Fase 2:**
    - ponto eletrônico por conector (arquivo AFD da Portaria 671 e REP-P);
    - benefícios (vale-transporte, alimentação, plano de saúde);
    - consignado (eConsignado);
    - PLR;
    - adiantamento de 13º nas férias;
    - jornada 12×36 e banco de horas.
  - **Fase 3:** a saúde e segurança do trabalho do eSocial (S-2210, S-2220,
    S-2240), com dados do médico do trabalho por conector ou digitação
    assistida.
- **D6 — Fechamento em passos guiados.** A folha de uma competência é um
  processo do BPM (spec 039), com tarefas e responsáveis:
  1. **Variáveis.** Horas extras, faltas e comissões são importadas (apontamento,
     ponto, vendas) ou lançadas. O que falta aparece como pendência.
  2. **Prévia.** Cálculo em ensaio (spec 056), com a comparação com o mês
     anterior por pessoa e rubrica. Diferenças acima do limite configurado são
     destacadas e explicadas.
  3. **Conferência.** Casos de teste e verificações de consistência: líquido
     negativo, salário abaixo do piso, férias vencendo o período concessivo.
  4. **Fechamento.** Com **quatro olhos**: quem calcula não fecha.
  5. **Saídas automáticas (P17):**
     - holerites no portal do colaborador;
     - títulos a pagar do líquido e das guias;
     - lançamentos contábeis por centro de custo;
     - eventos do eSocial (spec 074);
     - arquivo de pagamento ao banco;
     - custo real por hora para os projetos.
- **D7 — Integração com o resto do ERP.**
  - **Contabilidade.** Salários, encargos e provisões por centro de custo e
    projeto, pelas contas padrão da spec 027, na mesma transação do
    fechamento.
  - **Financeiro.**
    - O líquido de cada pessoa é um título a pagar, pago por arquivo de
      remessa ou PIX em lote (conector bancário, spec 022).
    - As guias (DARF da DCTFWeb, guia do FGTS Digital, DAS do Simples na parte
      patronal) também viram títulos, com vencimento.
    - A conciliação pelo extrato fecha o ciclo sem conferência manual.
  - **Projetos.** O custo da hora de cada colaborador (spec 038, custo das
    horas) passa a ser o **custo real**: salário, encargos e provisões do mês,
    divididos pelas horas. Ele é recalculado no fechamento, e a diferença
    entre o estimado e o real é apropriada aos projetos.
  - **Fator R (Simples).** A folha dos 12 meses alimenta o fator R do motor de
    impostos (Anexo III × V), sem digitação.
  - **Retroativos.** Uma mudança depois do fechamento (reajuste da convenção
    com data passada) gera diferenças na competência seguinte, com o cálculo
    de cada mês. Reabrir uma competência fechada exige motivo e quatro olhos,
    e dispara as retificações no eSocial.
- **D8 — Portal do colaborador.** O colaborador vê pelo portal (spec 037) e
  pelo aplicativo (spec 060):
  - holerite, informe de rendimentos anual e férias programadas;
  - pede férias e adiantamento, que viram tarefa de aprovação;
  - atualiza dados pessoais e dependentes com comprovante, com aprovação de
    Pessoal (spec 040, campos sensíveis).
- **D9 — Sigilo e LGPD.**
  - **Classificação.** Salário, rubricas, dependentes e dados de saúde são
    sigilosos (classificação da spec 068, D10). Só o grupo Pessoal e o próprio
    colaborador os veem, com escopo de dados (spec 009). O histórico mascara.
  - **Assistente e simulação.** Não mostram valores individuais a quem não
    pode.
  - **Auditoria.** Cada consulta a uma folha individual vai para a trilha
    (spec 024).
  - **Retenção.** Segue o prazo trabalhista (dados como regra de retenção).
- **D10 — Experiência premium (P18).**
  - **Abertura.** A folha abre na competência do mês, com o passo atual e o
    que falta.
  - **Holerite.** O holerite na tela é o mesmo do portal, com a explicação ao
    tocar no valor.
  - **Admissão.** É um fluxo guiado que pede só o que a categoria exige e gera
    o S-2200 (spec 074).
  - **Rescisão.** Mostra antes de confirmar quanto custa, o que será pago e
    quando, e o prazo legal de pagamento.
  - **Simulações.** "Quanto custa contratar R$ 6.000 em CLT, como PJ ou como
    estagiário?" e "e se reajustarmos 6%?", ligadas aos cenários da spec 069.

## O que a pessoa deixa de fazer (P19)
- Redigitar a folha do escritório no ERP: salário, encargos, provisões e
  pagamentos já saem lançados.
- Montar o arquivo de pagamento no banco e conferir crédito a crédito.
- Atualizar à mão o custo-hora dos projetos.
- Calcular o fator R.
- Lembrar férias vencendo e prazos de rescisão: viram tarefas com data.

## Requisitos funcionais
- **RF-073-01** Categorias de vínculo como dado, com incidências e eventos (D1).
- **RF-073-02** Cadastro único de colaborador com abas trabalhistas e
  histórico contratual com vigência (D2).
- **RF-073-03** Rubricas com fórmulas fechadas e incidências; tabelas, regimes
  e convenções coletivas com vigência, em pacotes (D3).
- **RF-073-04** Cálculo explicado e reproduzível; casos de teste que rodam
  antes de cada mudança valer (D4).
- **RF-073-05** Processos da fase 1 (folha, adiantamento, pró-labore,
  autônomo, estágio, férias, 13º, rescisão, afastamentos, variáveis,
  provisões) (D5).
- **RF-073-06** Fechamento guiado: variáveis, prévia com comparação,
  conferência e quatro olhos (D6).
- **RF-073-07** Saídas automáticas para contabilidade, financeiro, projetos,
  fator R e eSocial; retroativos e reabertura com retificação (D7).
- **RF-073-08** Portal e aplicativo do colaborador com pedidos e aprovação
  (D8).
- **RF-073-09** Sigilo, escopo, auditoria de consulta e retenção (D9).
- **RF-073-10** Admissão e rescisão guiadas, holerite explicado e simulações de
  custo (D10).

## Requisitos não funcionais
- **RNF-073-01 (desempenho).**
  - O cálculo de um colaborador na tela leva até 300 ms no p95.
  - A folha de 1.000 colaboradores sai em até 60 s, e a de 10.000 em até
    10 min, em paralelo, sem segurar quem está usando o sistema.
  - A prévia em ensaio tem o mesmo tempo.
- **RNF-073-02 (robustez).**
  - Recalcular é idempotente e substitui o cálculo da competência aberta.
  - Uma competência fechada é imutável no banco: só a reabertura com motivo e
    quatro olhos a muda.
  - Uma queda no meio do cálculo não deixa folha pela metade, porque cada
    colaborador é uma transação e o fechamento só acontece com todos
    calculados.
- **RNF-073-03 (correção).**
  - Os casos de teste trabalhistas do produto cobrem cada rubrica padrão e
    cada processo da fase 1, com os valores conferidos por um especialista
    antes da primeira instalação. É uma pendência do dono, com a validação
    registrada.
  - Arredondamentos e datas seguem a regra legal de cada cálculo.
- **RNF-073-04 (segurança).** Os valores individuais nunca aparecem em log,
  rastreio de execução, alerta ou mensagem de erro. O teste procura valores de
  salário nesses lugares.
- **RNF-073-05 (escrita, P15).** O cálculo grava o resultado por colaborador e
  rubrica uma vez por competência; a prévia em ensaio não grava. As entradas
  no orçamento da spec 063 ficam no plan.md.

## Critérios de aceite
- **CA-073-01** Uma empresa do Simples com dois sócios (pró-labore) e um
  empregado CLT fecha a folha de um mês:
  - holerites no portal;
  - INSS e IRRF iguais aos casos de teste;
  - títulos do líquido e das guias;
  - lançamentos por centro de custo;
  - custo-hora dos projetos atualizado;
  - fator R recalculado.

  Ninguém digita nada fora das variáveis.
- **CA-073-02** Um pacote com a tabela do INSS do ano seguinte, com vigência
  em 1º de janeiro, não muda a folha de dezembro e vale na de janeiro. Os
  casos de teste mostram a diferença antes de aceitar o pacote.
- **CA-073-03** Uma rescisão sem justa causa com aviso indenizado mostra o
  valor e o prazo antes de confirmar. O título vence dentro do prazo legal, e
  o S-2299 sai pela spec 074.
- **CA-073-04** Quem calculou a folha não consegue fechá-la. A segunda pessoa
  fecha, e as duas ficam na auditoria.
- **CA-073-05** Um vendedor sem acesso a Pessoal não vê o salário de ninguém
  na folha, no assistente, no histórico nem nas simulações. O próprio
  colaborador vê só o seu holerite no portal.
- **CA-073-06** Um reajuste da convenção publicado em março com vigência em
  janeiro gera, na folha de março, as diferenças de janeiro e fevereiro, com o
  cálculo de cada mês explicado.
