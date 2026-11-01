# 042 — Vistoria das trilhas de processos de negócio

Situação: vistoria feita (31/10/2026); fases 1 (A-01..A-04, M-01, M-02), 2 (B-01..B-05, E-01..E-03) e 3 (suíte permanente `make teste-trilhas`) concluídas.

## Como foi feita
Cada trilha foi percorrida de ponta a ponta com dados novos, pelos programas reais (a mesma API das
telas), na instância de desenvolvimento. Em cada passo: o documento seguinte nasce e leva ao anterior?
As conciliações de controle (clientes, fornecedores, créditos, estoque, em processo, bancos) ficam iguais
antes e depois da trilha? O razão fecha? A esteira termina sem ninguém conciliar à mão?

Trilhas percorridas: venda completa (pedido → expedição → entrega → fatura → PIX no extrato → baixa);
cancelamento de fatura e devolução de cliente; compra (solicitação → aprovação → ordem → dois recebimentos
→ pagamento pelo extrato → devolução ao fornecedor); produção (estrutura → OP → liberação → requisição →
apontamento → entrega → encerramento → venda do produzido); serviço em campo (OS → agendamento → viagem →
trabalho → peça → aceite → fatura → pagamento); projeto (plano → alocação → horas → aprovação → despesa
refaturável → fatura → pagamento); atendimento sob encomenda (spec 041: pedido → compra vinculada →
recebimento → liberação → expedição → fatura); estoque (perda, inventário, transferência); esteiras de
compra, campo e produção com etapas automáticas; documentos de cada tipo e suas ligações; razão geral.

## O que está sólido
- Venda, devolução, compra manual, produção, serviço em campo, projeto e atendimento sob encomenda: nenhuma
  conciliação de controle se moveu, o razão fecha, todo lançamento está balanceado, e o PIX/TED no extrato
  com o número do documento baixou o título sozinho em todas as trilhas.
- Esteira de produção: liberou, requisitou, esperou a fabricação e encerrou sozinha após a entrega.
- Esteira de serviço em campo (com agendamento manual): após o aceite, faturou, cobrou, esperou o pagamento
  e fechou sozinha quando o extrato chegou.
- Spec 041: o recebimento da compra vinculada liberou o pedido, que expediu e faturou.

## Achados

### Alto
- **A-01 Recebimento automático sem mercadoria.** Na esteira de compra, com "Recebimento" automático, o
  robô dá entrada no estoque (e gera o título a pagar) assim que a ordem é emitida — sem a mercadoria
  existir. Receber é um fato físico: a etapa deveria só aguardar (como "Fabricação" na produção) ou
  receber pelo aviso do fornecedor/nota (spec 017), nunca por si.
- **A-02 Aprovação de compra de valor zero passa por qualquer alçada.** Solicitação de item sem preço de
  catálogo vale R$ 0,00; "0 acima do limite 0" é falso e o robô (alçada zero) aprovou. Uma solicitação sem
  valor estimado deveria exigir valor ou aprovação humana.
- **A-03 Etapa automática que nunca funciona.** Esteira de serviço em campo com "Agendamento" automático:
  falha sempre ("parâmetro obrigatório ausente: technician"). A configuração permite um modo impossível.
  Propostas: escolher o técnico pela agenda/região (spec 015) ou não oferecer "automática" nessa etapa.
- **A-04 Recusa de alçada vira falha, não espera.** Com preço, a aprovação automática pelo robô é recusada
  pela alçada e a esteira marca **falha**; o certo é aguardar um aprovador humano (com o motivo), como as
  etapas manuais.

### Médio
- **M-01 Diferença sem explicação.** A conciliação de fornecedores tem −R$ 20,00 acumulados na base de
  desenvolvimento e o detalhe da conciliação não lista nada que a explique. O detalhe deveria mostrar
  também os lançamentos na conta de controle sem título correspondente (isso revela a origem).
