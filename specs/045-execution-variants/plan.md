# 045 — Plano: variantes de execução

## Modelo (T-045-01)
Migração `068_run_variants.sql`:
- `run_variant`: rotina, nome, dono (`NULL` = da empresa), publicada, padrão da empresa, campos (`entries`),
  travados, ocultos, situação (válida ou inválida, com o motivo), versão e a versão anterior (variantes da
  empresa, RF-045-02). Nome único por rotina e dono, sem diferenciar maiúsculas; até 200 por rotina.
- `run_variant_default`: a padrão de cada usuário por rotina (D4); sem ela, a padrão da empresa.
- `access_group.variant_patterns`: rotinas (ou `prefixo.*`) cujas variantes da empresa os membros publicam;
  administradores sempre.
- `execution.variant` e `scheduler.job.variant_id` (RF-045-06).

## Valores dinâmicos (T-045-02)
Cada campo guarda um destes: `{"value": x}`, `{"expr": "last_month_start"}` (a lista fechada da spec 065, a
mesma do agendador e dos valores da empresa, com deslocamento onde a lista permite) ou
`{"company_value": "financeiro.periodo_aberto"}`. São resolvidos na hora de cada execução, no fuso da empresa
e para o usuário que executa.

## Travados e ocultos (T-045-03)
Oculto implica travado. Na execução, o núcleo resolve a variante e junta os valores informados **só nos campos
livres**; um valor informado para um campo travado que difira do da variante é recusado (`VARIANT_LOCKED`) — na
tela, na API e no agendamento. A execução tem só as permissões de quem executa (RNF-045-01); o programa valida
os parâmetros como sempre.

## Tela (T-045-04)
Na barra de filtros da rotina: escolher a variante (pessoais e da empresa, a padrão com ★, inválidas com o
motivo), "Salvar como variante…" (cada campo: não guardar, este valor, uma expressão da lista com
deslocamento, ou um valor da empresa; travar; ocultar), alterar, excluir, usar como minha padrão, publicar,
despublicar, tornar a padrão da empresa e restaurar a versão anterior. A padrão vem aplicada ao abrir a rotina
sem parâmetros; o endereço leva `_variant` (atalhos, favoritos, voltar). Simular e Ensaiar valem com a variante.

## Em todo lugar (T-045-05)
`POST /api/programs/:nome/run` aceita `variant` (id ou nome) e devolve a variante usada com avisos; o
agendamento guarda a variante e a resolve no dia de cada execução (os parâmetros do agendamento só preenchem
campos livres). A execução registra id, nome, versão e avisos.

## Programa mudou (T-045-06)
Ao salvar um programa, atualizar o produto ou importar um transporte, as variantes dele são conferidas: campo
que deixou de existir é ignorado com aviso; tipo que não serve mais marca a variante inválida com o motivo (e ela
não executa). A mesma conferência acontece em cada execução.

## Fora desta entrega
Paleta de comandos (spec 050 fase 2, CA-045-05) e blocos do painel (spec 048) abrindo a rotina com a variante;
sugestão de "Salvar como variante" após três usos iguais (spec 051): T-045-07b.
