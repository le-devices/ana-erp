# 066 — Núcleo aberto (AGPL-3.0) e edição comercial

Situação: fase 1 implementada (nov/2026) — falta T-066-06, a publicação pelo dono do produto (checklist em plan.md); fases 2 e 3 na fila. Modelo decidido pelo dono do produto em 21/11/2026: **núcleo aberto em
AGPL-3.0, licença comercial para quem não quer as obrigações da AGPL, módulos premium num repositório privado**.

## Problema
O ANA é vendido com licença proprietária (spec 009): módulos contratáveis, usuários nomeados e modo somente
consulta quando a licença vence. O dono do produto quer mudar o modelo de negócio: **código aberto** e receita
por **suporte, implantação e customização, módulos premium, assinatura de atualizações fiscais e ANA como
serviço (SaaS)**. De quebra, o repositório público tem GitHub Actions sem limite de minutos, que hoje é o
gargalo da bateria.

Abrir o código muda o papel da licença assinada: dentro de código AGPL, qualquer verificação pode ser removida
legalmente. O controle passa a valer só para o que **não** está aberto (módulos premium, pacotes fiscais
oficiais, suporte) — e o contrato, a marca e o canal de atualizações são a proteção real (já era assim, D2 da
spec 009).

## Decisões

### D1 — Licença do núcleo: AGPL-3.0-or-later
- Todo o conteúdo do repositório público: núcleo Erlang, runtime Python, programas do produto, Estúdio,
  migrações, instalação, testes e specs.
- AGPL e não Apache/MIT: quem oferecer o ANA modificado **como serviço a terceiros** precisa publicar as
  modificações — protege o SaaS do fornecedor contra quem revenderia o ANA sem devolver nada.
- **Os programas do cliente** (`cli.*` e qualquer namespace fora do produto, D8 da spec 009) rodam pela API
  do runtime (`ana.*`) e são do cliente; o produto declara a **exceção de programas** no `LICENSE`/`NOTICE`:
  programas de negócio executados pelo ANA através da API do runtime não são obra derivada só por isso. O
  cliente customiza sem ter de abrir o próprio código (sem isso, a AGPL assusta quem compra ERP).
- Dependências atuais são compatíveis: cowboy, cowlib e ranch (ISC), epgsql (BSD), Citus (AGPL), Python e
  Erlang/OTP (licenças permissivas). Toda dependência nova passa a ser conferida (lista de licenças aceitas na
  bateria).

### D2 — Licença comercial (dupla licença)
- Quem não quer as obrigações da AGPL (por exemplo, um integrador que oferece o ANA modificado como serviço sem
  publicar as mudanças) contrata a **licença comercial** do fornecedor.
- Só é possível se o fornecedor puder relicenciar todo o código: contribuições externas entram com o **Termo de
  Licença de Contribuição** (`CLA.md`), conferido automaticamente no pull request. É uma licença ampla ao
  fornecedor (direitos autorais e patentes, inclusive para licenças comerciais), não uma cessão: o
  contribuidor continua dono do que escreveu, os direitos morais são preservados (Lei 9.610/1998), e o
  fornecedor se compromete a manter toda contribuição do núcleo disponível em AGPL-3.0 — se não cumprir, a
  licença volta a valer só para usos sob a AGPL. Empresas podem aceitar por todos os seus empregados.

### D3 — Núcleo aberto, sem trava
- A edição aberta não tem limite de usuários, de módulos nem de prazo, e **nunca** entra em modo somente
  consulta por licença. Todos os módulos que já existem (vendas, suprimentos, produção, logística e campo,
  projetos, BPM, analítico, API pública, portal, impostos…) ficam no núcleo aberto: o histórico do repositório
  já os contém.
- A tela Administração → Licença passa a mostrar a **edição** (Comunitária ou Comercial), o contrato de suporte
  e as assinaturas ativas (premium, pacotes fiscais) — sem faixa de alerta na edição comunitária.
- O que da spec 009 continua útil para todos: camadas de programas (namespaces do produto, programas
  customizados marcados), pontos de extensão, permissão por dado, marca conjunta, telemetria opcional.

