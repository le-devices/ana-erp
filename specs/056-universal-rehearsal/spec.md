# 056 — Ensaio universal: toda operação pode ser simulada

Situação: implementada (nov/2026); falta T-056-03b (assistente e regras, quando as specs 052 e 051 existirem).

## Problema
A simulação já existe (spec 020: parâmetro `simulate`, execução somente
leitura, botão Simular F9) e é usada em algumas rotinas (atendimento do
pedido, cancelamento, regras de extrato). Para a experiência premium (P18) e
para o assistente (spec 052) ensaiar antes de agir, **toda rotina que grava
precisa poder ser ensaiada**, mostrando o efeito em linguagem de negócio.

## Decisões
- **D1 — Ensaio genérico pelo núcleo.** Qualquer rotina pode ser executada
  em modo ensaio: a transação roda inteira e é desfeita no fim; chamadas
  externas, e-mails e arquivos ficam retidos e são listados ("enviaria este
  e-mail", "chamaria este conector").
- **D2 — Efeito legível.** O ensaio mostra o que mudaria: documentos criados
  ou alterados (com links de visualização, spec 035), movimentos de estoque,
  títulos, lançamentos, tarefas; derivado das mudanças registradas na
  transação, não de código específico de cada rotina.
- **D3 — Em todo lugar.** Botão "Ensaiar" (F9) em todo formulário que grava,
  no assistente, nas regras de automação (spec 051) e nas importações.
- **D4 — Rotinas que declaram efeito próprio** (como o atendimento do pedido)
  continuam podendo mostrar uma explicação mais rica.

## Requisitos funcionais
- **RF-056-01** Modo ensaio genérico com retenção de efeitos externos (D1).
- **RF-056-02** Resumo do efeito a partir das mudanças da transação (D2).
- **RF-056-03** "Ensaiar" em formulários, assistente, regras e importações (D3).
- **RF-056-04** Verificação: rotina que grava sem suporte a ensaio é apontada
  pelo verificador da spec 050.

## Critérios de aceite
- **CA-056-01** Ensaiar uma fatura mostra título, lançamento e e-mail que
  seriam gerados, e nada é gravado nem enviado.
- **CA-056-02** Toda rotina do produto que grava aceita ensaio (teste sobre o
  catálogo).
