# 016 — Repositório de arquivos com permissões granulares

## Problema
Empresas de engenharia trocam muitos arquivos com clientes e fornecedores:
layouts de placas, esquemáticos, firmware, códigos entregáveis, relatórios de
ensaio, faturas, contratos. Hoje isso vai por e-mail ou serviços externos, sem
vínculo com o projeto, sem controle de quem baixou o quê e sem versões.

## Histórias
- **H1** Como gestor de projeto, organizo arquivos em pastas por projeto,
  cliente ou assunto, com versões (v1, v2…) e descrição de cada versão.
- **H2** Como gestor, concedo acesso granular: por usuário, grupo, papel ou
  **conta de cliente externo**, em pasta ou arquivo, com níveis `view`,
  `download`, `upload`, `manage`.
- **H3** Como cliente final, entro no portal do ANA e baixo só o que me foi
  liberado (entregáveis do meu projeto, minhas faturas).
- **H4** Como gestor, gero um link de compartilhamento com validade, senha
  opcional e limite de downloads.
- **H5** Como financeiro, faturas e relatórios gerados por programas são
  guardados automaticamente na pasta do cliente/projeto.
- **H6** Como auditor, vejo quem enviou, alterou e baixou cada arquivo.
- **H7** Como desenvolvedor, programas leem e gravam arquivos pela API
  (`ana.files`), sujeitos às mesmas permissões.

## Requisitos funcionais
- **RF-016-01** Pastas hierárquicas (`files.folder`) com herança de
  permissões (pode ser interrompida por pasta); arquivos (`files.file`) com
  versões imutáveis (`files.file_version`): nome, tipo MIME, tamanho, SHA-256,
  autor, data, comentário.
- **RF-016-02** Vínculo de pastas/arquivos a entidades: projeto, parte
  (cliente/fornecedor), fatura, pedido, ordem de serviço — com pasta automática
  por projeto e por cliente (configurável).
- **RF-016-03** Permissões (`files.grant`): sujeito (`user`, `group`, `role`,
  `party` — contas de portal do cliente), recurso (pasta/arquivo), nível
  (`view` < `download` < `upload` < `manage`), validade opcional. Regra:
  maior nível concedido na cadeia de herança; negação explícita prevalece.
- **RF-016-04** Contas de portal externas (`ana_system.app_user` com papel
  `external` ligado a uma parte): só enxergam o repositório e programas
  expostos ao portal; nunca o Estúdio.
- **RF-016-05** Links de compartilhamento: token aleatório, validade, senha
  opcional (hash), limite de downloads, revogável; registro de cada uso.
- **RF-016-06** Upload em partes (retomável) para arquivos grandes; limite de
  tamanho por arquivo e cota por pasta/cliente (parâmetros).
- **RF-016-07** Verificação de conteúdo: tipo real (assinatura do arquivo) ×
  extensão; lista de extensões permitidas/bloqueadas; gancho para antivírus
  externo (arquivo fica `quarantine` até liberado).
- **RF-016-08** Busca por nome, tag, vínculo e período; visualização de PDF e
  imagens no navegador; download de pasta como ZIP (respeitando permissões).
- **RF-016-09** API para programas: `ana.files.put(path, data, ...)`,
  `ana.files.get(path)`, `ana.files.list(folder)`, `ana.files.grant(...)` —
  executadas com as permissões do usuário da execução.
- **RF-016-10** Auditoria de upload, nova versão, download, concessão,
  revogação e uso de link.

## Requisitos não funcionais
- **RNF-016-01** (segurança) Downloads só por URL assinada de curta duração
  (5 min) emitida após checar permissão; conteúdo servido com
  `Content-Disposition: attachment` e `X-Content-Type-Options: nosniff`; sem
  execução de conteúdo no domínio do ERP.
- **RNF-016-02** (segurança) Armazenamento cifrado em repouso (chave do
  ambiente) e deduplicado por SHA-256; nomes de arquivo nunca usados como
  caminho no disco.
- **RNF-016-03** (robustez) Gravação atômica (conteúdo primeiro, metadados na
  transação); verificação periódica de integridade (hash).
- **RNF-016-04** (performance) Conteúdo fora do banco transacional (sistema de
  arquivos ou armazenamento compatível com S3), metadados no PostgreSQL;
  downloads em streaming com suporte a `Range`.

## Critérios de aceite
- **CA-016-01** Cliente externo com `download` na pasta do seu projeto baixa
  o entregável e não vê a pasta de outro cliente (404).
- **CA-016-02** Nova versão de um arquivo preserva a anterior, baixável.
- **CA-016-03** Link com validade de 1 h e 2 downloads: terceiro download e
  acesso após 1 h são recusados.
- **CA-016-04** Arquivo `.exe` renomeado para `.pdf` é recusado (tipo real).
- **CA-016-05** Fatura de serviço gerada vira PDF na pasta do cliente e o
  cliente a baixa pelo portal.
- **CA-016-06** Toda operação aparece na auditoria do arquivo.
