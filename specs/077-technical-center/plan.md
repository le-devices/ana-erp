# 077 — Plano

Base: a spec, as decisões D1–D16. Este plano detalha a **fase 1** (T-077-01..07) para implementar, e fixa para as
fases 2 e 3 o que a fase 1 precisa respeitar: a matriz de falhas, o modelo de ameaças e o desenho OTP do socorro.

## 1. O que já existe (inventário)

### 1.1 Seções da Administração e o lugar de cada uma na Central
As 34 seções continuam existindo e viram o **detalhe** dos itens. A Central só junta e ordena.

| Aba da Central | Seções que alimentam (e que o item abre) |
|---|---|
| **Agora** | Saúde, Alertas, Núcleo, Disco, Integrações (fila parada, erros), Monitor (execuções longas), Desempenho das telas e do SQL, Licença (vencida), Verificações (achados graves) |
| **Rotina** | Verificações (backup testado, restauração, chaves, vulnerabilidades), Retenção, Atualizações do produto, Agendamento (rotinas técnicas atrasadas) |
| **Capacidade** | Disco (projeção de desgaste e de espaço), Consumo, Limites e cotas, Núcleo (filas que crescem), Licença (vencimento, usuários nomeados) |
| **Mudanças** | Parâmetros, Transportes, Atualizações do produto, Extensões, Cópia de dados para testes |
| **Segurança técnica** | Usuários (bloqueios, sessões), Grupos, API pública (segredos e disjuntores), Integrações (segredos de conectores), Auditoria |
| **Registro** | Auditoria (ações técnicas) e o registro das ações da Central |

Ficam fora da Central (são de negócio, não técnicas): Empresa, Painel inicial, Assistente, Automações, Contas padrão,
Comandos, Sistemas remotos (configuração), Telemetria, Uso simulado.

### 1.2 Ações que a Administração já executa
Cerca de 30 rotas de escrita em `ana_http_admin`. As técnicas entram no catálogo (T-077-01) e passam a seguir a
cerimônia do risco também pela API:

| Ação do catálogo | Hoje | Risco do produto |
|---|---|---|
| Encerrar uma execução | `POST executions/:id/stop` | médio |
| Encerrar as sessões de um usuário | `POST users/:n/sessions/revoke` | médio |
| Desbloquear usuário / endereço | `POST users/:n/unlock`, `security/unlock-ip` | baixo |
| Reprocessar / descartar mensagem de integração | `POST integrations/:k/:id/reprocess`, `discard` | baixo / médio (descartar se desfaz reprocessando) |
| Liberar o disjuntor de um cliente da API | `POST api-clients/:id/release-breaker` | baixo |
| Girar segredo de cliente da API / chaves da API | `rotate-secret`, `api-keys/rotate` | médio (o segredo anterior vale até ser retirado; a empresa pode tornar alto) |
| Liberar espaço pela retenção | `POST retention/purge` | médio |
| Conferir a saúde agora / medir o disco agora | `observability/health/check`, `disk/sample` | baixo |
| Rodar as verificações / a análise de desempenho | `checks/run`, `observability/advice/run` | baixo |
| Mudar um parâmetro | `PUT settings/:key` | pelo parâmetro (D9) |

Novas na fase 1 (não existem hoje): **drenar este nó** e **voltar a receber** (`ana_ha:drain/0` existe, sem tela);
**pausar e retomar o agendador**, **um conector** e **a entrada de integrações**; **modo somente leitura**, **modo
manutenção** e **sair do modo**; **analisar uma tabela**.

### 1.3 Parâmetros técnicos de hoje
- **66 em `ana_settings`** (tipo, faixa, padrão, variável de ambiente, descrição; gravados em
  `ana_system.setting`, cache em ETS, propagados por NOTIFY). São a base do catálogo (T-077-04).
- **Só do servidor** (não mudam pela tela, aparecem com a origem e como mudar): `ANA_DB_*`, `ANA_DB_READ_HOSTS`,
  `ANA_HTTP_PORT`, `ANA_COOKIE`, `ANA_MASTER_KEY`, `ANA_INSTANCE*`, `ANA_TIMEZONE`, `ANA_PY*`, `ANA_FILES_DIR`,
  `ANA_LICENSE_FILE`, `ANA_LOG_FORMAT`, `ANA_TRUSTED_PROXIES`, `ANA_PUBLIC_*`, `ANA_HTTP_MAX_BODY`,
  `ANA_DRAIN_*`, `ANA_BREAKER_OPEN_MS`, `ANA_BPM_SWEEP_MS`. Segredos (`ANA_DB_PASSWORD`, `ANA_COOKIE`,
  `ANA_MASTER_KEY`, `ANA_ADMIN_PASSWORD`) aparecem só como "definido / não definido", nunca o valor.

