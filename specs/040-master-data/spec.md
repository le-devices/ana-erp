# 040 — Dados mestres: cadastro e manutenção padronizados em todo o ERP

## Problema
O dono do produto exige **uma maneira padronizada, que garanta consistência
em todo o ERP**, para cadastrar e manter os dados mestres do negócio.

Hoje cada cadastro é um programa `save_*` com regras próprias (auditoria de
outubro/2026):

| Cadastro | Chave | Desativar | Validação comum | Registro de alteração | Retorno |
|---|---|---|---|---|---|
| `base.save_party` | `id` | não | sim | log | `{id, created}` |
| `base.save_product` | `code` | não | sim | não | `{id, code, created}` |
| `finance.save_cost_center` | `code` | sim | não | não | `{code, created}` |
| `logistics.save_carrier` | `name` | sim | não | não | `{id, default}` |
| `inventory.save_warehouse` | `code` | não | sim | não | `{id, code}` |
| `projects.save_employee` | `id` | sim | não | não | `{id, created}` |
| `finance.save_bank_account` | `code` | sim | não | não | `{code}` |

Problemas encontrados:
- Não há tela única de consulta e edição. O usuário precisa saber o nome do
  programa, e o formulário de alteração é o mesmo de criação, sem mostrar os
  valores atuais.
- Clientes e itens não podem ser desativados.
- Não há histórico campo a campo (quem mudou o quê, de quanto para quanto).
- Validações são desiguais: não há dígito verificador de CPF/CNPJ nem CEP, e
  duplicidade só é barrada pelo CNPJ (cliente sem CNPJ se duplica pelo nome).
- O item está espalhado em quatro telas: cadastro, plano de produção,
  fornecimento e reposição. O cliente também: cadastro, crédito, condição de
  pagamento e coordenadas.
- Há três buscas de itens diferentes (`sales.lookup`, `supply.lookup` e
  `production.lookup`), cada uma com filtros e textos próprios.
- Não há importação em lote validada, só SQL ou programa avulso; não há
  aprovação para campos sensíveis (dados bancários, limite de crédito,
  preço); e não há indicador de qualidade dos cadastros (incompletos,
  duplicados, inativos em uso).

## Princípio
**Um cadastro se descreve, não se programa.** Cada entidade mestre é
declarada uma vez: campos, tipos, validações, chave, unicidade, busca,
abas, campos sensíveis e ganchos de negócio. O ERP gera a partir disso a
lista, a ficha, a busca (lookup), a importação, a exportação, o histórico e
os indicadores de qualidade, iguais para todas as entidades. As regras
específicas de cada negócio vivem em ganchos pequenos, não em telas
próprias.

## Histórias
- **H1** Em Cadastros, encontro qualquer cadastro (clientes, fornecedores,
  itens, depósitos, centros de custo, contas bancárias, transportadoras,
  colaboradores, técnicos, recursos, condições de pagamento…) com a mesma
  lista: busca, filtros, colunas, ordenação e exportação.
- **H2** Abro a ficha: vejo os valores atuais organizados em abas (o item
  com Geral, Compras, Produção, Estoque e Custos), edito só o que muda e
  salvo. Os erros aparecem ao lado do campo, em português.
- **H3** Ao criar, o ERP avisa de possível duplicado antes de salvar
  (mesmo CNPJ, nome parecido, mesmo e-mail) e me leva ao existente.
- **H4** Desativo em vez de apagar. O inativo some das buscas de uso, mas
  continua nos documentos antigos e nos relatórios. Apagar só é possível
  quando o registro nunca foi usado.
- **H5** Vejo o histórico campo a campo de qualquer cadastro: quem, quando,
  valor anterior e novo.
- **H6** Alterar um campo sensível (dados bancários, limite de crédito,
  preço, alíquota) pode exigir aprovação de outra pessoa (quatro olhos). A
  alteração fica pendente até aprovar.
- **H7** Importo uma planilha (CSV) de clientes ou itens. O ERP mostra uma
  prévia linha a linha (novo, altera, erro com o motivo), e eu confirmo só
  as linhas válidas, numa única transação.
- **H8** Painel de qualidade dos cadastros: incompletos (sem CNPJ, sem
  coordenadas, sem custo padrão), possíveis duplicados, inativos ainda em
  uso e cadastros sem movimento há muito tempo, cada indicador com a ação
  que corrige.

