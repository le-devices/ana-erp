# 076 — Funcionalidades por perfil: ligar só o que a empresa usa

Situação: especificada (nov/2026). Complementa a licença (spec 009: o que a empresa **pode** usar) e a implantação
guiada (spec 061: o perfil escolhido na primeira configuração).

## Problema
O ANA cobre muita coisa: vendas, compras, estoque, produção, projetos, campo,
logística, financeiro, contabilidade, fiscal e, em breve, folha e eSocial.
Uma empresa de P&D com três pessoas usa uma fração disso. Ela vê menus,
campos, rotinas, regras sugeridas e pendências de coisas que nunca vai usar:
- número de série;
- ST de ICMS;
- NFC-e;
- produção com roteiro;
- moeda estrangeira.

Isso torna o produto mais difícil do que precisa ser (P18). Também tem custo:
- verificações que rodam à toa;
- rotinas agendadas que não servem;
- checklist de prontidão cobrando o que não interessa.

A licença de módulos não resolve. Ela é comercial e grossa ("produção sim ou
não"). Não diz "produzimos, mas sem controle de lote", "vendemos só serviço"
nem "temos folha só de sócios". Ela também não muda quando a empresa cresce:
quem começa só com serviços e passa a revender precisa **ligar** o estoque
sem reinstalar nem chamar consultoria.

## Decisões
- **D1 — Funcionalidades como catálogo de dados.**
  - **O que cada funcionalidade tem:**
    - código;
    - nome e explicação em português;
    - área;
    - o módulo da licença a que pertence, se houver;
    - as **dependências** ("eSocial exige Folha"; "NF-e exige Motor de
      impostos: ICMS");
    - os **efeitos**: menus, telas, campos, rotinas, programas, agendamentos,
      modelos de processo, regras sugeridas, verificações, itens do checklist.
  - **Granularidade.** Mais fina que o módulo. Exemplos:
    - vendas: venda de mercadoria, venda de serviço, NFC-e no balcão, crédito
      de cliente;
    - estoque: estoque, lote e validade, número de série, depósitos múltiplos;
    - produção: produção, roteiro e apontamento;
    - projetos: projetos, faturamento por marco;
    - campo: ordens de serviço em campo;
    - finanças: centros de custo obrigatórios, moeda estrangeira, várias
      filiais;
    - pessoal e fiscal: folha, eSocial, NF-e, NFS-e, obrigações do Simples,
      obrigações do Presumido.
  - **Entrega.** O catálogo do produto chega pelas atualizações (spec 028),
    como os pacotes. Uma extensão do cliente declara a qual funcionalidade
    pertence (`# ana:feature …`, revisado pelo portão da spec 064).
- **D2 — Ligado só se licenciado.** Uma funcionalidade só liga se o módulo dela
  está licenciado (spec 009). Desligar nunca muda a licença. A tela mostra as
  três situações sem confundir:
  - "não contratado";
  - "contratado e desligado";
  - "ligado".
- **D3 — Perfis prontos, sempre editáveis.**
  - **Perfis.** Perfis de negócio (serviços, P&D, comércio, indústria, campo,
    misto) são conjuntos de funcionalidades.
  - **Uso.** A implantação guiada (spec 061, D2) parte de um perfil. A empresa
    liga e desliga o que quiser depois.
  - **Diferença.** A tela mostra o que mudou em relação ao perfil.
  - **Sugestão.** Um perfil novo do produto não muda a empresa, só aparece como
    sugestão.
- **D4 — Desligado some de verdade, sem perder nada.** Desligar uma
  funcionalidade:
  - **Tira:** menus, telas, campos, atalhos, itens da paleta de comandos,
    regras e rotinas sugeridas, perguntas do assistente e itens do checklist
    de prontidão.
  - **Recusa:** os programas dela respondem `FEATURE_OFF`, dizendo qual e
    quem pode ligar, como o `NOT_LICENSED`.
  - **Pausa:** os agendamentos e as verificações dela.
  - **Pula:** nas rotinas que continuam, os passos dela. Por exemplo, sem
    "lote e validade" o recebimento não pede lote; sem "centro de custo
    obrigatório" o lançamento não exige centro.
  - **Preserva:** os dados ficam intactos e legíveis em consultas e
    relatórios. Religar devolve tudo como estava.
  - **Validações do banco:** as que dependem de uma funcionalidade
    ("lançamento exige centro de custo") leem o estado dela, de modo que nunca
    há uma regra valendo para algo desligado.
- **D5 — Ligar é guiado e verifica o que falta.**
  - **O que é pedido.** Ligar uma funcionalidade abre o que ela precisa para
    funcionar, como um passo da implantação guiada (spec 061): cadastros,
    contas, parâmetros, certificado, série de notas. Exemplos: "ligar NF-e:
    falta certificado (spec 072), série e a bateria de homologação"; "ligar
    Folha: cadastre a convenção coletiva e as contas da folha".
  - **Dependências.** São oferecidas junto ("eSocial precisa de Folha: ligar as
    duas?").
  - **Antes de pronta.** Enquanto falta algo, a funcionalidade fica "ligando":
    visível para o administrador e escondida da operação.
- **D6 — Desligar mostra o impacto antes, e pode ser recusado.**
  - **O ensaio.** Antes de desligar, a tela mostra:
    - os dados que ficam só para consulta;
    - os documentos em andamento;
    - as regras, esteiras e agendamentos afetados;
    - as integrações;
    - as outras funcionalidades que dependem dela.
  - **Recusa com motivo.** Desligar é recusado quando deixaria algo pela
    metade, com o caminho para resolver. Por exemplo: NF-e com notas em
    contingência ainda não transmitidas; Folha com competência aberta;
    Estoque com saldo e pedidos abertos.
- **D7 — Escopo: empresa, filial e ambiente.**
  - **Empresa e filial.** Cada funcionalidade vale para a empresa ou, quando
    faz sentido, por filial ou estabelecimento: NFC-e só na loja, produção só
    na fábrica.
  - **Ambientes.** Ligar numa instância de testes (spec 034) não liga em
    produção. A mudança vai para a produção pelo transporte, com quatro olhos,
    como uma configuração.
- **D8 — Rápido e sem custo.**
  - **Em memória.** O estado das funcionalidades fica em memória em cada nó
    (como os valores da empresa, spec 065) e é atualizado por evento quando
    muda.
  - **Consulta.** Saber se algo está ligado não vai ao banco, nem na tela nem
    no programa.
  - **No banco.** As validações do banco leem o estado por uma função estável
    e barata, sem consultar tabela por linha.
  - **Custo do desligado.** O que está desligado não roda: nada de verificação,
    agendamento ou gatilho trabalhando à toa (P15).
- **D9 — Testes com perfis reais.**
  - **Na bateria.** Roda com tudo ligado e também com cada perfil pronto. O
    rastreador do Estúdio (spec 050) confere, em cada perfil:
    - nenhum link para tela desligada;
    - nenhuma tela quebrada;
    - nenhuma lista vazia pedindo ação de funcionalidade desligada.
  - **Uso simulado (spec 067).** Também roda por perfil.
  - **Falta de dono.** Uma funcionalidade nova no produto sem efeitos
    declarados no catálogo é recusada pelo teste.
- **D10 — Auditoria e transparência.**
  - **Auditoria.** Quem ligou ou desligou, quando, por quê e o impacto
    mostrado na hora vão para a trilha (spec 024).
  - **Painel "Funcionalidades".** Agrupado por área, com:
    - o estado de cada funcionalidade;
    - a explicação;
    - o que ela traz;
    - quanto é usada: execuções e registros do último mês, sem gravar nada a
      mais, lido do que já existe.
  - **Sugestões (spec 051).** "Vocês nunca usaram depósitos múltiplos:
    desligar simplifica o recebimento" e o inverso: "três notas de entrada com
    número de série no texto: ligar número de série?".

## O que a pessoa deixa de fazer (P19)
- Atravessar menus e campos que não servem para a empresa.
- Chamar consultoria para "habilitar" algo que a empresa passou a fazer.
- Responder pendências e avisos de coisas que não usa.
- Descobrir sozinha que, ao começar a revender, precisa configurar estoque,
  contas e impostos: ligar guia isso.

## Requisitos funcionais
- **RF-076-01** Catálogo de funcionalidades com dependências e efeitos
  declarados, pelas atualizações; extensões declaram a sua (D1).
- **RF-076-02** Ligar só o que está licenciado; três situações distintas na
  tela (D2).
- **RF-076-03** Perfis prontos de negócio, editáveis, com a diferença
  mostrada (D3).
- **RF-076-04** Desligar tira menus, telas, campos, rotinas, regras,
  sugestões e checklist; programas respondem `FEATURE_OFF`; dados
  preservados; validações coerentes (D4).
- **RF-076-05** Ligar guiado, com o que falta e as dependências (D5).
- **RF-076-06** Ensaio do impacto e recusa ao desligar quando algo ficaria
  pela metade (D6).
- **RF-076-07** Escopo por empresa, filial e ambiente, com transporte e quatro
  olhos (D7).
- **RF-076-08** Estado em memória em cada nó; nada desligado roda (D8).
- **RF-076-09** Bateria e rastreador por perfil; funcionalidade sem efeitos
  declarados é recusada (D9).
- **RF-076-10** Auditoria, painel com uso e sugestões de ligar e desligar
  (D10).

## Requisitos não funcionais
- **RNF-076-01 (desempenho).**
  - Consultar o estado de uma funcionalidade custa menos de 1 µs no núcleo e
    não toca no banco.
  - O menu e a paleta de comandos não ficam mais lentos com o catálogo
    (orçamento da spec 050).
  - Ligar ou desligar chega a todos os nós em até 2 s.
- **RNF-076-02 (robustez).** Ligar e desligar são atômicos: o estado e os
  efeitos (agendamentos pausados, regras desligadas) mudam na mesma transação.
  Um nó que volta de uma queda lê o estado do banco antes de atender.
- **RNF-076-03 (segurança).**
  - Só o administrador liga e desliga.
  - A produção exige quatro olhos (D7).
  - Desligar nunca serve para driblar uma exigência legal em andamento: a
    recusa da D6 vale também pela API.
- **RNF-076-04 (escrita, P15).** O estado só é gravado quando muda. O uso
  mostrado no painel é lido do que já existe (execuções, contagem de
  registros), sem tabela nova escrita por evento.

## Critérios de aceite
- **CA-076-01** Uma empresa com o perfil "Serviços e P&D" não vê estoque,
  produção, NFC-e nem expedição no menu, na paleta, nas telas nem no
  assistente.
  - Chamar `inventory.stock_in` pela API responde `FEATURE_OFF` com o nome da
    funcionalidade.
  - O rastreador do Estúdio passa nesse perfil sem link quebrado.
- **CA-076-02** Ligar "Venda de mercadoria" guia o que falta (depósito, contas
  de estoque, regras de impostos de mercadoria). A funcionalidade fica
  "ligando" para a operação até tudo estar pronto e depois aparece para todos.
- **CA-076-03** Desligar "Número de série" com itens seriados em estoque
  mostra o impacto e é recusado, com o caminho. Sem itens seriados, desliga,
  os campos somem do recebimento e, ao religar, os números antigos estão
  todos lá.
- **CA-076-04** Desligar "Centros de custo obrigatórios" deixa o lançamento
  sem centro passar no banco. Religar volta a exigir, sem mexer nos
  lançamentos antigos.
- **CA-076-05** Ligar "eSocial" sem "Folha" oferece ligar as duas. Ligar uma
  funcionalidade de um módulo não contratado é recusado com "não contratado".
- **CA-076-06** Desligar "Produção" pausa os agendamentos de MRP e reposição
  por produção e esconde as regras sugeridas dela. Nenhum gatilho ou
  verificação de produção roda enquanto ela está desligada (medido).
- **CA-076-07** Ligar NFC-e só na filial "Loja" mostra o balcão só para quem
  opera essa filial.