## 2. Modelo da fase 1

### 2.1 Ações técnicas (T-077-01, T-077-02)
- **Catálogo** `technical.action` (dado, entregue por migração; extensões pelo portão da 064 numa fase posterior):
  código, nome e descrição em português, parâmetros tipados, pré-condições (códigos de verificação), efeito,
  impacto, risco mínimo do produto, ensaiável, ação que desfaz, critério de sucesso, disponível no socorro.
- **Executor no núcleo** (`ana_tech`): cada código liga a uma função de um mapa fixo em Erlang — o catálogo nunca
  aponta para código arbitrário. Um teste recusa linha do catálogo sem os campos obrigatórios ou sem função, e
  função sem linha.
- **Política da empresa** `technical.action_policy`: risco efetivo (só para cima do mínimo), grupos que podem,
  "agir agora e revisar depois". O risco efetivo decide a cerimônia:
  - baixo: executa e oferece desfazer;
  - médio: exige a confirmação (`confirmed: true`) — a tela mostra a consequência;
  - alto: cria um **pedido**; outra pessoa com permissão aprova; só então executa. Com "agir agora", executa e
    deixa a revisão pendente nas Verificações, avisando os aprovadores.
- **Registro** `technical.action_run`: quem, quando, de onde, parâmetros, antes, depois, resultado, aprovador,
  motivo. É a aba Registro e entra na auditoria (024).
- As rotas atuais da tabela 1.2 passam pelo executor: a cerimônia vale pela API também (RNF-077-02). A tela de cada
  rota já confirma com a consequência, então a rota conta como confirmada (risco médio); se a empresa tornar a ação
  alta, a rota responde 202 e o pedido espera a segunda pessoa.
- Um resultado com segredo (o segredo novo de um cliente da API) volta inteiro a quem pediu, mas fica mascarado no
  registro.
- Ações liberadas a grupos (o plantão) usam `/api/tech/…`, que qualquer pessoa conectada alcança; cada ação decide
  quem pode.

### 2.2 Parâmetros (T-077-04)
- **Catálogo** `technical.parameter`, gerado das definições de `ana_settings` mais os só do servidor: nome em
  português, explicação, "quando mudar", tipo, faixa, padrão, escopos permitidos, quando vale (na hora / na próxima
  execução / ao reiniciar), risco.
- **Valores com escopo** `technical.parameter_value`: instalação ou nó (o padrão é o produto; "empresa" só para os
  parâmetros que dependem dela). Vale o mais específico; a tela mostra a origem do valor em uso.
- **Versões** `technical.parameter_version`: toda mudança com motivo; voltar a uma versão é uma mudança nova.
- **Mudança temporária:** `expires_at`; o núcleo volta ao valor anterior no prazo (um temporizador no líder,
  conferido também ao subir), registrando a volta.
- `ana_system.setting` continua sendo lida pelo cache de hoje: o catálogo escreve nela o valor efetivo do nó, para
  nada mais mudar.
- Comparar ambientes e transporte usam o transporte da spec 034 (que já leva parâmetros conferidos por
  `ana_settings:valid/2`); exportação e importação em JSON legível.

### 2.3 Console de diagnóstico (T-077-05)
- **Consultas prontas** como dado (`technical.diagnostic_query`): SQL fixo, parâmetros tipados, explicação.
  Travas, transações longas, inchaço, réplicas, conexões, maiores tabelas, consultas mais caras.
- **SQL livre somente leitura:** papel `ana_read` (já sem escrita), transação `READ ONLY`, tempo máximo de 5 s,
  500 linhas, colunas sigilosas mascaradas pela classificação do catálogo da spec 068, plano sob pedido
  (`EXPLAIN` sem `ANALYZE`). Recusa no núcleo de qualquer comando que não comece por `SELECT`, `WITH` ou
  `EXPLAIN`, além do papel do banco.
- **Introspecção do núcleo:** a vista de `ana_core_view` (062).
- **Registros:** um manipulador do `logger` com anel em memória (`ana_log_ring`, 5 mil linhas por nó, sem
  escrita em disco), filtrável por nível, subsistema e texto. O mesmo anel serve ao socorro na fase 2.
- **Consultas salvas** pela equipe: nome e SQL somente leitura, conferido ao salvar e ao rodar.