## Requisitos funcionais
- **RF-040-01** Registro de entidades mestres (biblioteca do produto
  `master.entities`, atualizável pela spec 028). Cada entidade declara:
  - nome e rótulo;
  - tabela principal e tabelas filhas, como abas (ex.: item →
    `production.item_plan`, `supply.supplier_item`,
    `supply.replenishment_rule`);
  - chave de negócio e campos;
  - tipos e validadores, entre eles CPF/CNPJ com dígito verificador, CEP,
    e-mail, telefone, UF, coordenadas, moeda, percentual, código e
    referência a outra entidade;
  - obrigatoriedade e valores padrão;
  - unicidade e regras de possível duplicado;
  - colunas de lista e de busca;
  - campos sensíveis e política de aprovação;
  - ganchos de negócio (antes e depois de salvar, e "pode desativar?").

  O produto traz as entidades do produto (P13). O cliente pode acrescentar
  campos próprios, definidos como dados e guardados em coluna jsonb validada,
  sem mudar o banco.
- **RF-040-02** Lista padrão:
  - busca por texto (prefixo e trigramas), filtros por campo, ordenação,
    paginação por cursor;
  - seleção de colunas lembrada por usuário;
  - exportação CSV;
  - ações em lote: desativar, reativar e alterar um campo em vários
    registros, com prévia.
- **RF-040-03** Ficha padrão:
  - mostra os valores atuais, com abas pelas tabelas filhas;
  - salva só o que mudou, com controle de versão otimista: se alguém mudou o
    registro depois que a ficha foi aberta, mostra a diferença e não
    sobrescreve;
  - validação no campo, antes de enviar, e no banco.
  - Atalhos para os documentos que usam o cadastro: pedidos do cliente,
    movimentos do item…
- **RF-040-04** Busca padrão única por entidade: uma só busca de itens, de
  clientes etc. Ela é usada por todos os campos de escolha do ERP, com o
  mesmo texto, a mesma ordem e o mesmo filtro de ativos. As buscas atuais
  passam a delegar a ela, com compatibilidade.
- **RF-040-05** Desativar e apagar:
  - `active` em todas as entidades;
  - documentos novos recusam cadastro inativo; documentos antigos seguem
    válidos;
  - apagar só quando nenhum documento referencia o registro (verificado
    pelas chaves estrangeiras).
- **RF-040-06** Histórico: um gatilho genérico grava cada alteração campo a
  campo (`master.change_log`: entidade, chave, campo, antes, depois, quem,
  quando, origem — tela, importação, API ou programa). Retenção pela
  spec 024; campos secretos aparecem mascarados.
- **RF-040-07** Duplicados: na criação e na importação, as regras da
  entidade apontam candidatos (chave igual, nome com similaridade por
  trigramas acima do limite, mesmo e-mail ou telefone). A pessoa escolhe
  entre usar o existente e criar mesmo assim, com motivo. Há também uma
  ação de **mesclar** dois cadastros, que move as referências e desativa o
  duplicado, numa transação e com trilha.
- **RF-040-08** Aprovação de campos sensíveis: a alteração vira pedido
  pendente (antes/depois) e é aplicada só quando outra pessoa com o papel
  definido aprova. Avisos por notificação. Usa as tarefas humanas do BPM
  quando a spec 039 estiver disponível.
- **RF-040-09** Importação e exportação: CSV (UTF-8, separador `;` ou `,`)
  com mapeamento de colunas lembrado por entidade, prévia linha a linha,
  ensaio, confirmação em uma transação e relatório de erros para baixar.
  Exportação no mesmo formato, para editar e reimportar.
- **RF-040-10** Painel de qualidade: indicadores por entidade, regras
  declaradas no registro e ação que corrige em cada indicador. A
  verificação periódica (spec 033, integridade) avisa quando a qualidade
  piora.
- **RF-040-11** Migração dos cadastros atuais:
  - os programas `save_*` passam a ser chamadas finas ao serviço padrão,
    com os mesmos parâmetros e o mesmo retorno (compatibilidade com
    integrações);
  - as telas antigas levam à ficha padrão.

## Requisitos não funcionais
- **RNF-040-01 Usabilidade:**
  - Todas as entidades têm a mesma lista, a mesma ficha e os mesmos atalhos
    de teclado (novo, salvar, buscar, voltar).
  - Uma pessoa que aprendeu um cadastro sabe usar todos.
  - Mensagens dizem como corrigir.
  - A ficha abre em menos de 300 ms; a busca responde enquanto se digita.
