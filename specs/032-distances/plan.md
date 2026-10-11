# 032 — Plano técnico

## Dados (migração `032_geo.sql`)
- `latitude`/`longitude` (ambas ou nenhuma) em `base.company`,
  `inventory.warehouse` e `base.party` (+ `address`).
- `base.geo_policy`: fator rodoviário, velocidade média, conector de
  geocodificação.
- Funções `base.distance_km` (haversine, raio médio 6371,0088 km),
  `base.road_km`, `base.travel_minutes`.
- `logistics.freight_rate.max_km` (faixa opcional) e chave única com a faixa.

## Programas
- Biblioteca `base.geo` (origem empresa/depósito, distância entre pontos).
- `base.distance` (`distancia`), `base.customers_by_distance`
  (`clientes_distancia`), `base.geo_settings` (admin), `base.geocode`,
  `inventory.save_warehouse`; `base.save_party` com endereço e coordenadas;
  `sales.lookup` tipo `origins`.
- `field.schedule` calcula distância e deslocamento; `logistics.ship` usa a
  faixa de distância no frete; empresa com coordenadas em Administração.