### D4 — Assinatura (a licença assinada da spec 009, com novo papel)
O mesmo arquivo assinado com Ed25519 (D2 da spec 009, sem internet) passa a dizer **o que o cliente assinou**:
- **Módulos premium** que pode carregar (D5); vencida a assinatura, o módulo premium entra em somente leitura
  (seus dados continuam legíveis e exportáveis — nunca sequestro); o núcleo segue normal.
- **Pacotes fiscais oficiais** (D6): quais pode instalar e até quando.
- **Suporte**: nível e validade, mostrados na tela e no pacote de diagnóstico enviado ao suporte.
- **Licença comercial** (D2), quando houver.
Usuários nomeados deixam de ser limitados; o campo continua aceito (licenças antigas) e é ignorado.

### D5 — Módulos premium: repositório privado, carregados como extensão
- Ficam em repositório **privado** e chegam ao cliente como **pacote assinado** (mesmo formato de transporte da
  spec 034, assinado pelo fornecedor), com programas, migrações próprias e telas.
- Namespaces reservados `pro.*` (programas) e esquema `pro_*` (dados); a partida carrega os pacotes premium
  presentes e conferidos pela assinatura (D4).
- **Primeiros módulos premium** (decisão de 21/11/2026, pela recomendação do fornecedor), na ordem de lançamento:
  1. **Documentos fiscais eletrônicos**: NF-e, NFS-e (padrão nacional e prefeituras) e NFC-e — emissão,
     cancelamento, carta de correção, contingência e guarda dos XML. É a obrigação que toda empresa tem e o
     que mais custa manter atualizado (leiautes, certificados, SEFAZ e prefeituras).
  2. **Conectores bancários**: CNAB 240/400 (remessa e retorno), PIX com conciliação automática, boleto
     registrado e Open Finance — cada banco é um contrato e um leiaute a acompanhar.
  3. **Assistente com IA** (spec 052), quando usar modelo de linguagem pago pelo fornecedor; a versão que roda
     só com regras locais fica no núcleo.
  4. **Aplicativo de celular** (spec 060) e **chão de fábrica com rastreabilidade por série** (spec 054).
  Os pacotes fiscais oficiais (D6) e o suporte são assinaturas desde o início, sem depender destes módulos.
  Uma vez publicado no núcleo aberto, um recurso não volta a ser premium.

### D6 — Pacotes fiscais oficiais como assinatura
- O motor de impostos e o formato dos pacotes de regras continuam abertos (legislação é dado, P21): qualquer um
  pode escrever e instalar o próprio pacote.
- Os **pacotes oficiais do fornecedor** (Simples Nacional, ISS por município, reforma tributária CBS/IBS até
  2033, ICMS/IPI/PIS/COFINS) são **assinados**, com casos de teste, e atualizados a cada mudança da lei. A
  instalação de um pacote oficial confere a assinatura do pacote e a assinatura do cliente (D4).
- Pacotes oficiais já entregues continuam valendo depois que a assinatura vence; só deixam de chegar as
  atualizações.

### D7 — SaaS do fornecedor
- Mesmo código aberto, operado pelo fornecedor: alta disponibilidade (spec 023), cópias, observabilidade,
  transporte entre ambientes (spec 034), atualizações sem parada. A licença comercial (D2) não é necessária
  para o próprio fornecedor.
- A AGPL obriga a oferecer o código-fonte aos usuários do serviço: o rodapé "Sobre" do Estúdio mostra a
  versão, o commit e o endereço do código, inclusive em instalações de terceiros (RF-066-05).

### D8 — Publicação do repositório
- Varredura do histórico (21/11/2026): **nenhum segredo real** em 234 commits; só a chave de teste de licenças
  (`tests/integration/license_test.key`, que por desenho só assina licenças de não produção) e valores de
  exemplo. O histórico é publicado como está.
- O e-mail de autor dos commits (endereço da empresa) e o material interno (specs com decisões do dono do
  produto, `scripts/pending-work.prompt.md`) ficam públicos — decisão do dono do produto em 21/11/2026.
- A **chave privada de produção** das assinaturas (D4) e dos pacotes oficiais (D6) nunca entra em repositório
  nenhum; fica com o fornecedor, com cópia de segurança fora da máquina de desenvolvimento.