- **RNF-040-02 Consistência:** a validação mora no servidor (Python) e no
  banco (CHECK e unicidade). A tela só antecipa. Nenhum caminho, nem a API
  nem a importação, contorna as regras.
- **RNF-040-03 Desempenho:**
  - busca com índice de trigramas em menos de 50 ms com 1 milhão de
    clientes;
  - importação de 100 mil linhas em menos de 60 s, em lote.
- **RNF-040-04 Segurança:**
  - permissão por entidade e por ação (ver, criar, alterar, desativar,
    aprovar);
  - campos sensíveis exigem permissão própria para ver;
  - CSV sem fórmulas (células que começam com `=`, `+`, `-` ou `@` são
    neutralizadas na exportação).
- **RNF-040-05 Rastreabilidade:** o histórico e as aprovações entram na
  trilha (spec 024).

## Critérios de aceite
- **CA-040-01** Clientes, itens, depósitos e centros de custo abrem na
  mesma lista e na mesma ficha. Editar o item mostra as abas de compras,
  produção e estoque com os valores atuais.
- **CA-040-02** CNPJ com dígito errado é recusado no campo, na API e na
  importação, com a mesma mensagem.
- **CA-040-03** Criar um cliente com nome muito parecido com outro avisa do
  possível duplicado. Mesclar move pedidos e títulos para o que fica e
  desativa o outro.
- **CA-040-04** Desativar um item tira-o da busca do pedido, mas o pedido
  antigo continua abrindo. Apagar um item já usado é recusado com o motivo.
- **CA-040-05** Alterar o preço registra antes e depois no histórico. Com a
  aprovação ligada, o preço só muda depois que outra pessoa aprova.
- **CA-040-06** Importar 1.000 clientes com 3 linhas inválidas mostra as 3
  na prévia; confirmar grava as 997 válidas numa transação; reimportar o
  mesmo arquivo não cria duplicados.
- **CA-040-07** Duas pessoas editam o mesmo cliente: a segunda a salvar vê
  a diferença e não sobrescreve sem querer.
- **CA-040-08** As integrações que chamam `base.save_party` e
  `base.save_product` continuam funcionando com o mesmo retorno.

## Fases
1. **Serviço e registro:** registro das entidades, validadores, ficha e
   lista padrão, desativação, histórico e busca única (RF-01 a RF-06).
2. **Duplicados e mesclagem, importação e exportação** (RF-07, RF-09).
3. **Aprovação de campos sensíveis e painel de qualidade** (RF-08, RF-10).
4. **Migração** de todos os cadastros atuais e das buscas (RF-11).

## Situação (implementação, outubro/2026)
Implementada, com duas pendências (T-040-10b e T-040-11b).

Onze entidades do produto estão registradas: clientes e fornecedores, itens,
depósitos, centros de custo, contas bancárias, condições de pagamento,
transportadoras, colaboradores, perfis profissionais, técnicos de campo e
recursos de produção.

Decisões tomadas:
- **Registro na biblioteca.** As definições ficam na biblioteca do produto
  `master.entities`, e não numa tabela. Melhorias chegam pela atualização do
  produto (spec 028); campos próprios do cliente ficam em
  `master.custom_field`.
- **Escritores reaproveitados.** A gravação passa pelos programas `save_*`
  existentes, que já têm as regras de negócio testadas, com a mesma resposta
  de antes. O serviço padrão acrescenta validação, duplicados, versão,
  aprovação e histórico.
- **Documento no banco.** CPF/CNPJ é conferido (dígito verificador) e
  formatado pelo banco quando muda, por qualquer caminho. Registros antigos
  inválidos continuam editáveis enquanto o documento não mudar.
- **Histórico por gatilho genérico.** Uma linha por alteração, com os campos
  mudados no formato antes → depois, quem, origem e execução. Custo por hora
  do colaborador aparece mascarado no histórico.
- **Mesclagem no serviço,** com a autorização do contexto. Uma referência que
  não pode mudar (por exemplo, a conta de portal do parceiro) bloqueia a
  mesclagem dizendo onde; a contagem usa `master.reference_count`.
- **Depósito inativo é recusado em documentos novos:** pedido, compra,
  produção, entrada de estoque e despesa de projeto.
- **Importação:** prévia em cerca de 0,1 s por mil linhas; gravação em cerca
  de 18 ms por linha (T-040-10b).
