# 016 — Plano técnico

Princípios: o conteúdo fica fora do banco, cifrado e endereçado pelo
SHA-256 (deduplicado); o nome do arquivo nunca vira caminho no disco; toda
permissão é decidida no núcleo por uma única função SQL; o cliente externo
começa sem acesso a nada além do que lhe foi concedido.

## Dados (migração `023_file_repository.sql`, esquema `files`)
- `blob` (`sha256` PK, tamanho, IV, MAC, criado em): conteúdo único.
- `folder` (hierarquia, `inherit` para interromper a herança, vínculo
  opcional `entity_kind`/`entity_id`: `project`, `party`; cota opcional).
- `file` (pasta, nome único na pasta, versão atual, etiquetas, situação
  `active`/`quarantine`/`deleted`) e `file_version` (imutável: número,
  `blob`, nome, MIME detectado, tamanho, autor, comentário).
- `grant` (sujeito `user`/`group`/`role`/`party`, recurso pasta ou arquivo,
  nível `view` < `download` < `upload` < `manage`, `deny`, validade).
- `share_link` (hash do token, versão ou arquivo, validade, hash da senha,
  limite e contagem de downloads, revogado) e `upload` (envio retomável).
- `event` (auditoria: ação, recurso, usuário, IP, detalhe).
- `ana_system.app_user`: papel `external` e `party_id` (conta de portal);
  `ana_system.program.portal` (programa liberado ao portal).
- Função `files.level(usuário, papel, recurso)` — SECURITY DEFINER, maior
  nível na cadeia de herança (para quando `inherit = false`), negação
  explícita vence; administrador e desenvolvedor = `manage`; donos da
  pasta (quem criou) = `manage`.

## Armazenamento (`ana_files_store`)
- Diretório `ANA_FILES_DIR` (padrão `/var/lib/ana/files`, volume
  compartilhado entre os nós); caminho `aa/bb/<sha256>`.
- Cifra AES-256-CTR com chave derivada da `ANA_MASTER_KEY`
  (HMAC-SHA256 "ana-files-enc-v1") e IV aleatório por blob; MAC
  HMAC-SHA256 de IV ‖ texto cifrado (cifra-então-autentica) verificado na
  gravação, no download completo e na verificação periódica. CTR permite
  servir `Range` sem decifrar o arquivo inteiro.
- Gravação: arquivo temporário cifrado → hash do conteúdo → se o blob já
  existe, descarta; senão renomeia (atômico) → metadados na transação.

## Núcleo
- `ana_files`: pastas, envio (único e em partes, retomável por
  deslocamento), nova versão, concessões, links, busca, ZIP de pasta (até
  100 MB), auditoria; checagem de tipo real (assinatura × extensão; lista de
  bloqueadas em parâmetro).
- Rotas `/api/files/...` (usuários e externos com permissão; 404 para o que
  não pode ver), `/files/d/<token>` (URL assinada de 5 min, `attachment`,
  `nosniff`, `Range`), `/share/<token>` (link público com senha opcional).
- Execução: operações `files.*` no protocolo, com as permissões do usuário
  da execução (gravação imediata, como `ana.remote`).
- Integridade: verificação diária de uma amostra de blobs (nó líder).

## Programas
- `ana.files.put/get/list/grant/folder`.
- `util.pdf` (gerador de PDF simples, sem dependências) e
  `projects.invoice_project` guardando a fatura em PDF na pasta do cliente,
  com acesso de download para a conta do cliente.
- `files.my_invoices` (portal): faturas do cliente da conta externa.

## Telas
- Operação → **Arquivos**: navegação por pastas, envio (arrastar), versões,
  concessões, links, auditoria do arquivo, visualização de PDF/imagem.
- Conta externa: o Estúdio mostra só o **Portal** (arquivos liberados e
  programas de portal).

## Fica para depois (tarefas abertas)
Armazenamento compatível com S3; gancho de antivírus (quarentena).
