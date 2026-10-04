# 005 — Estúdio (ambiente de desenvolvimento embutido)

## Problema
Desenvolver, executar e depurar programas deve acontecer dentro do próprio
ERP, pelo navegador, sem instalar nada.

## Histórias
- **H1** Como desenvolvedor, quero navegar pelos programas em árvore por
  namespace, abrir, editar com realce de sintaxe e salvar com comentário.
- **H2** Quero executar com parâmetros e ver saída, tabelas e resultado.
- **H3** Quero depurar: clicar na margem para pontos de parada, ver linha
  atual destacada, variáveis, pilha, e um console de avaliação.
- **H4** Quero ver histórico de versões e restaurar.
- **H5** Quero consultar o Catálogo (tabelas, colunas, tipos, comentários) e
  rodar SQL somente-leitura.
- **H6** Como usuário, quero digitar um Comando curto e abrir o programa
  correspondente com formulário de parâmetros.
- **H7** Quero ver as últimas execuções e seus detalhes.

## Requisitos funcionais
- **RF-005-01** `GET /` serve o Estúdio (HTML/CSS/JS estáticos de `priv/www`).
- **RF-005-02** Editor com numeração de linhas, realce de sintaxe Python,
  indentação com Tab (4 espaços), atalho `Ctrl+S` salvar, `F5` executar,
  `F9` alternar ponto de parada na linha do cursor, `F10` passo, `F11` entrar,
  `Shift+F11` sair, `F8` continuar.
- **RF-005-03** Painéis: Saída, Resultado, Variáveis, Pilha, Console de
  avaliação, Versões, Execuções.
- **RF-005-04** Catálogo: `GET /api/catalog` (esquemas e tabelas de negócio)
  e `GET /api/catalog/:schema/:table` (colunas, tipos, nulidade,
  comentários, índices, contagem estimada).
- **RF-005-05** Console SQL: `POST /api/sql` — somente leitura, papel
  `ana_read`, máximo 1000 linhas, timeout 10 s.
- **RF-005-06** Comandos: tabela `ana_system.comando(codigo, programa,
  descricao)`; `GET /api/commands`; barra de comando abre o programa; se o
  usuário não for `developer`, abre só o formulário de execução gerado de
  `PARAMS`.
- **RF-005-07** Formulário de parâmetros gerado de `PARAMS`; também é
  possível informar JSON livre.
- **RF-005-08** Ao salvar, erros de sintaxe são reportados com linha
  (o programa é salvo mesmo assim, marcado com aviso).

## Requisitos não funcionais
- **RNF-005-01** (segurança) Zero dependências externas (CDN): CSP
  `default-src 'self'` sem `unsafe-inline` para scripts.
- **RNF-005-02** (segurança) Token em `sessionStorage` (não em cookie → sem
  CSRF); todo conteúdo dinâmico inserido via `textContent` (sem XSS).
- **RNF-005-03** (performance) Estúdio < 100 KiB sem compressão; arquivos
  estáticos com `Cache-Control` e ETag.
- **RNF-005-04** Funciona em largura de 1280 px e se adapta a telas menores.

## Critérios de aceite
- **CA-005-01** Criar programa, salvar, executar e ver resultado sem sair da
  página.
- **CA-005-02** Clicar na margem da linha 3, depurar: linha 3 destacada,
  variáveis visíveis; F10 avança.
- **CA-005-03** Console SQL rejeita `DELETE` (transação somente leitura).
- **CA-005-04** Digitar o Comando `balance` abre `inventory.balance` com formulário.
