# 049 — Motor de impostos

Situação: especificada (nov/2026).

## Problema
Hoje só a fatura de projeto calcula imposto (ISS, com alíquota e retenção no
próprio programa); pedidos, faturas de venda, compras e notas de fornecedor
não calculam nada. Espalhar cálculo tributário pelos programas torna cada
mudança de lei uma caça a trechos de código. E a legislação brasileira muda o
tempo todo — em especial durante a **reforma tributária**: CBS e IBS
convivem com PIS/COFINS, ICMS, ISS e IPI de 2026 a 2033, com alíquotas e
regras de transição que mudam ano a ano, e o Imposto Seletivo entra no
caminho. O ANA é licenciado para muitas empresas, cada uma com regime,
estados, atividades e benefícios próprios.

## Decisões
- **D1 — Um único serviço calcula impostos para todo o sistema.** Biblioteca
  `tax.engine` (e serviço `tax.calculate` para API e outros sistemas): recebe
  um documento (operação, data, emitente, destinatário, itens com NCM/NBS,
  quantidades, valores, frete, seguro, desconto, outras despesas) e devolve,
  por item e no total, cada tributo com base, alíquota, valor, redução,
  retenção, informações para a nota e a **explicação** (quais regras valeram e
  por quê). Nenhum programa calcula imposto por conta própria; o ISS atual
  dos projetos passa a usar o motor.
- **D2 — Regras são dados, com vigência.** Cada regra tem início e fim de
  vigência e é escolhida pela data do fato gerador. Mudou a lei: cria-se uma
  regra nova com a data — nada de editar a antiga nem tocar em programa.
- **D3 — Escolha da regra por critérios.** Tipo de operação (venda, compra,
  serviço prestado/tomado, devolução, remessa, transferência), finalidade
  (consumo, revenda, industrialização, ativo), NCM/NBS (código ou prefixo),
  grupo de itens, UF e município de origem e destino, regime e contribuinte
  do emitente e do destinatário (spec 043), consumidor final, CFOP/natureza e
  classificação tributária da reforma. A regra **mais específica** vence;
  empate é erro de configuração apontado na tela (nunca escolha silenciosa).
- **D4 — Fórmulas seguras.** Base, redução de base, alíquota, cálculo por
  dentro ou por fora, inclusão de um tributo na base de outro, substituição
  tributária (MVA, pauta), diferencial de alíquota, fundo de combate à
  pobreza, mínimo para retenção — expressos numa linguagem de fórmulas
  **fechada** (aritmética, comparações, funções de arredondamento, valores do
  documento e de tabelas), sem código livre. Casos raros: um "programa de
  exceção" declarado na regra, executado com limites e registrado.
- **D5 — Tabelas de apoio versionadas.** Alíquotas por UF e por NCM, MVA,
  benefícios, códigos (CST/CSOSN, cClassTrib), municípios e alíquotas de ISS,
  faixas do Simples — tabelas com vigência, importáveis (CSV) e entregues em
  **pacotes de regras** pelas atualizações do produto (spec 028), que o
  administrador compara e aceita como os programas.
