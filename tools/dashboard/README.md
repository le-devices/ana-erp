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

## Rodar na rede local

```bash
docker run -d --name ana-dashboard --restart unless-stopped -p 8099:8099 \
  -v "$PWD":/repo:ro erlang:27 python3 /repo/tools/dashboard/serve.py --repo /repo --port 8099
```

Abra `http://<ip-desta-máquina>:8099/`. Só leitura: responde apenas `/` e `/data.json`.
A porta 8090 fica livre para a suíte de caos.
