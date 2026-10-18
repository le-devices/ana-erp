# 009 — Licenciamento e distribuição

Situação: decisões tomadas (out/2026, recomendações aceitas pelo dono do
produto). Fase 1 (licença, módulos, limites, expiração, versão, ambientes,
camadas de programas) implementada; fases 2 e 3 especificadas abaixo.
Pendente do fornecedor: gerar a chave de produção (`scripts/license.py
keygen`) e publicar a parte pública em `priv/license/keys.json`.

## Problema
O ANA é vendido a vários clientes. Cada um precisa de seus dados isolados,
dos módulos que contratou, de atualizações do produto sem perder as próprias
customizações — e o fornecedor precisa controlar o que foi licenciado, sem
nunca sequestrar os dados do cliente.

## Decisões

### D1 — Implantação: uma instância por cliente
Banco próprio por cliente, em nuvem gerenciada ou local (spec 036). Várias
empresas (filiais, CNPJs) do mesmo cliente ficam na mesma instância
(`base.company`). Multi-inquilino no mesmo banco está descartado (risco de
vazamento entre clientes e customização em Python por cliente).

### D2 — Licença: arquivo assinado, sem internet
- Texto assinado pelo fornecedor com **Ed25519**, no formato
  `-----BEGIN ANA LICENSE-----` / conteúdo `base64url(JSON).base64url(assinatura)` /
  `-----END ANA LICENSE-----`. A assinatura cobre o JSON codificado.
- Conteúdo: identificador, cliente, emissão, validade (início e fim),
  versão máxima do produto, módulos, limites, ambiente
  (`production` | `non_production`) e a chave que assinou (`kid`).
- Verificada na partida, ao instalar e de hora em hora (todas as instâncias
  do cluster leem a mesma licença no banco). Funciona em rede isolada.
- Instalação: pelo administrador (Administração → Licença, colando o texto)
  ou pelo arquivo indicado em `ANA_LICENSE_FILE` (instalações sem tela; o
  arquivo mais recente vale).
- Chaves confiáveis: `priv/license/keys.json` (`kid` → chave pública). A
  chave privada de produção fica **fora do repositório**, com o fornecedor,
  e a ferramenta `scripts/license.py` gera o par e emite licenças.
- Uma chave de **teste** (privada em `tests/`, usada pela suíte) também é
  confiável, mas a licença assinada por ela é sempre tratada como **não
  produção**, com faixa permanente na tela — um vazamento nunca vira licença
  de produção.
- Licenciamento offline é dissuasão, não cofre: quem controla o servidor pode
  alterar o software. A proteção real é o contrato e o canal de
  atualizações; por isso o ANA registra tudo (auditoria) e nunca bloqueia a
  leitura dos dados.

### D3 — O que se licencia
- **Usuários nomeados**: usuários humanos internos ativos. Não contam
  usuários robô, contas do portal (clientes e fornecedores) nem clientes da
  API pública. No limite, criar ou reativar usuário interno é recusado
  (`LICENSE_LIMIT`); nada que já funciona para.
- Empresas (CNPJs) e robôs não são limitados.

### D4 — Módulos
- **Núcleo, sempre incluído**: plataforma, Estúdio, cadastros e dados
  mestres, financeiro (títulos, extrato, conciliações, contabilidade),
  estoque básico, documentos, arquivos, agendamento, esteiras, integrações e
  todos os programas do próprio cliente.
- **Contratáveis**: vendas (`sales.*`), suprimentos (`supply.*`), produção
  (`production.*`), logística e campo (`logistics.*`, `field.*`), projetos
  (`projects.*`), BPM (`bpm.*`), analítico (`analytics.*` e o painel
  analítico), API pública (chamadas de clientes da API) e portal (contas
  externas).
- Programa de módulo não contratado não executa (`NOT_LICENSED`, dizendo o
  módulo); as tabelas continuam legíveis. Integração automática que passa
  por módulo não contratado: o modelo de processo avisa na publicação, e o
  caso para com o motivo legível — nunca uma falha muda no meio.

### D5 — Expiração
- **Faltando 30 dias**: aviso aos administradores (faixa na tela).
- **Vencida há até 15 dias (carência)**: tudo funciona, com faixa de alerta.
- **Depois da carência — modo restrito**: execuções de programas rodam em
  transação **somente leitura** (o banco recusa gravações): consultas,
  relatórios, painéis e exportação continuam. O administrador continua
  podendo instalar a nova licença. Nunca sequestro de dados.
- **Relógio**: a instância guarda a maior data já vista; data do servidor
  mais de 1 dia antes dela é tratada como licença inválida (modo restrito)
  até o relógio ser corrigido.
- **Sem licença** (instalação nova ou atualização de quem ainda não tem):
  avaliação de 30 dias com todos os módulos, contados da primeira partida
  com esta versão; depois, modo restrito.
- Licença com assinatura inválida ou de chave desconhecida é recusada na
  instalação; a anterior continua valendo.

### D6 — Versão máxima (manutenção)
A licença cobre versões até `max_version` (maior.menor). Uma versão do
produto acima disso **não sobe**: a partida para antes de aplicar as
migrações, com a mensagem do que fazer (instalar a licença renovada pelo
`ANA_LICENSE_FILE`) — nunca uma instalação pela metade.

