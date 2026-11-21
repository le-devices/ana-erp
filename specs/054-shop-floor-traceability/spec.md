# 054 — Chão de fábrica, bancada de testes e rastreabilidade por número de série

Situação: especificada (nov/2026).

## Problema
Empresas de eletrônica e embarcados (o caso do dono do produto) precisam
responder em segundos: "quais clientes receberam placas com o lote X de
capacitores?", "qual firmware e qual resultado de teste tem o número de série
Y?", "a linha parou por quê?". Hoje o ANA tem ordens de produção, estoque com
lote e OS de campo, mas não tem número de série, genealogia nem a coleta
automática dos equipamentos. O núcleo em Erlang aguenta milhares de conexões
simultâneas — base natural para coletar dados de bancadas, máquinas e
dispositivos em tempo real.

## Decisões
- **D1 — Número de série e genealogia.** Item pode exigir número de série;
  cada unidade produzida guarda ordem de produção, lotes e números de série
  dos componentes consumidos, firmware/versão, operador e resultados de
  teste. Expedição, nota, devolução e OS de campo referenciam a unidade.
- **D2 — Coleta automática.** Bancadas, máquinas e dispositivos enviam dados
  por conector (HTTP com assinatura, spec 017; MQTT como fase 2): resultado
  de teste por número de série, apontamento de produção, parada com motivo.
  Mensagens fora de ordem e repetidas são tratadas (idempotência).
- **D3 — Qualidade automática.** Regra por item: teste reprovado bloqueia a
  unidade (não expede), abre não conformidade e avisa; taxa de reprovação
  acima do limite vira alerta (spec 019) e tarefa (spec 051).
- **D4 — Rastreabilidade em segundos.** Consulta para frente (lote do
  componente → unidades → clientes) e para trás (número de série →
  componentes, testes, ordem, operador), com exportação para recall.
- **D5 — Painel do chão de fábrica.** Painel em tempo real (spec 048) por
  linha: produzido, reprovado, paradas e motivo, eficiência; funciona numa
  TV e no celular.

## Requisitos funcionais
- **RF-054-01** Número de série por item, geração e leitura por código de
  barras/QR (spec 050).
- **RF-054-02** Genealogia da unidade (D1) gravada na conclusão da produção.
- **RF-054-03** Coleta por conector com idempotência (D2).
- **RF-054-04** Regras de qualidade e não conformidade (D3).
- **RF-054-05** Consultas de rastreabilidade para frente e para trás (D4).
- **RF-054-06** Painel em tempo real (D5).
- **RF-054-07** Integração com expedição, notas, devoluções, garantia e OS de
  campo pela unidade.

## Requisitos não funcionais
- **RNF-054-01** 1.000 resultados de teste por segundo por nó sem atrasar o
  ERP (fila e lote, P15).
- **RNF-054-02** Consulta de recall de um lote com 100 mil unidades em < 2 s.

## Critérios de aceite
- **CA-054-01** Uma placa reprovada na bancada não pode ser expedida e gera
  não conformidade; aprovada, segue.
- **CA-054-02** A partir de um lote de componente, a consulta lista as
  unidades e os clientes que as receberam.
- **CA-054-03** O mesmo resultado de teste recebido duas vezes não duplica.
