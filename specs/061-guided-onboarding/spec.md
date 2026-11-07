# 061 — Implantação guiada

Situação: especificada (nov/2026).

## Problema
A primeira semana decide a venda e a satisfação. Hoje a instalação é simples
(spec 036), mas configurar empresa, impostos, contas, usuários, cadastros e
saldos iniciais exige saber onde fica cada coisa. Um ERP premium se implanta
**guiado**, em horas, e mostra valor no primeiro dia.

## Decisões
- **D1 — Assistente de implantação** em passos com progresso: empresa e dados
  fiscais (busca por CNPJ, spec 043), perfil do negócio (serviços, comércio,
  indústria, P&D — escolhe módulos, políticas e modelos de processo), plano
  de contas e contas padrão, impostos (pacote de regras, spec 049), usuários
  e grupos, e-mail (spec 044), importação de cadastros e saldos iniciais
  (spec 040), conferência final.
- **D2 — Modelos por perfil de negócio.** Políticas (atendimento do pedido,
  crédito, alçadas), esteiras, processos BPM, painéis e variantes prontos
  para o perfil escolhido; tudo editável depois.
- **D3 — Dados de demonstração** com um clique numa instância de testes, para
  treinar sem medo; removíveis.
- **D4 — Saldos iniciais conciliados.** Estoque, clientes, fornecedores e
  bancos entram por importação e já nascem conciliados com a contabilidade
  (P17).
- **D5 — Checklist de prontidão.** O que falta para operar (ex.: "sem conector
  de e-mail: documentos não serão enviados") aparece no painel até ser
  resolvido.

## Requisitos funcionais
- **RF-061-01** Assistente de implantação (D1) retomável.
- **RF-061-02** Modelos por perfil de negócio (D2).
- **RF-061-03** Dados de demonstração na instância de testes (D3).
- **RF-061-04** Saldos iniciais com conciliação (D4).
- **RF-061-05** Checklist de prontidão (D5).

## Critérios de aceite
- **CA-061-01** Uma instalação nova chega a emitir a primeira fatura de
  serviço seguindo só o assistente.
- **CA-061-02** Saldos iniciais importados deixam todas as conciliações em
  zero.
