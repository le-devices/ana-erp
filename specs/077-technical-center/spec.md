# 077 — Central técnica e modo de socorro

Situação: especificada (nov/2026); plano em plan.md (28/11/2026). Reúne e completa o que já existe na Administração (specs 011, 019, 023, 024,
028, 033, 036, 062, 063) e se apoia nas specs 046 (diagnósticos), 047 (acesso emergencial), 056 (ensaio) e 057
(suporte).

## Problema
Manter um ERP de pé é um trabalho técnico contínuo:
- acompanhar a saúde dos nós, do banco, do disco, das filas e das integrações;
- aplicar atualizações e levar mudanças entre ambientes;
- cuidar de backups, certificados, segredos, licença e retenção;
- agir rápido quando algo quebra.

Nos ERPs grandes, isso exige um especialista dedicado ou uma consultoria. Uma empresa pequena ou média não tem
nenhum dos dois. O resultado é que problemas simples (disco enchendo, certificado vencendo, backup que nunca foi
testado) viram paradas.

O ANA já tem quase todas as peças, mas elas estão espalhadas em cerca de 30 seções da Administração, organizadas
por tela e não pelo trabalho. Quem não é especialista não sabe por onde começar nem o que é urgente.

O caso mais grave é a falha séria. Quando o banco está fora, o disco cheio ou a aplicação em laço de quedas, a
própria tela de administração cai junto: ela depende do banco para o login, para a auditoria e para tudo o que
mostra. Sobra o terminal, que exige conhecer o produto por dentro.

## Objetivo
Uma área técnica que:
1. **é rápida e amigável:** em segundos mostra o que precisa de atenção e qual é o próximo passo, com um botão;
2. **não tira a flexibilidade:** dá para investigar a fundo e configurar cada parâmetro técnico com precisão;
3. **funciona na falha grave:** continua informando e guiando com o banco fora, a aplicação principal caída ou o
   disco cheio;
4. **é segura:** nenhuma ação técnica vira porta dos fundos. Tudo é tipado, ensaiado quando possível, com quatro
   olhos no que é arriscado, e tudo fica registrado, inclusive quando o banco não está disponível.

## O que já existe (base)
- **Saúde e operação:** saúde, núcleo (062), disco e desgaste (063), desempenho das telas e do SQL, consumo,
  limites, alertas e dicas (019), verificações periódicas (033).
- **Alta disponibilidade (023):** vários nós, desligamento gracioso, atualização sem parada, troca de primário do
  banco e testes de caos.
- **Instalação e operação do servidor (036):** `deploy/ana-ctl` com `status`, `doctor`, `backup`, `restore-test`,
  `upgrade`, `rollback`, `disk` e `logs`.
- **Mudanças:** atualizações do produto (028), transportes e cópia de dados entre ambientes (034), retenção (024).
- **Especificadas, ainda não implementadas:**
  - acesso emergencial com aprovador e prazo, e depuração por reexecução (047);
  - diagnósticos e grupos de erro (046);
  - central de suporte e parceiros (057);
  - ensaio universal (056).

Esta spec não duplica nada disso. Ela organiza essas peças pelo trabalho, acrescenta o que falta (roteiros, ações
tipadas, configuração granular, modo de socorro) e define como tudo continua disponível na falha.

## Decisões

### Uso rápido e amigável

- **D1 — Uma Central técnica organizada pelo trabalho.** Administração → **Central técnica**, com seis abas:

  | Aba | O que mostra |
  |---|---|
  | **Agora** | O que precisa de atenção, do mais grave ao menos grave |
  | **Rotina** | O que é feito sempre (backup testado, certificados, atualizações, retenção, verificações), com o que está em dia e o que atrasou |
  | **Capacidade** | Tendências e previsões ("o disco enche em 23 dias", "a licença vence em 40 dias", "a fila de saída cresce 8% por semana") |
  | **Mudanças** | Atualizações, transportes, parâmetros alterados e versões, com quem mudou e quando |
  | **Segurança técnica** | Acessos emergenciais, sessões de suporte, segredos e certificados com prazo, chaves de socorro |
  | **Registro** | Tudo o que foi feito na área, com busca |

  As seções atuais da Administração continuam existindo e passam a ser o detalhe de cada item. Nada some, e ninguém
  precisa saber de antemão em qual seção está o problema.