- **D6 — Casos de teste tributários.** Cada empresa mantém casos ("venda de
  protótipo para indústria em SP", "serviço de P&D para órgão público com
  retenção") com o resultado esperado; **toda mudança de regra ou pacote roda
  os casos antes de valer** e mostra o que mudou. Simulação: "como ficaria
  este pedido com as regras de 2027?".
- **D7 — Integração.** Pedido, fatura de venda, fatura de projeto, compra e
  nota de fornecedor (confronto com a nota recebida — spec 038), devolução e
  serviço chamam o motor; os tributos vão para os lançamentos contábeis
  (contas por tributo, recuperáveis ou custo) e para as retenções nos títulos
  a pagar/receber (spec 031), sem conciliação manual (P17).
- **D8 — Fases.** (1) motor, linguagem de fórmulas, vigência, casos de teste,
  ISS e retenções federais e municipais (IRRF, PIS/COFINS/CSLL, INSS, ISS
  retido) — o caso de empresas de serviço; (2) ICMS (incluindo ST, DIFAL e
  FCP), IPI e PIS/COFINS cumulativo e não cumulativo, Simples Nacional; (3)
  transição da reforma: CBS, IBS e Imposto Seletivo convivendo com os
  tributos atuais, alíquotas de transição por ano, créditos.
- **D9 — Responsabilidade.** O produto entrega o motor e **pacotes de regras
  de exemplo marcados "conferir com o contador"**; quem valida as regras de
  cada empresa é o responsável tributário dela. A emissão de documentos
  fiscais eletrônicos (NF-e, NFS-e, comunicação com a SEFAZ e prefeituras,
  certificado digital) fica fora desta spec (spec futura), mas o resultado do
  motor já traz os campos de que ela precisará.

## Requisitos funcionais
- **RF-049-01** Serviço de cálculo (D1) com resultado por item e total e a
  explicação das regras aplicadas.
- **RF-049-02** Cadastro de tributos, regras e tabelas com vigência (D2, D5);
  nova vigência a partir de uma regra existente ("copiar com nova data").
- **RF-049-03** Seleção por critérios com especificidade e detecção de
  conflito (D3); tela "Qual regra vale?" para um caso informado.
- **RF-049-04** Linguagem de fórmulas fechada, com validação ao salvar e
  mensagens claras (D4); programa de exceção declarado.
- **RF-049-05** Casos de teste tributários, execução obrigatória antes de
  ativar regra ou pacote, relatório de diferenças, simulação por data (D6).
- **RF-049-06** Pacotes de regras pelas atualizações do produto (D5, spec 028).
- **RF-049-07** Integração com vendas, projetos, compras, notas de
  fornecedor, devoluções, contabilidade e títulos (D7); migração do ISS dos
  projetos.
- **RF-049-08** Fase 1 (D8): ISS por município e retenções federais e
  municipais com mínimos e responsabilidade.
- **RF-049-09** Fase 2 (D8): ICMS (próprio, ST, DIFAL, FCP), IPI, PIS/COFINS,
  Simples Nacional.
- **RF-049-10** Fase 3 (D8): CBS, IBS e Imposto Seletivo na transição.
- **RF-049-11** Registro: cada cálculo guardado com o documento (entrada,
  regras e versões usadas, resultado) — recalcular uma fatura antiga dá o
  mesmo resultado.

## Requisitos não funcionais
- **RNF-049-01** Documento de 200 itens calculado em < 300 ms (regras e
  tabelas em cache, invalidadas na mudança).
- **RNF-049-02** Determinístico e reproduzível: mesma entrada, mesmas regras
  → mesmo resultado; arredondamento conforme a regra, em decimal (nunca
  ponto flutuante).
- **RNF-049-03** Só quem tem permissão tributária altera regras; toda
  alteração tem autor, motivo e casos de teste executados registrados.
- **RNF-049-04** Nenhum cálculo de imposto fora do motor (verificação
  automática no código dos programas do produto).

## Critérios de aceite
- **CA-049-01** Fatura de serviço para tomador com retenção: ISS, IRRF e
  PIS/COFINS/CSLL calculados pelas regras vigentes, retidos nos títulos e
  lançados nas contas certas; a fatura de projeto dá o mesmo ISS de antes.
- **CA-049-02** Nova alíquota com vigência futura não muda documentos de hoje
  e vale a partir da data; recalcular documento antigo dá o resultado antigo.
- **CA-049-03** Duas regras igualmente específicas para o mesmo caso: a
  ativação é recusada mostrando o conflito.
- **CA-049-04** Mudança de regra que altera um caso de teste mostra a
  diferença e exige confirmação; sem casos afetados, ativa direto.
- **CA-049-05** Fórmula com código livre ou função desconhecida é recusada ao
  salvar.
- **CA-049-06** (fase 2) Venda interestadual para não contribuinte calcula
  ICMS com DIFAL e FCP conforme as tabelas da UF de destino.
- **CA-049-07** (fase 3) Um documento de 2027 traz CBS e IBS nas alíquotas de
  transição do pacote, e o de 2026 nas do ano anterior.

## Experiência e automação (P18, P19)
- "Por que este imposto?" em todo documento: a explicação das regras
  aplicadas em linguagem simples, também pelo assistente (spec 052).
- Ensaio por data (spec 056): "como fica este pedido com as regras de 2027?"
  num clique.
- Pacotes de regras chegam pelas atualizações e rodam os casos de teste
  sozinhos; só a diferença chega ao responsável tributário, como tarefa.
- Aviso automático de vigência terminando sem regra seguinte (ex.: alíquota
  de transição que acaba em 31/12 sem a do ano seguinte).
- Nenhum valor de imposto é digitado à mão em documento.
