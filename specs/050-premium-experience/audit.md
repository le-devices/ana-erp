# 050 — Relatório da auditoria de todas as áreas (fase 3) e da auditoria de automação (T-051-06)

Novembro de 2026. Método no plan.md ("Fase 3"). Tudo o que pôde ser verificado virou teste, e esse teste
cobre as telas e os programas que vierem depois.

## 1. Telas: o rastreador

Primeira rodada (25/11/2026): 456 telas alcançáveis, sendo 266 do administrador e 190 do usuário de
operação. Todas as rotinas que só leem foram executadas e a tela de resultado também foi verificada.
Foram encontradas 25 violações, todas corrigidas:

| Área | Tela | Apontamento | Correção |
|------|------|-------------|----------|
| Administração | Alertas | silêncios: lista vazia sem ação; seleção da regra sem nome | "Silenciar uma regra" leva ao formulário; nome acessível |
| Administração | Extensões | lista vazia sem ação | "Ligar um programa seu" |
| Administração | Limites e cotas | lista vazia sem ação | "Criar um perfil"; campos com nome |
| Administração | Monitor | execuções em andamento: vazia sem ação | "Ver as execuções recentes" |
| Administração | Retenção, Parâmetros, Desempenho do SQL | campos sem nome | nomes acessíveis |
| Fiscal | Impostos, Casos de teste, Vigilância fiscal | caixa de JSON para o usuário de operação (rotinas sem `PARAMS`) | `PARAMS = {}`; teste impede rotina sem `PARAMS` |
| Logística e campo | Bancada de campo (resultado) | listas vazias sem ação | "Nova OS"; "Agenda da semana" |
| Projetos | Minha semana, Painel, Portfólio (resultado) | listas vazias sem ação | "Apontar horas"; "Novo projeto" |

Mecanismo novo: `ana.table(…, empty=…, empty_action=…)`. A tabela vazia explica o motivo e oferece
a rotina que a preenche.

Segunda rodada, depois das correções: as mesmas 456 telas, sem nenhuma violação (CA-050-05). O
rastreador roda sem linha de base em `make teste-estudio`.

As telas mais lentas para assentar foram formulários com listas de consulta (pedido de venda, política
de atendimento, requisição de compra, devolução, projeto, bloqueio de crédito): de 10 a 13 s, com o
rastreador limitado a 0,7 CPU num computador compartilhado. Isso precisa ser conferido num navegador
real, pela tela "Desempenho das telas" (orçamento de 1 s no p95, D2), antes de ser tratado como
defeito (T-050-20).

## 2. Programas: regras verificadas sem tela

Situação por área das rotinas do menu:

| Área | Rotinas | Com próximo passo | Desfazer | Confirmação | Padrão pelo contexto |
|------|---------|-------------------|----------|-------------|----------------------|
| Cadastros | 24 | 6 | – | 1 | – |
| Compras | 15 | 7 | – | 1 | – |
| Contabilidade | 11 | 4 | – | – | – |
| Documentos e arquivos | 5 | 3 | – | – | – |
| Estoque | 6 | 2 | – | 1 | 1 |
| Financeiro | 22 | 7 | – | 1 | – |
| Fiscal | 17 | 13 | – | – | – |
| Logística e campo | 20 | 2 | – | 1 | – |
| Processos | 23 | 3 | – | – | – |
| Produção | 18 | 5 | – | 2 | – |
| Projetos | 37 | 6 | – | 2 | – |
| Vendas | 8 | 2 | 1 | 1 | 1 |

Corrigido nesta fase:
- **Ações irreversíveis sem confirmação.** Oito rotinas passaram a dizer a consequência antes de
  executar:
  - cancelar fatura (venda, OS e projeto);
  - cancelar e encerrar ordem de produção;
  - cancelar solicitação ou ordem de compra;
  - apagar cadastro;
  - excluir apontamento.

  O fechamento contábil fica isento: sem parâmetros ele só mostra a situação, e fechar se desfaz
  reabrindo, com motivo. O teste `test_rf_050_05_irreversible_routines_confirm_or_offer_undo` impede
  regressão.
- **Rotinas sem `PARAMS`.** Teste `test_rf_050_02_every_routine_declares_its_params`.

Pendente, medido e sem regressão possível:
- **Próximo passo (D3)** em 108 rotinas que gravam (T-050-17). A lista
  `tests/runtime/next_step_pending.txt` só pode diminuir: rotina nova que grava já nasce com `NEXT`.
  As maiores lacunas, pela ordem do processo, são:
  - Logística e campo: 16 de 16;
  - Projetos: 23 de 27;
  - Processos: 13 de 14;
  - Financeiro: 14 de 19.
- **Desfazer (D5)** existe só no cancelamento do pedido. Candidatos com rotina inversa já pronta:
  cancelar fatura ↔ faturar de novo, bloquear ↔ liberar crédito, ativar ↔ desativar cadastro
  (T-050-18).
- **Valores padrão pelo contexto (D6)** em só dois lugares (pedido de venda e inventário). Candidatos:
  recebimento (fornecedor → depósito e condição), OS (cliente → técnico da região), apontamento de
  horas (último projeto e atividade) (T-050-19).

## 3. Automação (T-051-06)

| Achado | O que mudou |
|--------|-------------|
| As 10 rotinas periódicas do produto (conciliação, busca de extratos, compensação de créditos, liberação de pedidos retidos, apropriação de mão de obra, rateio, faturamento de projetos, reposição de estoque, vigilância fiscal, uso simulado) nascem desligadas, e a empresa precisava saber que existem | Quando o programa de uma delas é executado à mão ao menos 2 vezes em 30 dias, cada administrador recebe a sugestão "Ligar a rotina do produto…", com a explicação; aceitar liga a rotina. A sugestão de agendamento pessoal deixa de concorrer com a rotina do produto |
| O planejamento de necessidades (MRP) era sempre executado à mão | Nova rotina do produto, todo dia útil às 5h, antes da reposição. Ela só propõe: aprovar continua com uma pessoa |
| Cobrança de títulos vencidos: não há lembrete automático ao cliente | Fica para a régua de cobrança (T-051-07), com e-mail (spec 044) e portal |
| Rotinas que gravam sem próximo passo obrigam a pessoa a procurar o que vem depois | T-050-17 (seção 2) |