- **D2 — Cada item responde quatro perguntas, em linguagem de negócio.**
  1. **O quê:** "o banco está respondendo devagar";
  2. **Por quê:** "a consulta X ocupa 70% do tempo desde ontem às 14h";
  3. **Que efeito tem:** "as telas de pedido levam 3 s em vez de 0,4 s";
  4. **O que fazer:** um botão para o próximo passo recomendado, com a consequência escrita.

  A situação nunca é só cor: tem ícone e texto, como no restante do produto (spec 029). O termo técnico existe, mas
  fica no detalhe.

- **D3 — Três camadas de profundidade em todo item.**
  1. **Resumo e ação recomendada:** um toque.
  2. **Investigar:** gráficos, eventos, execuções, consultas e registros ligados ao item, com filtros.
  3. **Avançado:** todos os parâmetros envolvidos, as ações alternativas e o console de diagnóstico (D7).

  Quem resolve rápido fica na primeira camada. Quem precisa de controle fino desce sem trocar de tela.

- **D4 — Encontrar qualquer coisa pelo nome.** A paleta de comandos (spec 050) busca ações, roteiros, parâmetros,
  nós, filas, conectores e execuções ("pausar conector banco", "parâmetro tempo máximo de execução", "roteiro disco
  cheio"). Também por atalho de teclado e pelo celular no plantão (spec 060), com notificação do alerta já trazendo
  o roteiro.

### Agir com segurança

- **D5 — Ações técnicas tipadas, nunca comando livre.** Toda intervenção é uma **ação do catálogo**. O catálogo é
  dado, versionado e entregue pelo produto, e extensões revisadas pelo portão da spec 064 podem acrescentar ações.
  Cada ação declara:
  - parâmetros com tipo e faixa;
  - **pré-condições** (o que é conferido antes);
  - o **efeito** em português e o **impacto** previsto (quem é afetado, por quanto tempo);
  - o **risco** (D6);
  - se pode ser **ensaiada** (spec 056) e como se **desfaz**;
  - o **critério de sucesso**, conferido depois de agir.

  Exemplos:
  - pausar e retomar um conector, o agendador ou uma esteira;
  - drenar um nó, reiniciar um subsistema e encerrar uma execução;
  - encerrar as sessões de um usuário;
  - ligar o modo somente leitura ou de manutenção (D13);
  - liberar espaço pela retenção;
  - renovar um certificado e girar um segredo;
  - trocar o primário do banco;
  - reindexar sem bloquear, analisar uma tabela;
  - restaurar um backup num ambiente de teste.

  Não existe campo para digitar código, comando do sistema operacional ou SQL que grava.

- **D6 — Risco decide a cerimônia, e a configuração é granular.** Cada ação tem uma classe de risco:

  | Risco | Exemplos | Como é feita |
  |---|---|---|
  | **Baixo** (reversível, sem perda) | pausar, drenar, analisar | Um toque, com a opção de desfazer em seguida |
  | **Médio** (afeta pessoas, reversível) | reiniciar, encerrar sessões, modo somente leitura | Confirmação que diz a consequência e o prazo previsto |
  | **Alto** (irreversível ou com risco de perda) | trocar o primário, restaurar, girar a chave mestra, apagar dados | Ensaio quando possível e **segunda pessoa** (quatro olhos) |

  Cada empresa pode tornar uma ação mais rígida (exigir segunda pessoa para reiniciar, por exemplo), mas nunca
  menos rígida que o mínimo do produto. Em plantão, pode permitir "agir agora e revisar depois" por ação, como o uso
  imediato da spec 047 (D1): os aprovadores são avisados na hora e a revisão fica pendente nas Verificações.

  Quem pode o quê é configurado por **grupo e por ação**: o plantão pode drenar e pausar, só o responsável técnico
  troca o primário. Não é só o papel "admin".

- **D7 — Console de diagnóstico seguro, para a flexibilidade.** Para investigar o que nenhum painel previu:
  - **Consultas de diagnóstico prontas**, com parâmetros: travas, transações longas, inchaço de tabelas, réplicas,
    conexões, maiores tabelas, consultas mais caras.
  - **SQL somente leitura:** papel de banco sem escrita, tempo máximo curto, limite de linhas, colunas sigilosas
    mascaradas (como na spec 068, D10) e plano de execução sob pedido.
  - **Introspecção do núcleo** (062): processos, filas, memória, mensagens pendentes, árvore de supervisão.
  - **Registros (logs)** com filtro por nó, nível, subsistema, execução e período.

  Uma consulta útil pode ser salva como consulta de diagnóstico, com nome, para a equipe reusar. Qualquer coisa além
  da leitura (corrigir dado, depurar uma execução real) passa pelo acesso emergencial da spec 047.

- **D8 — Roteiros guiados como dado.** Um **roteiro** é uma sequência de passos para resolver uma situação conhecida:
  disco cheio, banco fora, réplica atrasada, nó que não sobe, laço de quedas, certificado vencido, fila parada,
  restaurar até um instante, trocar de servidor. O produto entrega os roteiros como dados versionados, e o cliente
  ou o parceiro pode acrescentar os seus.

  Cada passo é uma **verificação** (com resultado esperado), uma **ação do catálogo** (D5) ou uma **instrução** para
  a pessoa ("confira se o servidor tem energia"), com:
  - critério de sucesso;
  - o que fazer se falhar (outro passo ou parar e pedir ajuda);
  - tempo esperado.

  Na execução de um roteiro:
  - as verificações rodam sozinhas e a pessoa só decide;
  - dá para seguir passo a passo ou "executar até a próxima decisão";
  - dá para pausar, retomar ou entregar para outra pessoa no meio;
  - cada execução fica registrada, com o tempo de cada passo.

  Os alertas (019) e os itens da aba Agora já trazem o roteiro certo. Um roteiro também pode virar regra automática
  para o que é seguro (spec 051): drenar o nó que falha nas verificações, por exemplo.

- **D9 — Configuração técnica granular, como dado e com histórico.** Cada parâmetro técnico (tempos máximos,
  limites, tamanhos de pool, intervalos, retenções, limiares de alerta, filas, conectores) fica num **catálogo** com:
  - nome em português, explicação e "quando mudar";
  - tipo, faixa permitida e valor padrão;
  - **escopo:** produto, empresa, ambiente ou nó. O mais específico vale, e a tela mostra de onde veio o valor em
    uso;
  - **quando vale:** na hora, na próxima execução ou depois de reiniciar;
  - classe de risco (D6).

  Na tela:
  - por padrão, só o que **foi alterado** nesta instalação, com a diferença para o padrão e o motivo de cada
    mudança;
  - todos os parâmetros com busca;
  - alteração com motivo obrigatório e ensaio do efeito quando dá (ex.: "com este limite, 3 rotinas de ontem teriam
    sido interrompidas");
  - **mudança temporária**, com prazo: volta sozinha ao valor anterior, útil numa crise;
  - **versões:** voltar a qualquer configuração anterior;
  - comparar dois ambientes e levar a diferença pelo transporte (034), com quatro olhos para risco alto;
  - exportar e importar como arquivo legível, para o parceiro revisar.

  Nenhum parâmetro técnico fica só em variável de ambiente sem aparecer aqui. Quando um valor vem do servidor e não
  pode ser mudado pela tela, a tela mostra o valor, a origem e como mudar.

### Funcionar na falha grave

- **D10 — Três camadas, cada uma para um nível de falha.**

  | Situação | Quem atende | O que precisa estar de pé |
  |---|---|---|
  | Normal ou degradada (lento, uma integração fora, um nó a menos) | **Central técnica** no Estúdio | Banco e aplicação |
  | Grave (banco fora, aplicação principal caída ou em laço de quedas, disco cheio, Python fora) | **Modo de socorro** | Só a máquina virtual Erlang do nó |
  | Extrema (a máquina virtual não sobe, o servidor reiniciou) | **`ana-ctl`** no servidor | Só o servidor |

  As três camadas compartilham o catálogo de ações, os roteiros e o formato do registro. O mesmo roteiro "banco fora"
  aparece na Central, no socorro e no `ana-ctl`, com os passos que cada camada consegue executar.

- **D11 — O modo de socorro é uma aplicação OTP à parte.** Uma aplicação própria (`ana_rescue`), na mesma release
  mas com árvore de supervisão própria:
  - **Não depende** do banco, do runtime Python, do pool de conexões nem da pilha web da aplicação principal.
  - **Sobe antes e não cai junto.** Uma queda ou laço de quedas da aplicação principal não derruba o socorro nem a
    máquina virtual. Os reinícios da principal passam a ser controlados, com limite e recuo, e o socorro mostra o
    motivo de cada queda.
  - **Porta própria**, ligada por padrão só em localhost e na rede administrativa declarada na instalação, com
    HTTPS. Página mínima, sem bibliotecas externas, legível no celular.

  O que o socorro mede sozinho:
  - processos, memória e filas da máquina virtual;
  - espaço livre e desgaste do disco (063);
  - alcance, latência e situação de replicação do banco, por uma conexão própria de diagnóstico, curta e com papel
    somente leitura;
  - situação dos outros nós;
  - os últimos registros (logs), guardados em memória num anel de tamanho fixo;
  - a **última fotografia da saúde**, mantida em memória e gravada num arquivo pequeno só quando muda (P15).

  O que ele executa: as ações do catálogo marcadas como "disponível no socorro". Por exemplo:
  - parar ou reiniciar a aplicação principal;
  - drenar este nó;
  - ligar o modo somente leitura;
  - liberar espaço em arquivos do próprio ERP pela retenção (registros antigos, temporários, pacotes de
    diagnóstico);
  - apontar para o novo primário do banco;
  - gerar o pacote de diagnóstico (057) para o suporte.

- **D12 — Acesso de socorro sem depender do banco, com duas pessoas para o arriscado.**
  - **Com o banco de pé**, o socorro aceita o login normal de quem tem o perfil técnico, e vale tudo da spec 047.
  - **Sem o banco**, vale o acesso de socorro, por **guardiões** (pessoas nomeadas, no mínimo duas):
    - cada guardião cadastra uma **chave de acesso** (passkey, no celular ou numa chave física). O servidor guarda só
      a parte pública, num arquivo local com permissão restrita, e o segredo nunca sai do aparelho do guardião;
    - como alternativa, para quem não tem chave de acesso, um **código de uso único** (TOTP). Esse segredo precisa
      ficar no servidor para conferir o código, por isso fica cifrado com a chave do nó, e a aba Segurança técnica
      mostra que esse guardião usa a forma mais fraca;
    - a lista de guardiões é mantida na Central técnica e copiada para o arquivo local de cada nó quando muda;
    - entrar exige um guardião;
    - ações de risco alto exigem **um segundo guardião**, que confirma no próprio aparelho;
    - tentativas são limitadas, com bloqueio progressivo;
    - cada entrada gera aviso, enviado na hora quando dá (e-mail, celular) e, se não der, quando o ERP voltar.
  - A chave do nó pode ser girada pela Central, e um guardião removido perde o acesso em todos os nós.
  - No `ana-ctl`, quem já tem acesso de administrador ao servidor confirma com o código ou a chave de um guardião
    para as ações de risco alto. O acesso ao servidor sozinho não basta para elas.

- **D13 — Registro que resiste à falha.** Tudo o que se faz na Central, no socorro e no `ana-ctl` gera um registro
  com:
  - quem, quando e de onde;
  - a ação e os parâmetros;
  - o antes e o depois;
  - o resultado.

  No socorro e no `ana-ctl`, o registro vai primeiro para um **arquivo local só de acréscimo**. Cada linha leva o
  resumo da anterior (encadeado), e cada ação é gravada em disco antes de terminar. O volume é baixo: só ações, nunca
  leituras.

  Quando o banco volta, o registro local entra na auditoria normal (024). Antes disso, a cadeia é conferida. Linha
  faltando ou alterada vira alerta e pendência nas Verificações.

- **D14 — Modos de operação degradada, anunciados às pessoas.** Ações do catálogo para atravessar uma crise:
  - **somente leitura:** consultas funcionam e gravações são recusadas com mensagem clara;
  - **manutenção:** só a equipe técnica entra;
  - entrada de integrações pausada (as mensagens esperam na fila);
  - rotinas pesadas e agendamentos suspensos.

  Cada modo tem prazo previsto e mensagem, mostrada numa faixa no Estúdio, no portal e na API ("o ERP está em
  manutenção até 14h30: consultas funcionam, gravações não"). Ao sair do modo, tudo o que foi pausado volta na ordem
  certa.

- **D15 — Treinar antes da crise.** Todo roteiro pode ser **ensaiado** num ambiente de teste (034) com a falha
  provocada de propósito, reaproveitando os testes de caos da spec 023. Um **simulado de crise** pode ser agendado
  (ex.: a cada trimestre): o resultado (tempo até resolver, passos que falharam) fica registrado, e roteiro nunca
  treinado aparece na aba Rotina.

  O teste de restauração do backup (036) entra na mesma rotina: backup nunca restaurado não conta como em dia.

### Suporte e parceiros
- **D16 — O parceiro vê o mesmo que o cliente, só com consentimento.** O suporte e o parceiro responsável pela
  instalação (057) usam a mesma Central e os mesmos roteiros. O acesso é concedido pelo cliente, com prazo e
  escopo, e é registrado (047 e 057). Para o socorro, o cliente pode nomear um guardião do parceiro.

  O pacote de diagnóstico (057, D2) sai de qualquer camada, inclusive do socorro e do `ana-ctl`, com dados de
  negócio mascarados.

### Fora do escopo
- Administração do sistema operacional (pacotes, núcleo, usuários do servidor, firewall): o `ana-ctl` confere e
  orienta, mas não altera o servidor além do próprio ERP.
- Terminal livre ou execução de código arbitrário em qualquer camada.
- Ferramentas de banco além das ações e consultas do catálogo. O que não estiver lá passa pelo acesso emergencial
  (047) e fica registrado.

## O que a pessoa deixa de fazer (P19)
- Abrir várias seções para descobrir o que está errado: a aba Agora diz, em ordem de gravidade, com o próximo passo.
- Lembrar de rotinas técnicas (testar backup, renovar certificado, girar segredo, conferir réplica): a aba Rotina
  cobra, e o que é seguro roda sozinho.
- Saber de cor o que fazer numa crise: o roteiro guia, conferindo cada passo.
- Comparar ambientes e copiar configurações à mão: a diferença sai pronta e vai pelo transporte.
- Chamar um especialista para "ver o que houve" com o banco fora: o socorro mostra e o pacote de diagnóstico vai ao
  suporte com um toque.

## Requisitos funcionais
- **RF-077-01** Central técnica com as abas Agora, Rotina, Capacidade, Mudanças, Segurança técnica e Registro (D1),
  alimentada pelas fontes existentes (saúde, alertas, verificações, disco, núcleo, atualizações, transportes,
  retenção, licença, acessos), sem duplicar dados.
- **RF-077-02** Item com o quê, por quê, efeito e ação recomendada, em três camadas de profundidade (D2, D3).
- **RF-077-03** Busca de ações, roteiros, parâmetros e componentes pela paleta de comandos (D4).
- **RF-077-04** Catálogo de ações técnicas como dado, com parâmetros, pré-condições, efeito, impacto, risco, ensaio,
  forma de desfazer e critério de sucesso; extensível por pacote revisado (D5).
- **RF-077-05** Classes de risco com a cerimônia de cada uma; endurecimento por empresa e permissão por grupo e por
  ação; "agir agora e revisar depois" configurável por ação (D6).
- **RF-077-06** Console de diagnóstico: consultas prontas, SQL somente leitura com limites e mascaramento,
  introspecção do núcleo e registros filtráveis; consultas salvas pela equipe (D7).
- **RF-077-07** Roteiros como dado: passos de verificação, ação e instrução, com sucesso, falha e tempo esperado;
  execução passo a passo ou até a próxima decisão, pausa, retomada e entrega a outra pessoa; ligados aos alertas
  (D8).
- **RF-077-08** Catálogo de parâmetros técnicos com escopo, origem do valor, quando vale e risco; alterados primeiro,
  motivo obrigatório, ensaio, mudança temporária, versões, comparação e transporte entre ambientes, exportação (D9).
- **RF-077-09** Modo de socorro como aplicação OTP independente, com porta própria, medições locais, última
  fotografia da saúde e as ações marcadas para o socorro (D10, D11).
- **RF-077-10** Reinício controlado da aplicação principal pelo socorro, com limite, recuo e motivo da queda (D11).
- **RF-077-11** Acesso de socorro por guardiões com chave de acesso (ou código de uso único como alternativa
  sinalizada), segundo guardião para risco alto, giro e remoção pela Central, avisos de cada entrada (D12).
- **RF-077-12** Registro encadeado local no socorro e no `ana-ctl`, conferido e levado à auditoria quando o banco
  volta (D13).
- **RF-077-13** Modos somente leitura e manutenção, entrada de integrações pausada e rotinas suspensas, com prazo,
  mensagem nas telas, no portal e na API, e volta ordenada (D14).
- **RF-077-14** `ana-ctl` com os mesmos roteiros e o mesmo formato de registro, para quando a máquina virtual não
  sobe (D10).
- **RF-077-15** Ensaio de roteiros com falha provocada num ambiente de teste e simulado de crise agendado, com
  resultado registrado (D15).
- **RF-077-16** Acesso do suporte e do parceiro com consentimento, prazo e escopo; pacote de diagnóstico de
  qualquer camada (D16).

## Requisitos não funcionais
- **RNF-077-01 (robustez).** O socorro continua respondendo, nos testes de caos, com:
  - o banco parado;
  - o disco do banco cheio;
  - o runtime Python parado;
  - a aplicação principal em laço de quedas;
  - a memória da máquina virtual em 90% do limite.

  A memória e os processos do socorro têm limite próprio, e ele nunca compete com a aplicação principal por
  conexões.
- **RNF-077-02 (segurança).**
  - Nenhuma camada executa código, comando do sistema ou SQL que grava fora do catálogo.
  - O socorro só escuta no endereço configurado.
  - Os segredos dos guardiões nunca ficam em texto claro no servidor: chave de acesso guarda só a parte pública, e
    o código de uso único fica cifrado.
  - O registro local não pode ser alterado sem que a conferência acuse.
  - Ação de risco alto sem segunda pessoa é recusada em todas as camadas, inclusive pela API.
- **RNF-077-03 (desempenho).**
  - Central técnica: abre com a aba Agora em até 1 s (p95) com 10 mil eventos no período.
  - Página do socorro: responde em até 200 ms (p95) com o banco fora.
  - Ociosas, a Central e o socorro não fazem consultas além das medições que já existem (019, 062).
- **RNF-077-04 (escrita, P15).** O socorro grava só quando algo muda (fotografia da saúde) ou quando alguém age
  (registro), e o anel de registros fica em memória. Os valores medidos entram no orçamento da spec 063.
- **RNF-077-05 (experiência, P18).**
  - Do alerta ao primeiro passo do roteiro em até 2 toques, também no celular.
  - Toda tela passa pelo verificador da spec 050.
  - Nenhum termo técnico aparece sem explicação ao lado.
- **RNF-077-06 (multinó).** Cada nó tem o próprio socorro. Cada socorro mostra os outros nós que alcança, e uma ação
  num nó nunca é aplicada em outro sem que a pessoa escolha.

## Critérios de aceite
- **CA-077-01** Com o disco a 92%, a aba Agora mostra o item em primeiro lugar, com a previsão de quando enche, o que
  mais ocupa e o botão do roteiro "disco cheio". O roteiro confere, libera espaço pela retenção e mostra o espaço
  recuperado.
- **CA-077-02** Com o banco parado:
  - o Estúdio indica que está indisponível e aponta para o socorro;
  - o socorro responde, mostra "banco inacessível desde 10h42" e a última fotografia da saúde;
  - o guardião entra com a chave de acesso e segue o roteiro "banco fora";
  - quando o banco volta, o registro do socorro aparece na auditoria com a cadeia conferida.
- **CA-077-03** A aplicação principal em laço de quedas não derruba a máquina virtual. O socorro mostra o motivo das
  quedas e o número de tentativas, e "parar a aplicação" interrompe o laço.
- **CA-077-04** Trocar o primário do banco pede a confirmação de um segundo guardião no socorro, ou a aprovação de uma
  segunda pessoa na Central. Sem isso, é recusado também pela API.
- **CA-077-05** Um parâmetro alterado com prazo de 1 hora volta sozinho ao valor anterior, e as duas mudanças ficam
  no histórico com motivo.
- **CA-077-06** A comparação entre teste e produção mostra só os parâmetros diferentes, e levar a diferença pelo
  transporte pede quatro olhos para os de risco alto.
- **CA-077-07** Uma linha removida do registro local é acusada na conferência, vira alerta e vira pendência nas
  Verificações.
- **CA-077-08** No modo somente leitura:
  - uma gravação pelo Estúdio, pela API ou por uma rotina é recusada com a mensagem do modo;
  - as consultas funcionam;
  - ao sair, os agendamentos e as integrações pausados voltam.
- **CA-077-09** O console recusa SQL que grava e respeita o tempo máximo e o limite de linhas. Coluna sigilosa sai
  mascarada.
- **CA-077-10** O simulado de crise "banco fora", agendado no ambiente de teste, provoca a falha, mede o tempo até o
  roteiro terminar e registra o resultado na aba Rotina.
- **CA-077-11** Com a máquina virtual parada, `ana-ctl rescue` mostra os mesmos roteiros e grava o registro no mesmo
  formato, que entra na auditoria quando o ERP volta.
- **CA-077-12** Um guardião removido na Central não entra mais no socorro de nenhum nó, nem com o banco fora.

## Experiência e automação (P18, P19)
- Uma pergunta responde a área: "está tudo bem?". A primeira linha da Central diz sim ou não, e o porquê.
- A ação recomendada é sempre o botão principal. As alternativas ficam em "Outras ações", e o avançado a um toque.
- Os alertas chegam com o roteiro, no Estúdio e no celular. O plantão resolve o comum sem abrir o computador.
- As rotinas técnicas seguras rodam sozinhas: teste de restauração, conferência de certificados, verificação de
  réplica, limpeza pela retenção. A pessoa só vê o que precisa de decisão.
- Sugestões (spec 051): uma ação repetida à mão vira proposta de regra ("você drenou o nó 2 três vezes quando a
  memória passou de 90%: quer que o ERP faça isso sozinho e avise?").
