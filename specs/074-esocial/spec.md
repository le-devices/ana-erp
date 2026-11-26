# 074 — eSocial, DCTFWeb e FGTS Digital

Situação: especificada (nov/2026). Depende da spec 072 (canal com o governo) e da spec 073 (folha).

## Problema
O eSocial é o caminho obrigatório das informações trabalhistas, previdenciárias
e de FGTS:
- **tabelas:** empregador, estabelecimentos, rubricas, lotações, processos;
- **eventos não periódicos:** admissão, alterações, afastamentos,
  desligamento, trabalhadores sem vínculo;
- **eventos periódicos:** remuneração, pagamentos, fechamento.

Dos totalizadores do eSocial saem:
- a **DCTFWeb**, com a EFD-Reinf, que gera o DARF das contribuições;
- o **FGTS Digital**, que gera a guia do FGTS.

Os eventos têm prazos curtos:
- a admissão vai antes do início do trabalho;
- o desligamento, em dias;
- os periódicos, até o dia 15 do mês seguinte.

Os riscos são concretos:
- um evento fora de ordem ou de prazo vira multa;
- uma rejeição não tratada trava o fechamento do mês;
- uma divergência entre a folha e o que o governo totalizou vira guia errada.

Escritórios e sistemas comuns tratam isso como uma tarefa separada, conferida
à mão.

## Decisões
- **D1 — O evento nasce do fato, nunca digitado.**
  - **Origem.** Cada evento é gerado a partir de uma mudança no ERP:
    - cadastro da empresa e dos estabelecimentos → S-1000 e S-1005;
    - rubrica → S-1010;
    - lotação → S-1020;
    - admissão → S-2200 (ou S-2190 preliminar);
    - alteração cadastral ou contratual → S-2205 e S-2206;
    - ausência → S-2230;
    - rescisão → S-2299;
    - trabalhador sem vínculo → S-2300, S-2306 e S-2399;
    - fechamento da folha → S-1200, S-1210 e S-1299;
    - correção → retificação ou S-3000.
  - **Como.** A geração usa as mudanças vigiadas da spec 068: um campo que
    importa ao eSocial mudou, e o evento correspondente entra na fila, com o
    prazo calculado.
- **D2 — Ordem e dependências garantidas.**
  - **Pré-requisitos.** Um evento só é enviado quando os de que depende foram
    aceitos (a tabela antes da admissão, a admissão antes da remuneração).
  - **Mesmo trabalhador.** Os eventos dele seguem em ordem (spec 072, D6).
  - **Retificação.** Só depois que o evento original tem recibo.
- **D3 — Prazos como dado, vigiados.**
  - **O quê.** O prazo de cada evento (regras do leiaute em pacote, spec 072,
    D4) é calculado na geração e mostrado na agenda (spec 075).
  - **Risco.** Um evento perto do prazo e ainda pendente vira tarefa urgente
    para quem pode resolver.
  - **Admissão.** O S-2200 é **pré-requisito** do primeiro dia de trabalho: a
    admissão guiada (spec 073, D10) não termina sem ele enviado (ou o S-2190,
    quando faltar dado).
- **D4 — Leiaute em pacote (P21).** Versões do leiaute (como a S-1.3),
  tabelas do eSocial (categorias, naturezas de rubrica, motivos), esquemas e
  regras de validação vêm em pacotes com vigência. Uma versão nova de leiaute
  é dado, não programa.
- **D5 — Validação antes de enviar, com a origem.**
  - **O quê.** Além do esquema, as regras do manual que dá para conferir
    localmente: CPF e PIS, datas coerentes, categoria × incidências, rubrica ×
    natureza.
  - **Mensagem.** O erro aponta o cadastro ou a folha a corrigir (spec 072,
    D5).
- **D6 — Retorno, totalizadores e conciliação automática.**
  - **Recibo.** O recibo de cada evento fica guardado (spec 072, D10).
  - **Totalizadores.** Os do governo (S-5001, S-5002, S-5003, S-5011, S-5013)
    são lidos e **confrontados** com a folha (spec 073): bases de INSS, IRRF e
    FGTS por trabalhador e no total.
  - **Igual.** A competência é dada como conferida.
  - **Diferente.** A divergência vira tarefa com o trabalhador, a rubrica e os
    dois valores. Nunca passa em silêncio (P17).
- **D7 — DCTFWeb.**
  - **Origem.** Fechados o S-1299 e a EFD-Reinf (R-2099, R-4099, spec 075), a
    DCTFWeb é gerada pela Receita.
  - **Com o serviço da Receita.** Com o serviço de integração da Receita para
    contadores e empresas contratado (conector), o ANA:
    - transmite a declaração;
    - emite o DARF;
    - lança o título a pagar com código de barras;
    - concilia o pagamento pelo extrato.
  - **Sem o serviço.** A tela guia o passo no e-CAC, recebe o recibo e o DARF
    (arquivo ou leitura do código de barras), e o resto segue igual: título,
    pagamento, conciliação.
  - **Valores.** O valor do DARF é conferido com os totalizadores. Uma
    diferença vira tarefa.
