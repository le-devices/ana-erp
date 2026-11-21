# 032 — Geolocalização e distâncias aproximadas

## Problema
Para frete, roteiro de técnicos e prazos, é útil saber a distância entre a
empresa (ou um depósito) e o cliente sem depender de serviço externo.

## Requisitos funcionais
- **RF-032-01** Coordenadas (latitude/longitude) na empresa, nos depósitos e
  nas partes (clientes/fornecedores, endereço de entrega/atendimento).
- **RF-032-02** Distância em linha reta (fórmula de haversine, no banco) e
  aproximação rodoviária = reta × fator configurável (padrão 1,3); tempo
  estimado por velocidade média configurável.
- **RF-032-03** Uso: OS e rota (distância/deslocamento estimados), frete por
  faixa de distância (tabela opcional), relatório de clientes por distância.
- **RF-032-04** Geocodificação opcional por conector (spec 017) para
  preencher coordenadas a partir do endereço; nada é enviado sem conector.

## Critérios de aceite
- **CA-032-01** São Paulo (−23,5505, −46,6333) → Campinas (−22,9056,
  −47,0608): reta ≈ 84 km (±1 km); rodoviária ≈ 109 km com fator 1,3.
- **CA-032-02** OS de cliente com coordenadas mostra distância e
  deslocamento estimados ao agendar.

## Decisões
- Coordenadas na empresa, nos depósitos e no cliente (com endereço, usado
  pela geocodificação); a OS já tinha as suas e prevalece sobre as do cliente.
- Distância rodoviária é **aproximada** (reta × fator, padrão 1,3) — sem
  serviço externo; tempo pela velocidade média (padrão 50 km/h).
- Agendamento da OS sai da base do técnico (depósito do veículo, senão a
  empresa) e preenche distância e deslocamento quando não informados.
- Frete por faixa de distância é opcional na tabela da transportadora; a
  faixa de peso pode se repetir com distâncias diferentes.
- Geocodificação só com conector escolhido pelo administrador (contrato
  `/search?q=…&format=json` dos geocodificadores comuns).
