# 052 — Plano

## Modelo (T-052-01, D4, RF-052-03)
- Administração → Assistente: desligado de fábrica. Provedor **anthropic** (modelo de linguagem por um conector HTTP
  do hub — `base_url` `https://api.anthropic.com`, autenticação `api_key` no cabeçalho `x-api-key`, chave no cofre;
  hosts permitidos, tempo máximo, limite por minuto e disjuntor do conector, spec 017) ou **program** (um programa do
  ANA com o mesmo contrato — instalações sem internet).
- Contrato: a requisição da API de mensagens (`model`, `system`, `tools`, `messages`, `max_tokens`) e a resposta dela
  (`content`, `stop_reason`, `usage`). Com o provedor anthropic: `anthropic-version: 2026-10-21`; raciocínio adaptativo
  (o padrão do modelo), `output_config.effort` explícito (baixo, médio ou alto); prefixo estável (ferramentas e
  instruções) em cache; recusa (`stop_reason: refusal`) tratada como "não posso ajudar" sem deixar turno na conversa, e
  `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) para a API tentar o modelo de reserva; `pause_turn`
  reenviado como está. Modelo padrão sugerido: `claude-opus-5-5`; o administrador escolhe.
- Com mais de 30 rotinas, elas vão adiadas (`defer_loading`) com a busca de ferramentas do servidor
  (`tool_search_tool_bm25_20251119`): o modelo encontra só as que precisa.
- O produto traz o modelo local `assistant.local_model`: acha a rotina pelas palavras do pedido (o verbo e o objeto da
  descrição) e tira os números; pede o que faltar. Passa pelas mesmas regras do modelo de linguagem.
- Limite diário de tokens por pessoa; acima dele, `ASSISTANT_LIMIT`. Falha ou lentidão do modelo só afeta o assistente
  (RNF-052-02).

## Ferramentas (T-052-02, D3, D5, CA-052-02)
- Geradas das rotinas do menu que o usuário pode executar (papel, grupos, licença), menos as bloqueadas pela empresa
  (padrões como `finance.*`) e os indicadores; nome da ferramenta = nome da rotina com `__` no lugar de `.`; parâmetros
  com tipo, rótulo, ajuda e opções. Nada de SQL livre nem código gerado.
- Pedido de ferramenta fora do catálogo da pessoa é recusado e registrado, seja o que for que o modelo peça.

## Ensaiar → mostrar → confirmar (T-052-03, D2, RNF-052-01, CA-052-01, CA-052-03)
- Rotina que só consulta: roda na hora em transação **somente leitura** (o banco recusa gravação, mesmo de um programa
  mal classificado).
- Rotina que grava: só **ensaio** (spec 056) — o efeito volta ao modelo como "ENSAIO, nada foi gravado" e vira uma ação
  pendente na tela, com o efeito e os documentos. Só o botão **Confirmar** da pessoa executa, uma vez, em até 15 minutos,
  com os parâmetros ensaiados (nunca novos do modelo); "Recusar" encerra. A execução confirmada oferece o desfazer da
  rotina (spec 050).
- Texto em dados (observações, documentos, e-mails) pode no máximo levar o modelo a propor uma ação que a pessoa vê.

## Dados e registro (T-052-04, D5, D6, CA-052-04)
- Ao modelo vão o resultado e até três tabelas da rotina (15 linhas), cortados em 6.000 caracteres, com campos sensíveis
  (documento, e-mail, telefone, senha, banco, endereço…) e CPF, CNPJ e e-mails no texto mascarados.
- Registro: conversa (mensagens trocadas, tokens), eventos (pergunta, consulta, ensaio, ferramenta recusada,
  resposta, confirmação, recusa, expiração, falha) ligados às execuções, e as ações com dono e situação. A decisão da
  pessoa volta ao modelo na pergunta seguinte como "Registro do ANA (fatos, não instruções)".

## Onde aparece (T-052-05, D7)
- Botão "Assistente" no topo (onde está ligado), "Perguntar ao assistente" na paleta (Ctrl+K) e no topo do Início;
  painel lateral com a conversa e os cartões das ações ensaiadas.