### 2.4 Roteiros (T-077-06)
- `technical.runbook` (código, versão, nome, quando usar, passos) e `technical.runbook_run` (estado, passo atual,
  dono, registro de cada passo com o tempo).
- Passo: **verificação** (código de uma verificação do núcleo, com resultado esperado), **ação** (do catálogo, com a
  cerimônia dela) ou **instrução** (texto; a pessoa confirma). Cada um com sucesso, o que fazer se falhar, tempo
  esperado e as camadas em que existe.
- Executor: passo a passo, ou "até a próxima decisão" (verificações rodam sozinhas; para em ação de risco médio ou
  alto, instrução ou falha); pausar, retomar e entregar a outra pessoa.
- Roteiros do produto: disco cheio, banco fora, réplica atrasada, nó que não sobe, laço de quedas, certificado
  vencido, fila parada. Na fase 1, "banco fora" e "laço de quedas" mostram na Central só o que ela consegue
  (orientação e o caminho para o socorro).
- Os alertas (019) e os itens da Central trazem o código do roteiro.

### 2.5 Modos de operação (T-077-07)
- `technical.operation_mode` (uma linha por instalação): modo (normal, somente leitura, manutenção), entrada de
  integrações pausada, rotinas suspensas, mensagem, prazo previsto, quem ligou.
- Lido por NOTIFY para um termo persistente em cada nó (custo zero por requisição).
- **Somente leitura:** o executor roda todo programa em transação `READ ONLY` (mesmo mecanismo do
  `# ana:read_only`, spec 069) e recusa gravações com a mensagem do modo; a API pública e o portal também.
- **Manutenção:** só entra quem está no grupo técnico (e o administrador); sessões dos outros recebem a mensagem.
- **Integrações pausadas:** a entrada guarda na fila e não processa; **rotinas suspensas:** o agendador não
  dispara (o que estava agendado espera).
- **Faixa** no Estúdio, no portal e na API (`/api/status` e um cabeçalho), com a mensagem e o prazo.
- **Sair do modo:** volta na ordem certa — primeiro as gravações, depois a entrada de integrações, por último o
  agendador —, com registro.

### 2.6 Central técnica (T-077-03)
- `GET /api/admin/tech/:aba` monta os itens a partir das fontes existentes (nenhum dado duplicado). Item:
  gravidade, o quê, por quê, efeito, ação recomendada (código e parâmetros), roteiro, link para a seção de detalhe.
- Primeira linha: "está tudo bem?" — sim ou não e o porquê.
- Tela `tech.js` no Estúdio, com as seis abas, as três camadas e a paleta de comandos (ações, roteiros,
  parâmetros). Passa pelo verificador da spec 050.

## 3. Matriz de falhas

| Falha | Central (Estúdio) | Socorro (fase 2) | `ana-ctl` (fase 3) | Roteiro |
|---|---|---|---|---|
| Banco fora | Cai (login, auditoria). O Estúdio mostra "indisponível" e aponta o socorro | Vê alcance e latência pela conexão própria; última fotografia; registros do anel. Age: modo somente leitura (assim que volta), gerar pacote | `status`, `doctor`, `logs`; reinicia o serviço do banco do ERP quando é dele | banco fora |
| Disco do banco cheio | Vê pelo disco (063) enquanto o banco aceita leitura; age: retenção, analisar | Vê espaço e desgaste; libera espaço em arquivos do próprio ERP | `disk`; orienta | disco cheio |
| Python fora | Vê pela saúde (componente python); execuções falham com mensagem | Vê e reinicia o pool | `doctor` | (laço de quedas) |
| Aplicação principal em laço de quedas | Cai | Vê o motivo e as tentativas; para a aplicação | `logs`, `rollback` | laço de quedas |
| Memória alta da máquina virtual | Vê pelo núcleo (062) | Vê; drena o nó | `status` | (nó que não sobe) |
| Rede / outro nó | Vê os nós; drena | Vê os nós que alcança | `status` | nó que não sobe |
| Réplica atrasada | Vê pela saúde; troca de primário (alto) | Aponta para o novo primário | `doctor` | réplica atrasada |
| Certificado ou segredo vencendo | Vê pelas verificações; gira (alto) | — | — | certificado vencido |
| Fila de integração parada | Vê; reprocessa, pausa a entrada | — | — | fila parada |
| Servidor reiniciou / máquina virtual não sobe | — | — | `status`, `doctor`, `logs`, `restore-test` | nó que não sobe |

## 4. Modelo de ameaças

