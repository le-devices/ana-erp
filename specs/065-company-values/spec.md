# 065 — Valores da empresa: valores nomeados que as rotinas leem e a empresa mantém

Situação: fase 1 implementada (nov/2026); fase 2 (T-065-07..11) na fila.

## Problema
Toda empresa tem valores de negócio que mudam sem que o código deva mudar:
o período contábil aberto, o depósito principal, a margem mínima para
aprovar sem alçada, a lista de centros de custo de P&D, o limite de horas
extras, o código de serviço padrão da nota, a data de corte do inventário.
Hoje eles acabam:
- **escritos no código** dos programas (mudar exige editar, testar e
  transportar a rotina);
- **repetidos** em parâmetros de agendamentos e variantes (cada um com a sua
  cópia, que envelhece em silêncio);
- **espalhados** em tabelas de configuração de cada módulo, sem histórico,
  sem vigência e sem saber quem usa.

As configurações do sistema (spec 011) são técnicas e da plataforma; os
cadastros (spec 040) são entidades do negócio. Falta o meio-termo: **valores
pequenos, com nome, tipados, com vigência e dono**, que qualquer rotina,
agendamento, variante, regra ou verificação lê pelo nome — e que a empresa
mantém pela tela, com histórico e aprovação, sem tocar em código.

## Decisões
- **D1 — Valor com nome e tipo.** Um valor da empresa tem nome hierárquico
  (`financeiro.periodo_aberto`, `estoque.deposito_principal`), descrição,
  dono (área responsável), tipo e forma:
  - **simples**: texto, número, decimal, data, sim/não, mês (período);
  - **referência a cadastro**: aponta para um registro (centro de custo,
    depósito, parceiro, conta, produto) e é validado contra ele — apagar o
    registro referenciado é impedido enquanto o valor apontar para ele;
  - **lista**: vários valores do mesmo tipo (ex.: centros de custo de P&D);
  - **faixa e seleção**: inclui/exclui valores, intervalos e padrões
    (`de 4000 a 4999`, `exceto 4500`, `começa com 3.1`) — usável como filtro
    em consultas sem montar SQL à mão.
- **D2 — Vigência.** Um valor pode ter várias versões com data de início:
  "a margem mínima é 18 % a partir de 1/1/2027". Quem lê recebe a versão
  vigente na data de referência da operação (por padrão, hoje no fuso da
  empresa); reprocessar um mês antigo lê o valor daquela época. O mesmo
  modelo de vigência do motor de impostos (spec 049).
- **D3 — Por instância e por filial.** Cada valor pode ser diferente em
  desenvolvimento, teste e produção (spec 034: o endereço do banco de teste,
  o e-mail de cópia em homologação) e, quando fizer sentido, por empresa ou
  filial do grupo. A resolução segue do mais específico para o geral.
- **D4 — Valores que se atualizam sozinhos (P19).** Um valor pode ser
  mantido por uma rotina: o fechamento do mês (spec 055) avança
  `financeiro.periodo_aberto`; o inventário grava `estoque.ultimo_inventario`.
  A atualização é uma operação registrada, com quem (a rotina e o usuário
  dono, P14), quando e de quanto para quanto — nunca uma escrita escondida.
  Valores calculados (D5) não precisam ser gravados.
- **D5 — Expressões dinâmicas de lista fechada.** Além de valores fixos,
  um valor pode ser uma expressão resolvida na hora: hoje, ontem, início e
  fim do mês e do ano (atual e anterior), hoje ± N dias, o próximo dia útil
  (calendário da spec 018), o período aberto ± N meses, o usuário atual e o
  centro de custo dele. Lista fechada, nunca código livre — a mesma lista
  das variantes (spec 045, D2) e dos agendamentos, num só lugar (os modelos
  `{{today}}`, `{{last_month_start}}` de hoje passam a ser casos dela).
- **D6 — Leitura em todo lugar, pelo nome.**
  - Programas Python: `ana.value("financeiro.periodo_aberto")`, com a data
    de referência opcional; lista e seleção chegam prontas para usar em
    consulta (`ana.sql(..., ana.value("pd.centros"))` vira `= ANY($1)`).
  - SQL dos programas: função `base.company_value(nome [, data])`, só
    leitura, respeitando a permissão do programa.
  - Variantes (spec 045), agendamentos (spec 018), regras de alerta,
    verificações (spec 029), condições de esteiras e processos (specs 030,
    039) e o motor de impostos (spec 049): referência `{{valor:nome}}`.
  - Telas: um campo pode vir preenchido com um valor da empresa (spec 050,
    valores padrão por contexto).
- **D7 — Rápido e sem escrita na leitura (P15, P20).** Os valores vigentes
  ficam em memória (ETS) em cada nó; uma mudança gravada avisa todos os nós
  por evento (NOTIFY, como as configurações) e a tela de quem está usando
  se atualiza ao vivo (spec 062). Ler um valor nunca escreve nada; não há
  ciclo periódico.
- **D8 — Onde é usado.** O ERP sabe quem lê cada valor: análise dos
  programas (chamadas com nome literal, pelo portão de qualidade da spec
  064), variantes, agendamentos, regras e esteiras que o referenciam, e as
  leituras reais medidas em memória (contadores, sem gravar a cada leitura).
  Antes de mudar ou apagar, a tela mostra o impacto; nome desconhecido num
  programa é apontado no editor.
