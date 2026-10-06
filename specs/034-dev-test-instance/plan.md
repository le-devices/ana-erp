# 034 — Plano técnico

## Instância
- `ANA_INSTANCE` = `production` (padrão quando ausente) | `test` |
  `development`; o `docker-compose.yml` de desenvolvimento usa
  `development`. `GET /api/me` e `/health` informam a instância; a barra
  superior mostra uma faixa "DESENVOLVIMENTO" / "TESTES" (cor própria) fora
  da produção.
- Parâmetro `transport_required` (0/1, padrão 0): na produção, com 1, salvar
  programa pelo Estúdio é recusado (`TRANSPORT_REQUIRED`); só a importação
  de pacote grava.

## Pacote de transporte (migração `030_transports.sql`)
- `ana_system.transport` (id, direção `out`|`in`, título, descrição, autor,
  origem, estado `draft`|`exported`|`received`|`imported`|`refused`|
  `reverted`, manifesto jsonb, hash do manifesto, verificação prévia jsonb,
  recebido/importado/desfeito por e quando).
- `ana_system.transport_item` (transporte, tipo `program`|`command`|
  `setting`, nome, hash novo, hash base, versão anterior no destino, versão
  criada, existia antes?).
- `ana_system.transport_origin` (nome, chave pública Ed25519, ativa, quem
  cadastrou) — o destino só aceita pacotes de origens cadastradas.
- Chave da instância: par Ed25519 gerado na primeira exportação; a privada
  fica no cofre (spec 017, cifrada pela chave mestra); a pública aparece na
  tela para ser cadastrada no destino.
- Arquivo: `{"format": "ana-transport/1", "origin", "manifest_b64",
  "signature"}` — a assinatura cobre os bytes exatos do manifesto.
- Manifesto: título, autor, instância e versão do produto de origem, data,
  itens (programa: nome, tipo, fonte, propriedades, sha256, sha256 base;
  comando; parâmetro) e os testes declarados.
- Hash base de um programa: o da última versão que veio de fora da instância
  de origem (semente, transporte ou cópia); conflito no destino = versão
  atual diferente da base e da nova.

## Importação
- Recebimento: confere formato, origem cadastrada, assinatura, hash de cada
  item, versão do produto (mesma versão maior) e roda a verificação prévia
  (conflitos, programas que o pacote chama e não existem no destino,
  achados de lint) → estado `received`.
- Importar: quatro olhos opcional (`transport_four_eyes`, padrão 0: quem
  recebeu não importa); conflitos só com a lista explícita de aceites;
  inspeção (Python) fora da transação, gravação de todos os itens numa
  transação única, versões novas com comentário "transporte #n"; cache
  trocado nos nós por notificação (P16) — execuções em andamento terminam
  na versão que começaram.
- Desfazer: numa transação, cada programa volta à versão anterior (nova
  versão com a fonte antiga) ou é desativado se não existia; comandos e
  parâmetros voltam ao valor anterior.

## Cópia de dados produção → testes
- Exportar (produção, admin): esquemas de negócio (`base`, `sales`,
  `inventory`, `finance`, `projects`, `supply`, `production`, `logistics`,
  `field`), tabela a tabela em lotes (cursor), **mascarando na origem**:
  dado pessoal nunca sai sem máscara. Arquivo JSON-lines comprimido e
  cifrado (AES-256-GCM, chave aleatória mostrada uma vez ao administrador).
- Máscara determinística por chave da cópia (HMAC): nome → "Pessoa <h>" /
  "Empresa <h>", e-mail → `<h>@exemplo.test`, telefone, documento (mesmo
  tamanho e formato), endereço, coordenadas (deslocamento fixo por
  registro), textos livres de observação; catálogo por padrão de nome de
  coluna e ajustes por instalação (`ana_system.mask_rule`, inclusive
  `keep`). Tabelas do sistema, cofre, integrações, arquivos e senhas nunca
  entram.
- Importar (só `test`/`development`; produção recusa): em uma transação,
  esvazia os esquemas de negócio, carrega cada tabela por ordem de
  dependência (uma instrução por tabela a partir de tabela temporária —
  autorreferências resolvidas), acerta as sequências, confere contagens e
  totais com o manifesto; depois desliga os conectores e liga
  `outbound_blocked` (nada sai da instância de testes).

## Testes
- eunit: assinatura e verificação, conflito, máscaras determinísticas.
- Integração: CA-034-01..06 (a mesma instância faz o papel de origem e de
  destino: origem cadastrada com a própria chave; a importação de dados
  roda porque o ambiente é `development`).
