# 060 — Aplicativo no celular (aprovações, campo, estoque)

Situação: especificada (nov/2026).

## Problema
Aprovar uma compra, registrar uma OS no cliente, conferir um recebimento ou
contar estoque são tarefas de quem está longe do computador. O Estúdio já é
utilizável no celular (spec 020), mas falta uma experiência **feita para o
celular**: instalável, rápida, com câmera e notificações.

## Decisões
- **D1 — Aplicativo web instalável (PWA)**, do mesmo servidor, sem loja de
  aplicativos: ícone na tela inicial, abre em tela cheia, atualiza sozinho.
- **D2 — Telas próprias para tarefas de celular:** minhas tarefas e
  aprovações (BPM, spec 039), OS de campo (spec 015) com foto e assinatura,
  recebimento e contagem de estoque com leitura de código de barras/QR
  (spec 050), consulta de cliente e de pedido, painel (spec 048).
- **D3 — Notificações** no celular para tarefas e alertas (com permissão do
  usuário).
- **D4 — Sem conexão por momentos:** contagem e OS gravam no aparelho e
  enviam quando a conexão volta (fila idempotente); o resto exige conexão.

## Requisitos funcionais
- **RF-060-01** PWA instalável e seguro (sessão, bloqueio por inatividade).
- **RF-060-02** Telas de celular (D2).
- **RF-060-03** Notificações (D3).
- **RF-060-04** Fila local para contagem e OS (D4), sem duplicar.

## Critérios de aceite
- **CA-060-01** Aprovar uma solicitação de compra pelo celular em até 3 toques
  a partir da notificação.
- **CA-060-02** Contagem feita sem conexão é enviada ao voltar, sem duplicar.
