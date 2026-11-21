# Como contribuir com o ANA ERP

Obrigado pelo interesse. O ANA é um ERP com núcleo Erlang/OTP, PostgreSQL e programas de negócio em Python,
aberto sob a [GNU AGPL-3.0](LICENSE) (com a [permissão adicional para os programas do cliente](NOTICE)).

## Antes de começar
- **Specs primeiro.** Todo trabalho começa numa spec em [`specs/`](specs/README.md): problema, decisões,
  requisitos (RF/RNF) e critérios de aceite (CA). Para uma mudança de comportamento, abra uma issue ou proponha a
  spec antes do código; correções pequenas podem ir direto num pull request.
- **Termo de contribuição.** Para que o projeto possa continuar aberto e também oferecer a licença comercial que o
  sustenta, toda contribuição entra sob o [Termo de Licença de Contribuição](CLA.md). No seu primeiro pull
  request, comente: *"Li e aceito o Termo de Licença de Contribuição do ANA ERP, versão 1.0."* A verificação
  automática registra o aceite; sem ele, o pull request não pode ser integrado.
- **Segurança.** Vulnerabilidade não vai em issue pública: veja [SECURITY.md](SECURITY.md).

## Convenções
- Código, nomes de tabelas, colunas, APIs e JSON em **inglês**; telas, mensagens e documentação em
  **português**.
- Nomenclatura própria do ANA: não use termos de outros ERPs (o portão de qualidade aponta os mais comuns).
- Todo arquivo de código novo começa com as linhas SPDX (`scripts/licensing_check.py add-headers` escreve):

      SPDX-FileCopyrightText: 2026 LE Devices
      SPDX-License-Identifier: AGPL-3.0-or-later

- Literais Erlang com acento usam `/utf8`.
- Dependência nova só com licença da lista aceita (`scripts/licensing_check.py`); inclua-a no `NOTICE`.
- Nada de segredo, credencial ou dado pessoal real no repositório, nem em testes; a bateria procura credenciais
  no que o pull request adiciona.

## Fluxo
1. Faça um fork e crie a branch a partir de `dev`: `feature/NNN-assunto` (NNN = número da spec) ou
   `fix/assunto`.
2. Escreva os testes rastreados aos requisitos (`test_rf_NNN_xx_…`, `test_ca_NNN_xx_…`).
3. Rode localmente o que a mudança toca (veja "Testes" no [README](README.md)); `make subir` sobe a pilha.
4. Abra o pull request para `dev`. A bateria escolhe as suítes pelos arquivos mudados; todas precisam passar.
5. Um mantenedor revisa. Integrações em `dev` são sem fast-forward; `qa` e `master` são promovidas pelos
   mantenedores.

## Código de conduta
Participando, você concorda com o [Código de Conduta](CODE_OF_CONDUCT.md).