- **M-02 Documentos que não levam de volta à origem.** O título a pagar de um recebimento (`OC-856/944`),
  a fatura de projeto (`INV-1524`), o crédito de devolução (`DEVF-…`) e as baixas (`EXT-…`, `COMP-…`) não
  abrem o documento de origem — os padrões de `docs.common` só reconhecem `OC-n`, `ORD-n`, `OS-n`…

### Baixo (usabilidade e robustez)
- **B-01** Lançar trabalho na OS exige o técnico mesmo quando a OS já tem um técnico agendado.
- **B-02** Inventário com coluna errada nas linhas termina em `EXCEPTION: KeyError` em vez de dizer o que
  falta.
- **B-03** Registrar nota do fornecedor quando a empresa gera o título no recebimento responde "não há
  recebimento esperando nota" — deveria dizer que a política é "título no recebimento".
- **B-04** Recusa por margem mostra "margem projetada —%" quando ainda não há receita prevista.
- **B-05** "projeto … está proposal": a situação aparece com o código interno, não em português.

## Correções da fase 1 (31/10/2026)
- A-01/A-03: etapa de esteira declara se pode ser automática (`flow.step.auto_allowed`, migração 052);
  "Recebimento" (compra) e "Agendamento" (OS) só por uma pessoa — a configuração recusa com o motivo
  (`STEP_NOT_AUTOMATIC`) e o banco impede (restrição).
- A-02: alçada zero não aprova nada, nem solicitação sem valor (`NO_APPROVAL_LIMIT`).
- A-04: recusa que pede uma pessoa (alçada, auto-aprovação) deixa a etapa aguardando com o motivo, não em falha.
- M-01: o detalhe das conciliações de clientes/fornecedores lista os títulos baixados sem baixa registrada.
  Os −R$ 20,00 da base de dev vêm do título `OC-423/445`, baixado em 17/10 por uma versão antiga de teste
  que editava o título (o teste atual paga pelo extrato): resíduo histórico, agora visível.
- M-02: títulos, créditos, resíduos, notas, devoluções e baixas levam à origem (`docs.common`); o título mostra
  "Como foi baixado" (extrato, compensação, cobrança, resíduo); novas visões "Fatura de projeto" e "Linha do
  extrato"; lançamento de compensação abre os dois títulos; a fatura de projeto em PDF traz os itens.

## Correções da fase 2 (31/10/2026)
- B-01: trabalho e peça na OS vão para o técnico informado, o usuário técnico ou o único técnico agendado.
- B-02: o runtime confere as linhas de toda lista com colunas declaradas (objeto, colunas obrigatórias, tipos) e
  diz linha e coluna — nenhum programa recebe linha mal formada (vale para todos, não só o inventário).
- B-03: com "título no recebimento", a nota do fornecedor responde `BILL_AT_RECEIPT` explicando a política.
- B-04: sem receita prevista, a recusa por margem diz o que falta em vez de "—%".
- B-05: situações em português nas mensagens (`util.format.status_text`), em todos os programas que diziam
  "está OPEN/INVOICED/done/proposal…".

Achados pela bateria durante a fase 2 (corrigidos):
- **E-01 Importação lenta com acúmulo.** Cada importação de extrato conciliava a conta inteira; com 200 mil
  linhas em aberto (massa de testes), estourava o tempo do banco. Agora concilia só as linhas que trouxe, e um
  título só é baixado sozinho se nenhuma outra linha em aberto também for candidata única a ele (mesma decisão
  da conciliação completa, consultada só para os títulos em jogo). A conciliação manual completa continua igual.
  Também (E-01b): a busca do identificador da cobrança no texto das linhas comparava cada cobrança com cada
  linha (55 s com 200 mil linhas); agora usa índice de trigramas só sobre as linhas em aberto e só cobranças que
  ainda podem casar (8 ms). A etapa "Recebimento" da esteira concilia só as linhas que querem os títulos do
  documento; a conciliação completa devolve no máximo as sugestões das 500 linhas mais recentes (10 por linha).
  O teste de importação de 100 mil linhas limpa suas linhas sempre (antes, só quando passava — era a origem do
  acúmulo de 200 mil linhas na conta CAIXA da instância de desenvolvimento).
