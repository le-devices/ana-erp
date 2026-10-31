# 042 — Vistoria das trilhas de processos de negócio

Situação: vistoria feita (31/10/2026); fase 1 (A-01..A-04, M-01, M-02) corrigida; B-01..B-05 e a suíte permanente a fazer.

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

## Proposta
Corrigir A-01..A-04 e M-01..M-02 numa fase; B-01..B-05 noutra (pequenas). Transformar o roteiro da vistoria
em suíte permanente (`make teste-trilhas`): cada trilha com as conciliações antes/depois, para que uma
regressão em qualquer processo apareça na bateria.
