# 068 — Mudanças vigiadas: qualquer alteração vira evento, sem custo quando ninguém vigia

Situação: especificada (nov/2026); plano com medições (plan.md, 26/11/2026).

## Problema
As regras "quando… então…" da spec 051 só reagem a um documento **criado** ou
que **mudou de situação**, e só em cinco documentos (pedido de venda,
requisição de compra, ordem de serviço, ordem de produção e projeto). As
empresas precisam reagir a outras mudanças:
- num cadastro: limite de crédito do cliente alterado, e-mail ou endereço
  trocado, produto bloqueado, conta bancária do fornecedor alterada (sinal
  clássico de fraude);
- num campo do documento: data de entrega do pedido adiada, valor alterado
  depois de aprovado, técnico trocado na ordem de serviço;
- em outros registros do catálogo, sem esperar uma versão nova do produto.

Os cadastros já têm histórico campo a campo (`master.change_log`, spec 040),
mas ele só serve para consulta e auditoria: nada reage a ele. Hoje, quem
precisa saber de uma mudança abre relatórios e compara, ou depende de
alguém avisar. Os sistemas externos também ficam sem saber.

Três riscos precisam ser controlados desde o desenho:
- **Escrita em disco (P15, spec 063).** Vigiar mudanças pode gravar uma
  linha a mais por alteração. Em tabelas de muito movimento, isso dobra a
  escrita.
- **Desempenho.** Um gatilho em toda linha atrasa gravações em lote (importação
  de 10 mil cadastros, reajuste de preços).
- **Segurança.** Um evento pode levar dados que a pessoa não pode ver para
  fora do ERP (e-mail, conector), ou ser usado para vigiar campos sigilosos.

