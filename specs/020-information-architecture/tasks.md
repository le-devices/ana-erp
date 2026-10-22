# 020 — Tarefas: Arquitetura da informação

- [x] T-020-01 Estrutura de áreas e roteamento por `#/…` (RF-020-01, 07, CA-020-04)
- [x] T-020-02 Início: favoritos, recentes, últimas execuções (RF-020-02, CA-020-05)
- [x] T-020-03 Operação: módulos, rotina com formulário/resultado/histórico (RF-020-03, CA-020-01)
- [x] T-020-04 Desenvolvimento: abas do programa e painel de execução (RF-020-04, CA-020-02)
- [x] T-020-05 Dados: catálogo + console SQL (RF-020-05)
- [x] T-020-06 Administração agrupada e ficha do usuário completa (RF-020-06, CA-020-03)
- [x] T-020-07 Mensagens, teclado e acessibilidade (RF-020-08, 09): auditoria de contraste dos temas (`tests/a11y/contrast.py`, WCAG 2.1), abas com papéis e setas, árvores e linhas pelo teclado, nome acessível em todo campo, atalho para pular ao conteúdo
- [x] T-020-08 Teste de fumaça cobrindo CA-020-01..05
- [x] T-020-09 Próxima ação sugerida (`NEXT` nos programas) (RF-020-10, CA-020-06)
- [x] T-020-10 Fluxos guiados por processo (RF-020-11, CA-020-07): `flows.guide` e o componente de etapas
- [x] T-020-11 Continuidade entre listas e detalhes (RF-020-12): documentos navegáveis (spec 035), parâmetros no endereço, Voltar devolve a posição da tela

## Padrões de telas de produtividade (RF-020-13..18)
- [ ] T-020-12 Componente de barra de tabela com variantes por usuário (colunas, ordem, filtros, exportar) (RF-020-17, CA-020-12)
- [ ] T-020-13 Painéis com divisor e recolher, cabeçalho fixável, estado lembrado (RF-020-18, CA-020-12)
- [ ] T-020-14 Construtor de condições (critérios E/OU, exclusões, ajuda de valores, texto em português) sobre a regra restrita (RF-020-14, CA-020-09)
- [ ] T-020-15 Definição com simulação ao lado: regras do extrato, condições de esteira e escopo de dados (RF-020-13, CA-020-08)
- [ ] T-020-16 Grade de planejamento por período (dimensões fixas, períodos pelo intervalo, edição, colar planilha, totais, lote, salvar só o mudado) (RF-020-15, CA-020-10)
- [ ] T-020-17 Gráfico ligado à grade (planejado × consumido × disponível, negativo em destaque, um eixo) e primeiros usos: orçamento, previsão, alocação de horas (RF-020-16, CA-020-11)

## Organização por áreas e categorias (RF-020-19..23)
- [ ] T-020-18 Áreas do negócio e categorias do produto (`ana:category` nos programas, área pelo namespace; nomes de área para bpm, master e demais) (RF-020-19, CA-020-13)
- [ ] T-020-19 Categorias pessoais e da empresa (visíveis a todos ou a grupos), renomear, reordenar, recolher, excluir (RF-020-20, CA-020-15)
- [ ] T-020-20 Seleção de várias rotinas e "Copiar para categoria…" (atalho; parâmetros pré-preenchidos e nome próprio opcionais) (RF-020-21, CA-020-14, CA-020-17)
- [ ] T-020-21 Favoritos do Início por categoria, arrastar para ordenar e mover; busca do topo acha atalhos; nunca mostra o que não pode usar (RF-020-22, RF-020-23, CA-020-16)
