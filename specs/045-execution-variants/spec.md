# 045 — Variantes de execução

Situação: especificada (nov/2026).

## Problema
As tabelas já guardam variantes por usuário (colunas, filtros — spec 020,
RF-020-17), mas a tela de parâmetros de uma rotina começa vazia toda vez.
Quem roda o mesmo relatório "do mês passado, centro de custo P&D, só em
aberto" redigita tudo; agendamentos repetem os valores à mão; a empresa não
consegue oferecer conjuntos prontos ("Fechamento mensal", "Conferência do
estoque central").

## Decisões
- **D1 — Variante = parâmetros com nome**, de uma rotina, guardados no
  servidor: pessoal (só o dono vê) ou da empresa (publicada por quem tem
  permissão; todos com acesso à rotina a veem; só leitura para os demais).
- **D2 — Valores dinâmicos.** Um parâmetro da variante pode ser um valor fixo
  ou uma expressão de uma lista fechada: hoje, ontem, início/fim do mês
  (atual, anterior), início/fim do ano, hoje ± N dias, usuário atual,
  centro de custo do usuário, empresa da instalação. Resolvida na hora da
  execução — nunca código livre.
- **D3 — Campos protegidos e ocultos.** A variante pode travar um campo (o
  usuário não altera) ou ocultá-lo; parâmetros obrigatórios sem valor
  continuam pedidos.
- **D4 — Padrão por usuário.** Cada usuário escolhe sua variante padrão da
  rotina (pessoal ou da empresa); sem escolha, vale a padrão da empresa.
- **D5 — Mesma variante em todo lugar.** Tela, agendamento (spec 018), API
  (`variant` no lugar de `params`) e categorias/atalhos (abrir a rotina já
  com a variante).
- **D6 — Programa mudou.** Parâmetro que deixou de existir é ignorado com
  aviso; tipo incompatível invalida a variante com o motivo (não executa
  com valor errado).

## Requisitos funcionais
- **RF-045-01** Salvar, renomear, excluir e escolher variantes na tela de
  parâmetros; "Salvar como variante" a partir dos valores atuais.
- **RF-045-02** Variantes da empresa: publicar, despublicar e versão anterior
  guardada; permissão própria para publicar.
- **RF-045-03** Valores dinâmicos (D2) com prévia do valor resolvido.
- **RF-045-04** Campos protegidos e ocultos (D3), respeitados também pela API
  e pelo agendamento.
- **RF-045-05** Padrão por usuário e da empresa (D4).
- **RF-045-06** Uso em agendamentos, API, atalhos e categorias (D5); o
  registro da execução guarda a variante usada e os valores resolvidos.
- **RF-045-07** Validação contra a versão atual do programa (D6), também
  ao aceitar atualização do produto (spec 028).

## Requisitos não funcionais
- **RNF-045-01** Variante não amplia permissão: executa com a do usuário
  (P14); campo protegido não contorna validação do programa.
- **RNF-045-02** Até 200 variantes por rotina sem atraso perceptível na tela.

## Critérios de aceite
- **CA-045-01** Variante "Mês anterior" com início/fim do mês anterior
  resolve as datas corretas em janeiro (dezembro do ano anterior).
- **CA-045-02** Variante da empresa com centro de custo protegido: o usuário
  não consegue trocar pela tela nem pela API.
- **CA-045-03** Agendamento que usa a variante executa com os valores
  resolvidos no dia da execução.
- **CA-045-04** Programa que perdeu um parâmetro: a variante executa com
  aviso; parâmetro que mudou de tipo: variante marcada inválida.