- **D8 — FGTS Digital.**
  - **Guia.** A guia do FGTS é obtida pelo serviço do FGTS Digital, quando
    houver acesso por integração, ou pelo mesmo passo guiado com o arquivo da
    guia.
  - **Conferência.** É conferida com o S-5003 e o S-5013 e vira título a pagar.
  - **Rescisório.** O FGTS rescisório segue o prazo da rescisão (spec 073).
- **D9 — Correções seguras.**
  - **Cadastro.** Alterar um dado já enviado gera o evento de alteração ou a
    retificação certa, conforme a regra do leiaute.
  - **Exclusão.** Excluir (S-3000) só com motivo e quatro olhos.
  - **Período fechado.** Reabrir (S-1298) só junto com a reabertura da folha
    (spec 073, D7).
  - **Antes de agir.** A tela mostra quais eventos e quais guias a correção vai
    afetar.
- **D10 — Ambientes e homologação.**
  - **Cenários.** A bateria da spec 072 (D9) roda no ambiente de produção
    restrita do eSocial:
    - tabelas;
    - admissão de CLT, de estagiário e de sócio;
    - remuneração e pagamento;
    - férias e afastamento;
    - desligamento;
    - retificação e exclusão;
    - fechamento e reabertura.
  - **Produção.** Só depois da bateria aprovada e com quatro olhos.
- **D11 — Experiência premium (P18).**
  - **Painel "eSocial".** Mostra:
    - o que falta enviar, com prazo;
    - o que espera retorno;
    - as rejeições com a ação de correção;
    - a conferência dos totalizadores;
    - a situação da DCTFWeb e do FGTS do mês.
  - **Linha do tempo.** Cada trabalhador tem a sua linha do tempo de eventos.
  - **Mensagens.** Em português, sem código de evento para quem não precisa.
    O código aparece para o especialista.
  - **Escritório.** Um escritório contábil que atende a empresa pode receber
    acesso de procurador, com escopo só de Pessoal (spec 009).

## O que a pessoa deixa de fazer (P19)
- Digitar eventos no eSocial ou num segundo sistema.
- Conferir os totalizadores contra a folha.
- Controlar prazos de admissão, desligamento e periódicos numa planilha.
- Montar a DCTFWeb e a guia do FGTS e lançar os títulos à mão.

## Requisitos funcionais
- **RF-074-01** Eventos gerados a partir dos fatos do ERP, pelas mudanças
  vigiadas (D1).
- **RF-074-02** Ordem e dependências entre eventos (D2).
- **RF-074-03** Prazos calculados e vigiados; a admissão exige o evento antes
  do início (D3).
- **RF-074-04** Leiaute, tabelas e regras em pacotes com vigência (D4).
- **RF-074-05** Validação local com a origem do erro (D5).
- **RF-074-06** Recibos, totalizadores e conciliação automática com a folha
  (D6).
- **RF-074-07** DCTFWeb por serviço da Receita ou passo guiado, com título e
  conciliação (D7).
- **RF-074-08** Guia do FGTS Digital conferida e lançada (D8).
- **RF-074-09** Alterações, retificações, exclusão e reabertura seguras, com o
  impacto mostrado antes (D9).
- **RF-074-10** Bateria de homologação na produção restrita e produção com
  quatro olhos (D10).
- **RF-074-11** Painel "eSocial", linha do tempo do trabalhador e acesso do
  escritório contábil (D11).

## Requisitos não funcionais
- **RNF-074-01 (desempenho).**
  - Gerar e validar os eventos periódicos de 1.000 trabalhadores leva até 30 s.
  - O envio respeita o tamanho de lote e a vazão do eSocial, sem segurar a
    folha nem as telas.
- **RNF-074-02 (robustez).**
  - Nenhum evento é enviado duas vezes sem consulta pelo recibo (spec 072).
  - Uma rejeição não trava os eventos independentes dos outros trabalhadores.
  - Uma queda do nó retoma do ponto em que parou.
- **RNF-074-03 (segurança).** Os dados pessoais e os valores nos eventos seguem
  o sigilo da spec 073 (D9). O conteúdo dos eventos só é visível a Pessoal e
  ao procurador autorizado.

## Critérios de aceite
- **CA-074-01** A admissão de um empregado CLT envia o S-2200 na produção
  restrita, com o recibo guardado, antes da data de início. Faltando o CPF de
  um dependente, a admissão pede o dado e oferece o S-2190.
- **CA-074-02** O fechamento da folha de um mês envia S-1200, S-1210 e S-1299.
  Os totalizadores batem com a folha, e a competência aparece conferida. Com
  uma base de INSS diferente, vira tarefa com o trabalhador e os dois valores.
- **CA-074-03** Uma rejeição de um trabalhador não impede o envio dos demais.
  Corrigido o cadastro, o evento sai de novo, e o prazo fica visível o tempo
  todo.
- **CA-074-04** Com o serviço da Receita simulado, a DCTFWeb do mês é
  transmitida, o DARF vira título a pagar com o valor conferido e o pagamento
  é conciliado pelo extrato.
- **CA-074-05** Alterar o salário de um empregado depois do S-1200 do mês
  mostra que a folha precisa ser reaberta. A reabertura com quatro olhos gera
  o S-1298, a retificação do S-1200 e o novo fechamento.
