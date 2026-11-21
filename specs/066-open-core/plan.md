# 066 — Plano

## Fase 1 — preparar e publicar o repositório (T-066-01..06)

### Licença nos arquivos (T-066-01, T-066-02)
- `LICENSE`: texto integral e sem alteração da GNU AGPL-3.0 (o GitHub reconhece a licença por ele).
- `NOTICE`: direitos autorais, aviso da AGPL, licença comercial, marca, **permissão adicional da seção 7 para os
  programas do cliente** (D1) e os componentes de terceiros com as licenças.
- Linhas SPDX (`SPDX-FileCopyrightText: 2026 LE Devices` e `SPDX-License-Identifier: AGPL-3.0-or-later`) no topo
  de todo arquivo de código, configuração e instalação — 200 arquivos, com a sintaxe de comentário de cada
  linguagem, depois do shebang e do doctype.
- **Sem cabeçalho no arquivo, licenciados pelo `REUSE.toml`** (especificação REUSE 3): os programas do produto
  (um comentário a mais mudaria o código de ~260 programas e ofereceria a toda instalação ~260 "atualizações do
  produto", spec 028), as migrações (nunca editadas depois de aplicadas) e os dados de demonstração; também a
  documentação, os JSON e as chaves de teste, que não aceitam comentário.
- `src/ana.app.src`: `{licenses, ["AGPL-3.0-or-later"]}` (dizia Apache-2.0 por engano) e o endereço do código.

### Documentos da comunidade (T-066-03)
`CONTRIBUTING.md` (specs primeiro, convenções, fluxo de branches, aceite do CLA), `SECURITY.md` (relato privado
pelo GitHub, prazos de 3 e 10 dias úteis, divulgação combinada até 90 dias, escopo, boa-fé), `CODE_OF_CONDUCT.md`
(texto próprio) e `TRADEMARKS.md` (o que pode e o que precisa de autorização com a marca "ANA").

### Termo de contribuição (T-066-04)
- `CLA.md` (versão 1.0): licença ampla ao fornecedor, não cessão; direitos morais preservados; compromisso de
  manter as contribuições do núcleo em AGPL; aceite por pessoa ou empresa.
- `.github/workflows/cla.yml`: em todo pull request e em cada comentário, confere se **todos os autores dos
  commits** (e quem abriu) aceitaram a versão atual; o aceite é o comentário com a frase (em português ou
  inglês), registrado na branch `cla-signatures` (`.github/cla/signatures.json`: usuário, id, versão, pull
  request, link do comentário, data) e vale para os próximos. Mantenedores (admin/maintain) e bots não precisam.
  O resultado é o status `CLA` no último commit do pull request.
- Seguro com `pull_request_target`: o código do pull request nunca é baixado nem executado; só a API do GitHub é
  lida e o texto do comentário só é comparado com a frase.
- Limite: commits com e-mail não ligado a uma conta do GitHub não têm usuário para conferir — quem abre o pull
  request responde por eles.

### Dependências e credenciais na bateria (T-066-05, RNF-066-02)
- `scripts/licensing_check.py` (só biblioteca padrão e git): `headers`, `deps` (cada dependência do `rebar.lock`
  com licença conferida e da lista aceita), `secrets BASE` (chaves privadas, tokens de GitHub/AWS/Slack/Google/IA,
  chaves de pagamento e JWT nas linhas adicionadas desde BASE; a chave de teste de licenças e os valores falsos
  dos testes são conhecidos), `add-headers`.
- `.github/workflows/licensing.yml`: em todo pull request para dev, qa e master — inclusive só de documentação,
  que a bateria pula — roda os três (~20 s).
- `make licencas` faz o mesmo localmente; `tests/runtime/test_licensing.py` testa o verificador.

### Checklist de publicação (T-066-06 — ações do dono do produto)
1. Revisão jurídica do `CLA.md` e da permissão adicional no `NOTICE`; retirar as notas de rascunho dos dois.
2. Integrar a fase 1 em `dev`, `qa` e `master` (o `cla.yml` só vale na branch padrão).
3. No dia: `make licencas` e a varredura do histórico inteiro de novo (21/11/2026: nenhum segredo real).
4. Gerar a chave de produção das assinaturas (`scripts/license.py keygen`) **fora do repositório**, com cópia de
   segurança fora da máquina de desenvolvimento.
5. GitHub → Settings → General → Danger zone → **Change visibility → Public**.
6. Settings → Code security: ativar **Private vulnerability reporting**, **Secret scanning** e **Push
   protection** (gratuitos em repositório público).
7. Settings → Branches (ou Rulesets) para `dev`, `qa` e `master`: exigir pull request; checks obrigatórios
   `plan`, `static`, `Licenças e credenciais` e `CLA`; sem force push nem exclusão.
8. Settings → Actions → General: **exigir aprovação para rodar workflows de contribuidores de primeira viagem**
   (pull requests de fork).
9. Settings → Secrets and variables: conferir que não há segredo que não seja necessário.
10. Perfil da organização no GitHub: e-mail de contato (citado em `CODE_OF_CONDUCT.md` e `TRADEMARKS.md`).
11. Depois de público: tirar da bateria os cuidados com minutos que deixarem de valer (a seleção de suítes continua
    útil para o tempo de espera).
