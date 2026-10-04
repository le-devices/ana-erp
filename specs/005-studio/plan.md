# 005 — Plano técnico: Estúdio

## Arquivos (`priv/www`)
| Arquivo | Conteúdo |
|---------|----------|
| `index.html` | estrutura; nenhum script inline |
| `studio.css` | tema claro/escuro (`prefers-color-scheme`) |
| `editor.js` | editor próprio: `<textarea>` transparente sobre `<pre>` com realce; margem com números e pontos de parada; destaque da linha em pausa |
| `highlight.js` | tokenizador Python mínimo (palavras-chave, strings, números, comentários, decoradores, builtins) |
| `api.js` | cliente da API (fetch + Bearer), long polling de eventos |
| `studio.js` | telas: login, árvore, abas de painéis, catálogo, SQL, comandos |

## Editor
- Camadas sincronizadas: `pre.realce` (HTML gerado com escape) + `textarea`
  (texto transparente, cursor visível) + `div.margem`.
- Rolagem sincronizada; realce recalculado em `requestAnimationFrame`.
- Pontos de parada mantidos em `Set` de linhas; enviados ao executar e via
  comando `pontos` durante pausa.

## Catálogo
Consultas a `information_schema`/`pg_catalog` restritas aos esquemas de
negócio (`base`, `inventory`, `sales`, `finance`, `projects`, `analytics`).

## Estáticos
Handler próprio `ana_http_static`: lista branca de arquivos, ETag = hash
do conteúdo carregado na partida (em memória — performance), `Cache-Control:
no-cache` (revalida por ETag).