- Marca: "ANA" e o logotipo são marcas do fornecedor (registro no INPI); a AGPL cobre o código, não a marca —
  derivados redistribuídos usam outro nome (política de marca no repositório).

## Requisitos funcionais
- **RF-066-01** Arquivos de licença do repositório: `LICENSE` (texto integral da AGPL-3.0), `NOTICE` (direitos
  autorais, exceção de programas do D1, dependências e suas licenças), cabeçalho SPDX
  (`SPDX-License-Identifier: AGPL-3.0-or-later`) em todo arquivo-fonte, `src/ana.app.src` com
  `{licenses, ["AGPL-3.0-or-later"]}` (hoje diz Apache-2.0 por engano).
- **RF-066-02** `CONTRIBUTING.md` (como contribuir, specs primeiro, bateria, CLA), `SECURITY.md` (como reportar
  vulnerabilidade em sigilo, prazos de resposta, versões cobertas), `CODE_OF_CONDUCT.md` e política de marca.
- **RF-066-03** CLA (`CLA.md`) conferido no pull request pelo comentário de aceite, registrado com usuário, data e versão do termo: contribuição de quem não assinou não pode ser integrada (check
  obrigatório na bateria).
- **RF-066-04** Núcleo sem trava (D3): fim do limite de usuários nomeados, dos módulos contratáveis do núcleo e do
  modo restrito por licença; a avaliação de 30 dias deixa de existir; a tela Licença mostra edição, suporte e
  assinaturas.
- **RF-066-05** "Sobre" no Estúdio: versão, commit, licença AGPL e endereço do código-fonte (configurável pela
  instalação, obrigatório quando a instalação é modificada e oferecida a terceiros).
- **RF-066-06** Assinatura (D4): módulos premium, pacotes oficiais, suporte e licença comercial; vencida, o
  premium fica somente leitura e o núcleo segue normal.
- **RF-066-07** Carregamento de módulos premium (D5): pacote assinado, namespaces `pro.*`/`pro_*`, migrações
  próprias, conferência da assinatura na partida e na instalação; sem pacote, nada muda.
- **RF-066-08** Pacotes fiscais oficiais assinados (D6), conferidos na instalação; pacote de terceiros continua
  instalável (marcado "não oficial").
- **RF-066-09** Lista de licenças aceitas para dependências, conferida na bateria (dependência nova com licença
  fora da lista falha com o motivo).
- **RF-066-10** Checklist de publicação executado e registrado: varredura de segredos repetida no dia,
  arquivos do RF-066-01/02, CLA ativo, chave de produção gerada fora do repositório, proteção da branch `master`,
  segredos do GitHub revistos, e só então o repositório passa a público.

## Requisitos não funcionais
- **RNF-066-01** Nenhuma mudança de licença tira dado do cliente do ar: a migração do modelo (RF-066-04) é
  aplicada pela atualização normal, sem parada.
- **RNF-066-02** A varredura de segredos roda na bateria a cada pull request depois da publicação (segredo novo
  no diff falha a bateria antes de ficar público).

## Critérios de aceite
- **CA-066-01** Instalação nova sem licença nenhuma: todos os módulos do núcleo funcionam, sem prazo, sem faixa
  de alerta e sem limite de usuários.
- **CA-066-02** Instalação com licença antiga (spec 009): continua funcionando; nada que funcionava para.
- **CA-066-03** Módulo premium com assinatura vencida: lê e exporta, não grava, dizendo o motivo; o núcleo
  grava normalmente.
- **CA-066-04** Pacote fiscal oficial com assinatura inválida é recusado; pacote não oficial instala marcado como
  tal.
- **CA-066-05** Pull request de quem não assinou o CLA não pode ser integrado.
- **CA-066-06** Todo arquivo-fonte tem o cabeçalho SPDX (verificado na bateria) e "Sobre" mostra o endereço do
  código.

## Decisões em aberto (do dono do produto)
- Preços da assinatura, do suporte, dos módulos premium e da licença comercial (a definir).
- Registro da marca "ANA" no INPI — providenciado pelo dono do produto.
- Revisão jurídica do `CLA.md` e da exceção de programas antes da publicação (o rascunho diz que não está em
  vigor enquanto a nota de revisão existir).
