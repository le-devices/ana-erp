# 015 — Logística e serviços em campo

## Problema
Entregar o que foi vendido, mover estoque entre locais e levar técnicos até o
cliente são problemas de logística. Para serviços, a "entrega" é uma visita:
técnico certo, no horário combinado, com as peças certas, e com o registro do
que foi feito para faturar.

## Histórias
- **H1** Como almoxarife, transfiro itens entre depósitos (com trânsito).
- **H2** Como expedição, separo, embalo e despacho pedidos de venda — total ou
  parcialmente — com transportadora, rastreio, frete e comprovante de entrega.
- **H3** Como comercial, registro devoluções de clientes.
- **H4** Como coordenador de serviços, abro **ordens de serviço** (instalação,
  manutenção, calibração, suporte em campo) para um cliente/local, com
  prioridade e prazo de atendimento (SLA).
- **H5** Como coordenador, agendo técnicos numa agenda visual, vendo conflitos
  e deslocamentos; monto a rota do dia.
- **H6** Como técnico, registro deslocamento, horas, peças usadas (baixa do
  estoque do veículo/maleta), checklist e aceite do cliente.
- **H7** Como financeiro, faturo ordens de serviço concluídas (avulsas ou como
  despesa/horas de projeto, spec 008).
- **H8** Como gestor, acompanho SLA, tempo de resposta e produtividade.

## Requisitos funcionais
- **RF-015-01** Transferência (`logistics.transfer`): origem, destino, itens;
  `draft` → `shipped` (saída da origem para depósito de trânsito) →
  `received` (entrada no destino); divergência registrada.
- **RF-015-02** Expedição (`logistics.shipment`): pedido de venda, linhas e
  quantidades (parcial), volumes, peso, transportadora, rastreio, frete
  (custo e cobrado), datas prevista/real, comprovante; estados `picking` →
  `packed` → `shipped` → `delivered` | `returned`. A baixa de estoque passa a
  ocorrer na expedição quando o parâmetro `stock_out_on = shipment`.
- **RF-015-03** Transportadoras (`logistics.carrier`) e tabela de frete
  simples por região/peso; frete pode ir ao faturamento.
- **RF-015-04** Devolução (`logistics.return`): entrada no estoque (ou
  quarentena), crédito ao cliente, motivo.
- **RF-015-05** Ordem de serviço (`field.service_order`): cliente, local
  (endereço, contato, coordenadas opcionais), serviço (item `service`),
  equipamento/nº de série opcional, prioridade, prazo (SLA calculado por
  contrato/prioridade), projeto opcional; estados `open` → `scheduled` →
  `en_route` → `in_progress` → `done` → `invoiced` | `cancelled`.
- **RF-015-06** Agenda (`field.assignment`): técnico(s), janela, deslocamento
  estimado; impede sobreposição para o mesmo técnico; respeita ausências do
  calendário (spec 014).
- **RF-015-07** Rota do dia por técnico/veículo: paradas ordenadas, horários
  estimados, distância informada; reordenação manual.
- **RF-015-08** Execução: apontamentos de deslocamento e trabalho (horas),
  peças (baixa do depósito do técnico/veículo), checklist configurável por
  serviço, observações, assinatura/aceite (nome, data, hora).
- **RF-015-09** Faturamento: ordem concluída → fatura de serviço (horas ×
  valor do perfil + peças + deslocamento) ou lançamento no projeto ligado.
- **RF-015-10** Indicadores: SLA cumprido %, tempo até atendimento, tempo em
  campo, visitas por técnico, retorno (nova visita em 30 dias).
- **RF-015-11** Programas expostos para app móvel do técnico e para o cliente
  abrir chamados (via API pública, spec 010).

## Requisitos não funcionais
- **RNF-015-01** (integridade) Agenda sem sobreposição garantida no banco
  (restrição de exclusão por técnico e intervalo de tempo).
- **RNF-015-02** (robustez) Execução em campo tolera conexão intermitente:
  programas idempotentes por chave do cliente (spec 010, idempotência).
- **RNF-015-03** (performance) Agenda da semana de 100 técnicos em < 1 s.

## Critérios de aceite
- **CA-015-01** Transferência de 10 unidades: origem −10 ao despachar,
  destino +10 ao receber, trânsito zerado.
- **CA-015-02** Pedido de 10 expedido em 6 + 4: duas expedições, pedido
  totalmente expedido, rastreios distintos.
- **CA-015-03** Agendar o mesmo técnico em janelas sobrepostas é recusado.
- **CA-015-04** OS concluída com 3 h, 2 peças e deslocamento gera fatura com
  as três linhas e baixa as peças do estoque do técnico.
- **CA-015-05** OS de prioridade alta aberta às 9 h com SLA de 4 h aparece
  atrasada às 13 h01 no indicador.
