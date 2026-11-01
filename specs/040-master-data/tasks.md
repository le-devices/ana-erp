# 040 — Tarefas: dados mestres padronizados

- [x] T-040-01 Migração 038: validadores de CPF/CNPJ no banco, `active` no depósito, campos próprios, histórico por gatilho genérico, pedidos de alteração, mesclagem, índices de trigramas (RF-040-01, 05, 06, 07)
- [x] T-040-02 Núcleo passa execução e origem à sessão do banco (RF-040-06)
- [x] T-040-03 `master.entities` (entidades do produto) e `ana_lib.master.core`: descrever, validar, buscar, ler, salvar pelo escritor com versão, desativar, apagar, duplicados (RF-040-01..05, 07)
- [x] T-040-04 Programas `master.*` e busca única com as buscas atuais delegando (RF-040-04)
- [x] T-040-05 Área Cadastros: lista, ficha com abas, validação no campo, conflito de versão, duplicados, histórico, uso, atalhos (RF-040-02, 03, RNF-040-01)
- [x] T-040-06 Importação e exportação CSV com prévia e confirmação; CSV seguro (RF-040-09, RNF-040-04)
- [x] T-040-07 Aprovação de campos sensíveis (RF-040-08)
- [x] T-040-08 Painel de qualidade e verificação periódica (RF-040-10)
- [x] T-040-09 Cadastros atuais pelo serviço padrão, compatíveis (RF-040-11, CA-040-08)
- [ ] T-040-10b Importação em lote acima de ~20 mil linhas por minuto: hoje cada linha passa pelo programa de gravação da entidade (~18 ms/linha; 1.000 linhas em 18 s), longe da meta de 100 mil em 60 s (RNF-040-03)
- [x] T-040-11b Rotinas antigas de cadastro no menu Operação passam a abrir a ficha padrão — o mapa vem de `master.describe` (`routes`): rotina da entidade abre a ficha (ou "novo"), rotina de aba abre a ficha nessa aba (`?aba=`); `?_rotina=1` mantém o formulário; os programas seguem para a API