### D7 — Ambientes e alta disponibilidade
- Licença `non_production` (sem custo) para a instância de desenvolvimento e
  testes (spec 034): tudo funciona, com faixa "Ambiente de testes — não usar
  em produção".
- Licença por **instância**, não por nó: o cluster inteiro usa a mesma.

### D8 — Camadas de programas
- **Produto**: namespaces reservados — os primeiros segmentos dos programas
  entregues pelo produto (`sales`, `projects`, `finance`, `bpm`…). O cliente
  não cria programa novo num namespace reservado (`PRODUCT_NAMESPACE`).
- **Cliente**: qualquer outro namespace; recomendado `cli.*`.
- Editar um programa do produto é permitido (a spec 028 detecta e oferece as
  atualizações); o Estúdio marca o programa como **"customizado — fora do
  suporte padrão"**.

### D9 — Pontos de extensão (fase 2)
Ganchos antes/depois genéricos, sem copiar o programa do produto: o cliente
registra um programa seu para um ponto (`before_*` pode recusar com erro de
negócio ou ajustar parâmetros; `after_*` recebe o resultado), na mesma
transação. Primeiros pontos: faturar pedido, receber compra, aprovar compra,
faturar projeto e baixar título.

### D10 — Permissão por dado (fase 2)
Dimensões: empresa (CNPJ), centro de custo, carteira do vendedor e projetos
do gestor, atribuídas a grupos de acesso e aplicadas **pelo banco** (RLS),
não pelo programa.

### D11 — Marca conjunta (fase 3)
Nome e logotipo do cliente no topo do Estúdio e nos PDFs, mantendo a
identidade do ANA (spec 029).

### D12 — Idioma, moeda e fuso
Só pt-BR e BRL por enquanto (fuso já configurável). Nenhum trabalho de
tradução agora.

### D13 — Telemetria (fase 3)
Desligada por padrão; ligada pelo administrador, envia só versão, saúde e
contagem de erros (nunca dados de negócio ou de pessoas) para o endpoint do
fornecedor configurado no conector de telemetria.

## Requisitos (fase 1)
- **RF-009-01** Verificação da licença (formato, assinatura, chave
  confiável, validade, versão) e estado único da instância: `trial`,
  `valid`, `expiring`, `grace`, `restricted` (com motivo), consultado por
  todas as execuções sem ida ao banco.
- **RF-009-02** Instalação pela tela (administrador) e por `ANA_LICENSE_FILE`;
  histórico de licenças instaladas (quem, quando, qual) e auditoria.
- **RF-009-03** Módulos: programa de módulo não contratado → `NOT_LICENSED`;
  API pública e portal recusados quando não contratados; o BPM avisa na
  publicação.
- **RF-009-04** Limite de usuários nomeados na criação e reativação.
- **RF-009-05** Modo restrito por transação somente leitura, com erro
  `LICENSE_RESTRICTED` legível.
- **RF-009-06** Avaliação de 30 dias, aviso de 30 dias, carência de 15 dias,
  proteção do relógio.
- **RF-009-07** Versão máxima conferida na partida, antes das migrações.
- **RF-009-08** Faixa na tela para avaliação, vencimento próximo, carência,
  modo restrito e ambiente não produção; tela Administração → Licença com
  estado, módulos, limites e uso.
- **RF-009-09** Namespaces reservados ao produto; selo "customizado" no
  Estúdio.
- **RF-009-10** Ferramenta do fornecedor: gerar par de chaves, emitir e
  conferir licença.

## Requisitos não funcionais
- **RNF-009-01** A conferência por execução custa um acesso a
  `persistent_term` (nenhuma consulta ao banco).
- **RNF-009-02** Nenhum caminho bloqueia leitura ou exportação de dados.
- **RNF-009-03** A chave privada de produção nunca entra no repositório nem
  no pacote.

## Critérios de aceite (fase 1)
- **CA-009-01** Licença válida instalada pela tela → estado `valid`, módulos
  e limites mostrados; licença adulterada (um byte) ou de chave
  desconhecida → recusada, a anterior continua.
- **CA-009-02** Sem o módulo projetos, `projects.*` responde `NOT_LICENSED`;
  um programa `cli.*` e o núcleo continuam executando.
- **CA-009-03** Com limite de N usuários e N ativos, criar o próximo →
  `LICENSE_LIMIT`; robôs e contas do portal continuam podendo ser criados.
- **CA-009-04** Licença vencida além da carência → leitura e relatórios
  funcionam, gravação responde `LICENSE_RESTRICTED`; instalar licença nova
  volta tudo na hora.
- **CA-009-05** Vencida dentro da carência → tudo funciona, estado `grace`
  com faixa.
- **CA-009-06** Licença de chave de teste → sempre `non_production`.
- **CA-009-07** Criar programa novo em namespace do produto →
  `PRODUCT_NAMESPACE`; editar um programa do produto o marca como
  customizado.
- **CA-009-08** Licença com versão máxima menor que a do produto → recusada
  na instalação ("não cobre a versão").

## Fases
1. Licença, módulos, limites, expiração, versão, ambientes, camadas
   (D1–D8).
2. Pontos de extensão e permissão por dado (D9, D10).
3. Marca conjunta e telemetria (D11, D13).