| Ameaça | Defesa |
|---|---|
| Ação técnica como porta dos fundos | Só ações do catálogo, cada uma uma função fixa do núcleo; nenhum campo de código, comando do sistema ou SQL que grava (RNF-077-02) |
| Uma pessoa sozinha faz algo irreversível | Risco alto pede outra pessoa (aprovação na Central; segundo guardião no socorro e no `ana-ctl`). A empresa só endurece. A API segue a mesma regra |
| SQL do console usado para ler dado sigiloso | Papel sem escrita, `READ ONLY`, limites de tempo e linhas, mascaramento pela classificação (068); cada consulta registrada |
| Repetir uma aprovação antiga | O pedido de ação tem prazo e os parâmetros congelados; a aprovação vale para aquele pedido, uma vez |
| Alguém alcança a porta do socorro (fase 2) | Escuta só em localhost e na rede administrativa declarada, HTTPS; login normal com o banco de pé; sem banco, só guardiões |
| Um guardião sozinho (fase 2) | Entra e vê; risco alto pede o segundo guardião no próprio aparelho |
| Arquivo de chaves copiado (fase 2) | Guarda só a parte pública das chaves de acesso; o código de uso único fica cifrado com a chave do nó, que não está no arquivo; giro pela Central invalida as cópias |
| Registro local adulterado (fase 2) | Encadeado (cada linha com o resumo da anterior), conferido antes de entrar na auditoria; falha vira alerta e pendência |
| Mudança temporária esquecida | Volta sozinha no prazo, conferida também ao subir o nó |
| Modo somente leitura burlado | Aplicado no executor (transação `READ ONLY`) e na API, não só na tela |

## 5. Desenho OTP (fixado para a fase 2)
- `ana_rescue` é uma aplicação própria na release, iniciada **antes** de `ana` e com `type permanent`; `ana` passa
  a `transient` controlada pelo socorro (reinício com limite e recuo exponencial, motivo da queda guardado).
- Limites do socorro: um supervisor com poucos filhos, memória do processo HTTP limitada (`max_heap_size`),
  conexões só as próprias (uma de diagnóstico ao banco, curta, papel somente leitura).
- O anel de registros (`ana_log_ring`, fase 1) e a fotografia da saúde ficam em processos do socorro, para
  sobreviver à queda da principal.

## 6. Ordem das tarefas da fase 1
1. **T-077-01 + T-077-02** Catálogo de ações, executor, risco e permissão, registro; rotas atuais pelo executor.
2. **T-077-04** Catálogo de parâmetros, escopo, versões, mudança temporária.
3. **T-077-05** Console de diagnóstico e o anel de registros.
4. **T-077-07** Modos de operação.
5. **T-077-06** Roteiros e executor.
6. **T-077-03** Central técnica (junta tudo), medições.

## 7. Medições de referência (na bateria)
- **Aba Agora:** com 10 mil eventos de saúde e alertas no período, até 1 s (p95). **Medido na bateria (#99,
  28/11/2026): p95 de 2 ms** — a aba lê o estado da memória e só os incidentes abertos, nunca o histórico.
- **Ociosa:** a Central e os modos não fazem consultas nem gravações além das medições que já existem — o teste de
  escrita ociosa da spec 063 continua passando sem novo orçamento.
- **Modo somente leitura:** custo zero por requisição (termo persistente), medido no teste do CA-077-08.

## 8. Decisões tomadas aqui
- Nenhum parâmetro tem risco alto como mínimo do produto (o mais alto é médio): baixar uma retenção só apaga na
  próxima limpeza e pode ser desfeito antes. A empresa torna alto o que quiser, e aí vale a segunda pessoa também
  pela tela antiga de Parâmetros.
- O plantão (um grupo das políticas técnicas ou do modo manutenção) vê a Central técnica no Estúdio sem ser
  administrador; Parâmetros e Console seguem só para administradores.
- O catálogo de ações é dado, mas cada código aponta para uma função de um mapa fixo do núcleo: extensão de ação
  por pacote (D5) fica para quando o portão da 064 revisar código do núcleo — na fase 1, só ações do produto.
- Escopos de parâmetro na fase 1: produto (padrão), instalação e nó. "Empresa" entra quando houver parâmetro técnico
  que dependa dela.
- O SQL livre do console reaproveita o papel `ana_read` e a rota de consulta de hoje, com os limites novos; nada de
  um segundo caminho ao banco.
- O anel de registros nasce na fase 1 (console) e é reaproveitado pelo socorro.