- **E-01c Repasses do gateway e listas grandes.** O casamento de repasses comparava cada linha de entrada com as
  somas das cobranças pagas pendentes (83 s com 100 mil linhas e 59 cobranças): agora só olha as linhas cujo valor
  é alguma soma possível. Filtros por uma lista grande de linhas (`id = ANY(lista)` dentro de um "ou") viraram
  semijunções (`id IN (SELECT unnest(lista))`). Importar e conciliar 100 mil linhas: 2,5 s de conciliação.
- **E-03 Execução longa perdia a resposta.** O servidor HTTP fechava a conexão após 60 s sem tráfego, embora um
  programa possa rodar até o teto de execução (10 min). O tempo ocioso agora acompanha o teto (+30 s), e o ingress
  do Kubernetes no pacote de produção espera 630 s.
- **E-04 Totais calculados sobre listas cortadas.** O relatório de crédito lia no máximo 500 clientes e tirava
  dessa amostra a contagem de bloqueados e o total em atraso (com mais de 500 clientes com pendência, os números
  ficavam errados e um bloqueado podia faltar na lista). Corrigido (31/10/2026): os números vêm do conjunto inteiro
  e só a tabela mostra os 500 primeiros, dizendo quantos há. Verificadas as demais (mesmo padrão, achado
  por varredura) e corrigidas as que mostravam totais: SLA do serviço em campo (% cumprido, atrasadas, tempo de
  resposta, horas, retornos), "Pedidos com falta", clientes por distância, simulação das regras do extrato e
  quarentena — números sobre o conjunto inteiro, tabela dizendo quantos há. A **folha de contagem do inventário**
  listava só 2.000 itens (o depósito de desenvolvimento tem 8.056 com saldo: três quartos ficariam fora da
  contagem); agora lista até 30.000 e avisa acima disso. "Minhas faturas" só lista (as 200 mais recentes): sem
  correção.
- **E-05 Nó que não subia no cluster.** Dois nós iniciando juntos alteravam os mesmos papéis do banco ao mesmo
  tempo ("tuple concurrently updated") e o perdedor encerrava a aplicação — a falha intermitente da suíte de cluster.
  Corrigido (31/10/2026): a configuração de papéis e a sincronização do papel restrito rodam sob uma trava
  consultiva de inicialização, um nó por vez (as migrações já tinham a sua).
- **E-02 Avisos repetidos.** Um achado que vai e volta criava o mesmo aviso a cada volta; os 100 mais recentes
  escondiam um aviso crítico antigo (senha de fábrica). Agora não se cria aviso igual a um não lido, a lista
  mostra cada mensagem uma vez e marcar como lido vale para as cópias.

## Suíte permanente (fase 3, 31/10/2026)
`tests/trails/test_trails.py` (`make teste-trilhas`, na bateria `make testes`): venda, devolução, compra,
produção, serviço em campo, projeto, atendimento sob encomenda, estoque e as esteiras de compra, campo e
produção. Cada trilha exige as conciliações de controle iguais antes e depois, nenhum lançamento
desbalanceado e os efeitos esperados (título baixado pelo extrato, esteira concluída, documento que leva à
origem). Na primeira execução a suíte pegou uma regressão da fase 2: duas colunas declaradas obrigatórias que
os programas preenchiam sozinhos (valor do crédito na devolução de cliente, quantidade recebida na
transferência) passaram a ser exigidas — as declarações foram corrigidas (opcionais, com o padrão no rótulo).

## Proposta
Corrigir A-01..A-04 e M-01..M-02 numa fase; B-01..B-05 noutra (pequenas). Transformar o roteiro da vistoria
em suíte permanente (`make teste-trilhas`): cada trilha com as conciliações antes/depois, para que uma
regressão em qualquer processo apareça na bateria.
