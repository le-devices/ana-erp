# 057 — Central de suporte e parceiros

Situação: especificada (nov/2026).

## Problema
O ANA é licenciado para muitos clientes, atendidos pelo fornecedor ou por
parceiros (revendas, consultorias). Suporte caro é o que mais corrói a margem
de um produto assim. Com diagnósticos (spec 046) e depuração por reexecução
(spec 047), dá para resolver a maioria dos casos **sem acessar a máquina do
cliente**.

## Decisões
- **D1 — Chamado de dentro do ERP.** "Pedir ajuda" em qualquer tela abre um
  chamado com contexto anexado automaticamente: tela, rotina, execução,
  versão, erro e pilha (mascarados), últimos passos do usuário — sem dados
  de negócio além do necessário, com consentimento.
- **D2 — Pacote de diagnóstico.** O administrador gera um pacote assinado e
  mascarado (inventário, configuração sem segredos, agregados de
  diagnóstico, grupos de erro, saúde) para enviar ao suporte; o suporte o
  abre numa instância própria e reproduz.
- **D3 — Acesso de suporte controlado.** Quando preciso, o acesso do suporte
  é um acesso emergencial (spec 047): pedido, aprovado pelo cliente, com
  prazo, registro e relatório.
- **D4 — Parceiros.** Cadastro de parceiro responsável pela instalação, com
  painel das instalações que atende (saúde, versão, licença a vencer,
  chamados) — só com telemetria autorizada pelo cliente (spec 009).

## Requisitos funcionais
- **RF-057-01** Chamado com contexto automático e consentimento (D1).
- **RF-057-02** Pacote de diagnóstico assinado e mascarado (D2).
- **RF-057-03** Acesso de suporte via acesso emergencial (D3).
- **RF-057-04** Painel do parceiro com instalações atendidas (D4).

## Critérios de aceite
- **CA-057-01** "Pedir ajuda" numa tela com erro gera chamado com a execução
  e a pilha mascarada, sem segredos.
- **CA-057-02** O pacote de diagnóstico não contém senha, segredo ou dado
  pessoal (teste de varredura).
