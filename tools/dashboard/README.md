# Painel de andamento do projeto (ferramenta interna)

Não faz parte do produto: mostra o andamento das specs para quem desenvolve o ANA.
Os números saem do próprio repositório a cada acesso (cache de 20 s; a página se
atualiza a cada minuto):

- `specs/README.md`, `spec.md` (requisitos RF/RNF/CA) e `tasks.md` (tarefas feitas e pendentes);
- histórico do git: quando cada tarefa foi marcada, commits e linhas alteradas por spec
  (pela menção a "Spec NNN", "T-NNN-…" ou `feature/NNN` na mensagem), atividade por semana;
- fila combinada em `scripts/pending-work.prompt.md`;
- testes que citam cada spec (`test_ca_NNN_…`, `test_t_NNN_…`, `t_NNN_…_test()`).

Complexidade = requisitos + 2 × tarefas + linhas alteradas ÷ 400 (P < 40 ≤ M < 90 ≤ G).

- bateria de testes no GitHub Actions e pedidos de merge abertos (`github.py`, cache de 60 s), se houver token.

## Bateria e pedidos de merge (GitHub)

A faixa do GitHub lê a API com um token **só de leitura**, guardado fora do repositório:

1. GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token.
   Resource owner: a organização; Repository access: **só** este repositório; permissões de repositório:
   **Actions: Read-only**, **Pull requests: Read-only** (Metadata: Read-only vem junto). Validade de até 1 ano.
2. Guarde o token num arquivo só seu (sem aparecer na tela nem no histórico do shell):

   ```bash
   mkdir -p ~/.config/ana-dashboard && (umask 077; read -rs -p "token: " T && printf '%s' "$T" > ~/.config/ana-dashboard/github-token); echo
   ```
3. Monte o arquivo no container (comando abaixo). Sem o arquivo, a faixa diz como configurar e o resto
   do painel funciona igual. O token nunca aparece em `/data.json`; o painel só faz GET em api.github.com.

## Rodar na rede local

```bash
docker run -d --name ana-dashboard --restart unless-stopped -p 8099:8099 \
  -v "$PWD":/repo:ro -v ~/.config/ana-dashboard/github-token:/run/secrets/github-token:ro \
  erlang:27 python3 /repo/tools/dashboard/serve.py --repo /repo --port 8099
```

Abra `http://<ip-desta-máquina>:8099/`. Só leitura: responde apenas `/` e `/data.json`.
A porta 8090 fica livre para a suíte de caos.