## Decisões
- **D1 — Gatilho "alterado".** Nova forma de gatilho nas regras da spec 051:
  "quando **campo(s)** de **entidade** mudar", com filtros opcionais:
  - valor de origem e de destino ("de qualquer valor para *bloqueado*"),
    variação mínima para números ("limite de crédito subir mais de 20%"),
    campo esvaziado ou preenchido;
  - **origem** da mudança: pessoa na tela, API, importação, regra,
    integração, rotina. A importação fica fora por padrão (D6);
  - **registro específico**, opcional ("avisar quando *este* cliente
    mudar"), atalho no histórico do registro.
  Condições e ações continuam as da spec 051 (construtor de condições;
  executar rotina, criar tarefa, avisar, e-mail, conector), com ensaio,
  dono, limite de disparos e detecção de ciclo.
- **D2 — Catálogo do que pode ser vigiado.** Só entram entidades e campos
  declarados num catálogo de **dados**: o produto entrega o catálogo
  (cadastros da spec 040, documentos do BPM, campos de cada um com rótulo
  em português, tipo, classificação e classe de volume). Uma extensão do
  cliente pode acrescentar as próprias tabelas pelo mesmo catálogo,
  revisado pelo portão da spec 064. Ninguém escolhe uma tabela ou coluna
  livre. Nunca entram no catálogo: tabelas internas (`ana_system`, sessões,
  usuários, chaves, licenças), segredos, o próprio histórico de mudanças e
  as tabelas da automação (para evitar laço).
- **D3 — Sem regra, custo zero de escrita.** Uma alteração sem regra ativa
  que vigie aquele campo não grava nada a mais: nenhuma linha, nenhum byte
  de WAL além da própria alteração. Isso é medido na bateria (orçamento da
  spec 063).
- **D4 — Cadastros reaproveitam o histórico que já existe.** Para as
  entidades que já têm `master.change_log`, o evento **é** a linha do
  histórico. O motor de regras lê o histórico a partir do último ponto
  processado, mantido em memória e gravado só quando avança e, mesmo
  assim, uma vez por lote, não por evento. Vigiar um cadastro não acrescenta
  nenhuma escrita por alteração.
- **D5 — Documentos: só o que importa, uma vez por transação.** Nos
  documentos (que não têm histórico campo a campo), a verificação fica no
  próprio banco e só grava um evento quando:
  1. existe regra ativa para aquela entidade e aquele campo;
  2. o valor realmente mudou (regravar o mesmo valor não conta);
  3. o filtro de/para da regra é atendido.
  Várias alterações no mesmo documento na mesma transação viram **um**
  evento, com o valor inicial e o final. A verificação é instalada na
  tabela só enquanto houver regra ativa que precise dela, ou fica
  presente com um teste barato que não consulta tabela por linha. A forma
  escolhida é a mais barata **medida** (plan.md), e nunca segura a tabela
  por mais que um instante: mudar regras não pode travar a operação.
- **D6 — Gravações em lote não viram avalanche.** Uma alteração em massa
  (importação, reajuste, rotina que atualiza 10 mil linhas) gera os eventos
  numa única gravação por comando, e não um por linha. A regra escolhe:
  - **por registro**, com o limite de disparos da spec 051 (excedeu, a
    regra é pausada com aviso, como já acontece);
  - **agrupado**: uma única ação com a lista ("312 clientes tiveram o
    limite alterado pela importação de 14h02"), que é o padrão quando a
    origem é importação ou rotina em lote.
- **D7 — Tabelas de muito movimento ficam de fora.** Entidades marcadas no
  catálogo como de alto volume e só de inclusão (movimentos de estoque,
  lançamentos contábeis, apontamentos de horas) não são vigiadas por
  campo. Para elas existem os gatilhos de métrica e de horário da
  spec 051 (ex.: "estoque do item abaixo do mínimo"), que leem agregados.
  A tela explica isso e oferece a alternativa.
- **D8 — Fila curta e descartável.** Um evento processado é apagado em
  lote, ou a fila é particionada por dia e descartada inteira, o que for
  mais barato medido. O que fica é o registro do disparo (`automation.fire`,
  spec 051), com a retenção da spec 024. Nenhum "visto em" é gravado por
  ciclo, e um sistema ocioso não escreve (spec 063, D2).
- **D9 — Quem vê, vê; quem não vê, não recebe.** O evento carrega só a
  entidade, a chave, os campos vigiados e quem mudou. A regra roda em nome
  do dono (P14), com as permissões e o escopo de dados dele: se o dono não
  pode ver aquele registro ou aquele campo, a regra não dispara para ele e
  o caso fica registrado como "fora do alcance do dono", sem mostrar o
  valor. Quem cria a regra só escolhe campos que pode ler.
- **D10 — Campo sigiloso e dado pessoal.** O catálogo classifica cada campo:
  - **comum**;
  - **pessoal** (LGPD: e-mail, telefone, endereço, documento de pessoa
    física);
  - **sigiloso** (custo por hora, dados bancários, limite de crédito, o que
    o histórico já mascara).
  Um campo sigiloso pode ser vigiado ("a conta bancária do fornecedor
  mudou"), mas o valor **nunca** sai no evento, no aviso, no e-mail nem no
  conector: sai "alterado" e um link para quem pode ver. Um dado pessoal
  só vai para um conector externo marcado como autorizado a receber dados
  pessoais, com finalidade declarada; essa autorização exige uma segunda
  pessoa (quatro olhos) e fica na auditoria.
- **D11 — Saída para fora com garantia.** Uma ação de conector usa a fila
  de saída da spec 017, com chave de idempotência (regra + evento): uma nova
  tentativa nunca duplica o aviso no sistema de destino. A ordem dos
  eventos de um mesmo registro é preservada. O conteúdo enviado tem
  tamanho máximo e é assinado com a chave do conector.
- **D12 — Experiência premium.** O histórico de qualquer registro do
  catálogo ganha "Avisar quando mudar", que abre a regra já preenchida com
  entidade, registro e campo. O editor de regras mostra os campos pelo
  rótulo, com a classificação visível (cadeado para sigiloso, ícone para
  pessoal). Antes de ligar, o ensaio roda a regra sobre as mudanças reais
  dos últimos dias ("teria disparado 7 vezes: …"). Na central de automações
  (spec 051) aparecem, por regra, os disparos, os agrupamentos e os casos
  fora do alcance.

## O que a pessoa deixa de fazer (P19)
- Abrir relatórios para descobrir o que mudou em clientes, produtos,
  fornecedores e pedidos.
- Avisar outra área ou outro sistema de uma mudança: o aviso sai sozinho,
  sem duplicar.
- Conferir à mão alterações de risco (dados bancários, limite, preço depois
  de aprovado): viram tarefa de conferência para outra pessoa.
- Sugestão (spec 051, D3): quando alguém consulta repetidamente o histórico
  de um mesmo campo ou registro, o ERP oferece "Avisar quando mudar".

## Requisitos funcionais
- **RF-068-01** Gatilho "alterado" nas regras (D1): entidade, campos,
  de/para, variação mínima, esvaziado/preenchido, origem e registro
  específico.
- **RF-068-02** Catálogo de entidades e campos vigiáveis como dado (D2),
  entregue pelo produto e extensível pelas extensões do cliente, com
  rótulo, tipo, classificação (D10) e classe de volume (D7). As exclusões
  obrigatórias são verificadas por teste.
- **RF-068-03** Cadastros vigiados a partir de `master.change_log`, sem
  escrita adicional por alteração (D4).
- **RF-068-04** Documentos vigiados por campo, com um evento por documento
  e por transação, gravado só quando há regra e o valor mudou (D5).
- **RF-068-05** Alterações em massa: um comando gera os eventos numa única
  gravação, e a regra escolhe entre disparo por registro e agrupado (D6).
- **RF-068-06** Permissões, escopo de dados e classificação aplicados no
  disparo e em toda saída (D9, D10). A autorização de dados pessoais por
  conector passa por quatro olhos.
- **RF-068-07** Saída por conector idempotente, ordenada por registro,
  limitada e assinada (D11).
- **RF-068-08** "Avisar quando mudar" no histórico, editor com
  classificação visível, ensaio sobre mudanças reais e central com
  disparos, agrupamentos e casos fora do alcance (D12).
- **RF-068-09** Sugestão de "Avisar quando mudar" a partir de consultas
  repetidas ao histórico.

## Requisitos não funcionais
- **RNF-068-01 (escrita).** Os valores medidos entram no orçamento
  `priv/disk_budget.json` e são testados por `TestDiskEndurance`:
  - sem regra ativa: zero bytes de WAL a mais por alteração, em cadastros
    e em documentos;
  - cadastro vigiado: zero bytes a mais por alteração (só o avanço do
    ponto processado, por lote);
  - documento vigiado: no máximo uma linha de evento por documento e por
    transação, com o orçamento medido no plan.md;
  - sistema ocioso com regras ativas: nada além do orçamento de ocioso
    da spec 063.
- **RNF-068-02 (desempenho).** Medidos na bateria:
  - uma atualização em lote de 10 mil linhas numa tabela do catálogo, sem
    regra ativa, fica no máximo 3% mais lenta que sem a funcionalidade;
  - com uma regra ativa sobre um campo que muda, fica no máximo 15% mais
    lenta;
  - um evento vira disparo em até 2 segundos no p95, com o sistema em carga
    normal;
  - ligar ou desligar uma regra nunca espera mais que um instante por
    trava na tabela vigiada; se não conseguir, tenta de novo em segundo
    plano e avisa.
- **RNF-068-03 (segurança).**
  - Nenhum SQL é montado a partir de texto digitado: entidade e campo vêm
    só do catálogo, validados no banco, e a instalação da verificação é
    feita por uma função do próprio banco que confere o catálogo.
  - O valor de um campo sigiloso nunca aparece em evento, aviso, e-mail,
    conector, log nem ensaio.
  - Toda regra, toda mudança de regra e toda autorização de dado pessoal
    ficam na auditoria (spec 024).
  - Uma regra não consegue vigiar a própria automação nem disparar a si
    mesma (RNF-051-01).
- **RNF-068-04 (robustez).**
  - Nenhum evento se perde numa queda: o evento é gravado na mesma
    transação da alteração, e o ponto processado só avança depois do
    disparo.
  - Num cluster, o processamento é do nó líder e retoma do ponto processado
    quando o líder troca, sem disparar duas vezes (a idempotência cobre a
    janela da troca).
  - Uma regra com erro não atrasa as demais.

## Critérios de aceite
- **CA-068-01** A regra "quando a conta bancária de um fornecedor mudar,
  criar tarefa de conferência para o grupo Financeiro, exceto para quem
  alterou" dispara na alteração. A tarefa mostra "conta bancária alterada"
  sem o valor, e quem alterou não pode concluí-la.
- **CA-068-02** Alterar 1.000 vezes um campo de cliente que nenhuma regra
  vigia grava o mesmo WAL que antes da funcionalidade (dentro da tolerância
  do orçamento).
- **CA-068-03** Com uma regra sobre o limite de crédito, alterar outro
  campo do cliente não grava evento. Alterar o limite grava, no máximo, o
  orçamento declarado.
- **CA-068-04** A regra "quando a data de entrega do pedido for adiada,
  avisar o cliente pelo conector" dispara uma vez por pedido, mesmo que a
  data seja alterada três vezes na mesma transação. Uma nova tentativa do
  conector não duplica o aviso no destino.
- **CA-068-05** Uma importação de 5.000 clientes que altera o limite de 312
  gera um único aviso agrupado com os 312, e não 312 avisos.
- **CA-068-06** Um vendedor que vê só a própria carteira cria uma regra
  sobre clientes: alterações em clientes de outros vendedores não disparam
  para ele, e o caso aparece como fora do alcance, sem valores.
- **CA-068-07** Uma regra que tenta enviar um campo pessoal por um conector
  não autorizado é recusada ao ser salva, com orientação. Autorizar exige
  uma segunda pessoa, e as duas ficam na auditoria.
- **CA-068-08** Tentar vigiar uma tabela interna ou um campo fora do
  catálogo é recusado pelo banco mesmo por chamada direta à API.
- **CA-068-09** Uma atualização em lote de 10 mil linhas sem regra ativa
  fica dentro dos 3% de RNF-068-02, e com uma regra ativa dentro dos 15%.
- **CA-068-10** Em "Avisar quando mudar" no histórico de um cliente, a
  regra abre preenchida, o ensaio mostra quantas vezes teria disparado nos
  últimos dias, e ligar a regra não trava quem está gravando clientes.
- **CA-068-11** Com o nó líder derrubado no meio de um lote de eventos, o
  outro nó continua do ponto processado, sem perder nem duplicar disparos.