- **D9 — Governança.** Permissão por área (quem vê, quem altera); valores
  marcados como sensíveis à operação (margem mínima, limite de alçada) pedem
  aprovação de uma segunda pessoa (quatro olhos) e podem exigir motivo; tudo
  vai à trilha de auditoria (spec 024) com antes e depois. **Segredos não são
  valores da empresa**: senha, token e chave vão para o cofre dos conectores
  (spec 017) — o ERP recusa gravar algo que pareça credencial.
- **D10 — Transporte entre ambientes (spec 034).** A definição (nome, tipo,
  descrição, dono, regras) viaja no transporte com as rotinas que a usam; o
  **conteúdo** só viaja quando o valor for marcado "igual em todos os
  ambientes". Importar um transporte que lê um valor inexistente no destino
  avisa antes e oferece criá-lo.

## Requisitos funcionais
- **RF-065-01** Cadastro de valores da empresa (D1): nome, descrição, dono,
  tipo, forma (simples, referência, lista, seleção) com validação por tipo e
  por cadastro referenciado.
- **RF-065-02** Vigência por data com histórico de versões e leitura na data
  de referência (D2).
- **RF-065-03** Variação por instância e por empresa/filial com resolução do
  mais específico para o geral (D3).
- **RF-065-04** Expressões dinâmicas de lista fechada, compartilhadas com
  variantes e agendamentos, com prévia do valor resolvido (D5).
- **RF-065-05** Leitura por programas (`ana.value`), SQL
  (`base.company_value`) e referências `{{valor:nome}}` em variantes,
  agendamentos, regras, verificações, esteiras, processos e impostos (D6).
- **RF-065-06** Cache em memória por nó, propagação por evento e tela ao
  vivo; nenhuma escrita na leitura (D7).
- **RF-065-07** Valores mantidos por rotinas com registro de cada mudança
  (D4); primeiros usuários: período aberto (spec 055) e último inventário.
- **RF-065-08** "Onde é usado" e análise de impacto antes de mudar ou apagar;
  nome desconhecido apontado no editor de programas (D8).
- **RF-065-09** Permissão por área, aprovação de quatro olhos para valores
  sensíveis, auditoria com antes e depois, recusa de credenciais (D9).
- **RF-065-10** Definição no transporte; conteúdo só quando marcado igual em
  todos os ambientes; aviso de valor ausente na importação (D10).
- **RF-065-11** Migração: os modelos de data dos agendamentos passam a ser
  expressões do D5 sem mudar o que já está agendado.

## Requisitos não funcionais
- **RNF-065-01** Ler um valor custa microssegundos (ETS) e não escreve no
  disco; mudar um valor chega a todos os nós em até 1 s.
- **RNF-065-02** O valor lido por uma execução fica no registro dela
  (rastreabilidade: com que margem mínima essa aprovação foi decidida).
- **RNF-065-03** Até 10 mil valores com histórico sem atraso perceptível na
  tela nem na partida do núcleo.
- **RNF-065-04** Um valor nunca amplia permissão: referência a cadastro
  respeita o escopo de dados de quem executa (spec 009).

## Critérios de aceite
- **CA-065-01** Uma rotina lê `financeiro.margem_minima`; o administrador
  muda de 18 % para 20 % com vigência amanhã: hoje a rotina usa 18 %, amanhã
  20 %, e reprocessar ontem continua 18 % — sem editar a rotina.
- **CA-065-02** O fechamento do mês avança `financeiro.periodo_aberto`; as
  variantes "Mês aberto" e os agendamentos que o referenciam passam a usar o
  novo período sem ninguém tocar neles; a mudança aparece na auditoria com a
  rotina e o usuário dono.
- **CA-065-03** `pd.centros_de_custo` (lista) usado num relatório filtra os
  centros listados; incluir um centro na lista muda o relatório na próxima
  execução; apagar o centro de custo referenciado é recusado mostrando quem
  o usa.
- **CA-065-04** O mesmo valor tem conteúdo diferente em teste e produção; um
  transporte leva a definição sem sobrescrever o conteúdo do destino.
- **CA-065-05** Mudar um valor marcado sensível fica pendente até a segunda
  pessoa aprovar; quem pediu não aprova o próprio pedido.
- **CA-065-06** Tentar gravar um valor parecido com credencial é recusado
  apontando o cofre dos conectores.
- **CA-065-07** Num cluster de dois nós, mudar um valor e executar a rotina
  no outro nó em seguida já lê o novo valor (até 1 s).
- **CA-065-08** Um programa que lê um nome inexistente é apontado no editor
  e no portão de qualidade antes de ir para a produção.

## Experiência e automação (P18, P19)
- Tela "Valores da empresa" agrupada por área, com busca, vigência em linha
  do tempo, "onde é usado" e prévia do valor resolvido para hoje.
- No editor de programas, digitar `ana.value("` completa os nomes com tipo e
  valor atual; um número ou data escrito fixo no código que já existe como
  valor da empresa vira sugestão "use o valor da empresa" (spec 064).
- O assistente (spec 052) e a paleta de comandos (spec 050) encontram e
  mudam valores (com a aprovação do D9 quando sensível).
- A implantação guiada (spec 061) pergunta os valores essenciais por perfil
  de negócio e já os grava.
- Valor com vigência futura agendada aparece nos avisos uma semana antes;
  valor que nenhuma rotina lê há 180 dias é sugerido para arquivar.
