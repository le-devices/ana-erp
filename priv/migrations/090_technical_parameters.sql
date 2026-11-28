-- 090 — Technical parameters (spec 077, T-077-04, D9; plan §2.2).
--
-- The catalog adds to each runtime setting (ana_settings: type, range, default and environment variable stay there,
-- one source) what a person needs to change it well: what it is in Portuguese, when to change it, when it takes
-- effect, its risk and its scopes. A value may be set for the installation (ana_system.setting, as before) or for one
-- node (technical.parameter_node); the most specific wins and the screen says where the value in use came from.
-- Every change is a version with its reason; a temporary change goes back by itself when it expires.
CREATE TABLE technical.parameter (
    key            text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    label          text NOT NULL CHECK (length(btrim(label)) >= 3),
    when_to_change text NOT NULL CHECK (length(btrim(when_to_change)) >= 3),
    applies        text NOT NULL CHECK (applies IN ('now', 'next_run', 'restart')),
    risk           text NOT NULL CHECK (risk IN ('low', 'medium', 'high')),   -- the product's minimum
    company_risk   text CHECK (company_risk IN ('low', 'medium', 'high')),    -- stricter only (checked in the core)
    area           text NOT NULL CHECK (area ~ '^[a-z]+$'),
    scopes         text[] NOT NULL DEFAULT '{installation}'
                   CHECK (scopes <@ ARRAY['installation', 'node'] AND cardinality(scopes) >= 1),
    sequence       integer NOT NULL DEFAULT 100
);

-- Values only the server sets (the screen shows them, where they come from and how to change them; secrets only as
-- "defined / not defined").
CREATE TABLE technical.server_parameter (
    env            text PRIMARY KEY CHECK (env ~ '^ANA_[A-Z0-9_]+$'),
    label          text NOT NULL,
    secret         boolean NOT NULL DEFAULT false
);

CREATE TABLE technical.parameter_node (
    key            text NOT NULL REFERENCES technical.parameter(key) ON DELETE CASCADE,
    node           text NOT NULL CHECK (length(node) BETWEEN 1 AND 200),
    value          jsonb NOT NULL,
    updated_by     text NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (key, node)
);

-- The history: each change with its reason; "before" is the value at that scope (null: none — the default applied).
CREATE TABLE technical.parameter_version (
    id             bigserial PRIMARY KEY,
    key            text NOT NULL,
    scope          text NOT NULL CHECK (scope IN ('installation', 'node')),
    node           text,
    before         jsonb,
    after          jsonb,                                        -- null: back to the default
    reason         text,
    kind           text NOT NULL DEFAULT 'set' CHECK (kind IN ('set', 'reset', 'restore', 'expired', 'import')),
    set_by         text NOT NULL,
    set_at         timestamptz NOT NULL DEFAULT now(),
    until          timestamptz,                                  -- a temporary change goes back then
    reverted_at    timestamptz,
    CHECK ((scope = 'node') = (node IS NOT NULL))
);
CREATE INDEX parameter_version_key_idx ON technical.parameter_version (key, id DESC);
CREATE INDEX parameter_version_until_idx ON technical.parameter_version (until) WHERE until IS NOT NULL AND reverted_at IS NULL;

INSERT INTO technical.parameter (key, label, when_to_change, applies, risk, area, scopes, sequence) VALUES
('session_hours', 'Validade da sessão de usuário (horas)', 'Pela política de segurança da empresa; afrouxar pede motivo.', 'next_run', 'medium', 'acesso', '{installation}', 10),
('exec_timeout_ms', 'Tempo máximo de uma execução (ms)', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation}', 20),
('sql_timeout_ms', 'Tempo máximo de um comando SQL de programa (ms)', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation}', 30),
('lock_timeout_ms', 'Espera máxima por travas no banco (ms)', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation}', 40),
('exec_max', 'Execuções simultâneas permitidas', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation,node}', 50),
('debug_max', 'Depurações simultâneas permitidas', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation,node}', 60),
('debug_idle_ms', 'Ociosidade máxima de uma depuração pausada (ms)', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation,node}', 70),
('output_max_kb', 'Saída máxima por execução (KiB)', 'Quando as rotinas da empresa precisarem de outro limite; o padrão serve à maioria.', 'now', 'medium', 'execucao', '{installation}', 80),
('analytics_interval_s', 'Intervalo de atualização analítica (s)', 'Para ver mais (ou menos) detalhe de desempenho; mais detalhe grava mais.', 'next_run', 'low', 'observacao', '{installation,node}', 90),
('password_min_length', 'Tamanho mínimo de senha', 'Pela política de segurança da empresa; afrouxar pede motivo.', 'now', 'medium', 'acesso', '{installation}', 100),
('max_login_failures', 'Falhas de login seguidas antes do bloqueio', 'Pela política de segurança da empresa; afrouxar pede motivo.', 'now', 'medium', 'acesso', '{installation}', 110),
('lockout_minutes', 'Duração do bloqueio por falhas de login (min)', 'Pela política de segurança da empresa; afrouxar pede motivo.', 'now', 'medium', 'acesso', '{installation}', 120),
('default_cpu_ms', 'CPU padrão por execução (ms)', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 130),
('default_memory_mb', 'Memória padrão por execução (MiB)', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 140),
('default_max_rows', 'Linhas máximas por consulta, padrão (0 = sem limite)', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 150),
('default_max_sql', 'Comandos SQL por execução, padrão (0 = sem limite)', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 160),
('default_max_concurrent', 'Execuções simultâneas por programa, padrão (0 = sem limite)', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 170),
('ceiling_timeout_ms', 'Teto: tempo de execução (ms)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 180),
('ceiling_cpu_ms', 'Teto: CPU por execução (ms)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 190),
('ceiling_memory_mb', 'Teto: memória por execução (MiB)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 200),
('ceiling_sql_timeout_ms', 'Teto: tempo por comando SQL (ms)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 210),
('ceiling_lock_timeout_ms', 'Teto: espera por travas (ms)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 220),
('ceiling_output_kb', 'Teto: saída por execução (KiB)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 230),
('ceiling_max_rows', 'Teto: linhas por consulta (0 = sem teto)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 240),
('ceiling_max_sql', 'Teto: comandos SQL por execução (0 = sem teto)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 250),
('ceiling_max_concurrent', 'Teto: execuções simultâneas por programa (0 = sem teto)', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 260),
('default_max_parallel_parts', 'Partes paralelas simultâneas por chamada, padrão', 'Quando muitas rotinas legítimas batem no limite padrão (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 270),
('ceiling_max_parallel_parts', 'Teto: partes paralelas simultâneas por chamada', 'O teto vale para todos, inclusive administradores: suba só com motivo medido.', 'now', 'medium', 'limites', '{installation}', 280),
('user_max_concurrent', 'Execuções simultâneas por usuário (0 = sem limite)', 'Quando uma pessoa legítima bate na cota (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 290),
('user_runs_per_minute', 'Execuções por minuto por usuário (0 = sem limite)', 'Quando uma pessoa legítima bate na cota (veja Consumo).', 'now', 'medium', 'limites', '{installation}', 300),
('retention_access_days', 'Retenção: acessos e comandos SQL (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 310),
('retention_login_days', 'Retenção: logins (dias, mínimo 90)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 320),
('retention_execution_days', 'Retenção: registro das execuções (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 330),
('retention_payload_days', 'Retenção: conteúdo das execuções — parâmetros, resultado, saída, stack traces (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 340),
('retention_task_days', 'Retenção: tarefas internas (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 350),
('retention_scheduler_days', 'Retenção: ocorrências e avisos do agendamento (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 360),
('retention_admin_log_days', 'Retenção: alterações administrativas (dias, mínimo 365)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 370),
('retention_hour', 'Hora do expurgo diário (fuso do cliente)', 'Para a limpeza rodar num horário de pouco uso.', 'next_run', 'low', 'retencao', '{installation}', 380),
('retention_trace_days', 'Retenção: rastros de execução e perfis (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 390),
('retention_observability_days', 'Retenção: eventos de saúde e amostras de métricas (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 400),
('retention_integration_days', 'Retenção: chamadas e mensagens de integração concluídas (dias)', 'Diminuir apaga mais cedo (na próxima limpeza, sem volta); aumentar guarda mais e ocupa mais disco.', 'next_run', 'medium', 'retencao', '{installation}', 410),
('files_max_file_mb', 'Repositório: tamanho máximo de um arquivo (MB)', 'Quando a empresa precisa guardar arquivos maiores.', 'now', 'medium', 'arquivos', '{installation}', 420),
('slow_sql_ms', 'Comando SQL lento a partir de (ms): registra o plano e gera dicas', 'Para ver mais (ou menos) detalhe de desempenho; mais detalhe grava mais.', 'now', 'low', 'observacao', '{installation,node}', 430),
('trace_slow_ms', 'Execução lenta a partir de (ms): sempre guarda o rastro', 'Para ver mais (ou menos) detalhe de desempenho; mais detalhe grava mais.', 'now', 'low', 'observacao', '{installation,node}', 440),
('trace_sample_pct', 'Rastros guardados das demais execuções (%)', 'Para ver mais (ou menos) detalhe de desempenho; mais detalhe grava mais.', 'now', 'low', 'observacao', '{installation,node}', 450),
('n_plus_one_threshold', 'Mesmo comando SQL repetido numa execução a partir de (vezes): dica N+1', 'Para ver mais (ou menos) detalhe de desempenho; mais detalhe grava mais.', 'now', 'low', 'observacao', '{installation}', 460),
('checks_backup_max_hours', 'Verificações: idade máxima da cópia completa do banco (horas)', 'Para ajustar quando uma verificação avisa.', 'next_run', 'low', 'verificacoes', '{installation}', 470),
('checks_restore_max_days', 'Verificações: idade máxima do último teste de restauração (dias)', 'Para ajustar quando uma verificação avisa.', 'next_run', 'low', 'verificacoes', '{installation}', 480),
('checks_key_max_days', 'Verificações: idade máxima de chave de API sem validade (dias)', 'Para ajustar quando uma verificação avisa.', 'next_run', 'low', 'verificacoes', '{installation}', 490),
('checks_perf_factor_pct', 'Verificações: piora de desempenho a partir de (% da linha de base)', 'Para ajustar quando uma verificação avisa.', 'next_run', 'low', 'verificacoes', '{installation}', 500),
('transport_required', 'Produção: programas só mudam por pacote de transporte (1 = sim)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 510),
('transport_four_eyes', 'Transporte: quem recebeu o pacote não pode importá-lo (1 = sim)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 520),
('quality_gate_level', 'Portão de qualidade: severidade que bloqueia o transporte (0 informação, 1 atenção, 2 sério, 3 crítico)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 530),
('quality_gate_required', 'Portão de qualidade: recusar pacote de programas sem relatório do portão verde (1 = sim)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 540),
('quality_exemption_max_days', 'Portão de qualidade: prazo máximo de uma isenção (dias)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 550),
('quality_tests_required', 'Portão de qualidade: programa que grava precisa de ao menos um teste passando (1 = sim)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 560),
('quality_perf_sql_pct', 'Portão de qualidade: piora de comandos SQL de um teste, em relação à versão anterior, que vira achado (%)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 570),
('quality_perf_time_pct', 'Portão de qualidade: piora de CPU de um teste (acima de 50 ms), em relação à versão anterior, que vira achado (%)', 'Pela política de mudanças da empresa (portão de qualidade e transportes).', 'now', 'medium', 'mudancas', '{installation}', 580),
('outbound_blocked', 'Bloquear chamadas a sistemas externos (instância de testes com dados copiados)', 'Ligado, nada sai para fora (e-mails, conectores): só em cópia de teste.', 'now', 'medium', 'integracoes', '{installation}', 590),
('api_breaker_failures', 'API pública: falhas técnicas (erro interno, tempo esgotado) em 2 min que suspendem o cliente', 'Quando clientes legítimos da API são suspensos cedo demais, ou tarde demais.', 'now', 'medium', 'api', '{installation}', 600),
('api_breaker_ratio', 'API pública: proporção mínima de falhas nas chamadas do cliente para suspender (%)', 'Quando clientes legítimos da API são suspensos cedo demais, ou tarde demais.', 'now', 'medium', 'api', '{installation}', 610),
('api_breaker_open_s', 'API pública: duração da suspensão do cliente (s)', 'Quando clientes legítimos da API são suspensos cedo demais, ou tarde demais.', 'now', 'medium', 'api', '{installation}', 620),
('disk_tbw_tb', 'Disco: resistência do SSD informada pelo fabricante (TBW, em TB; 0 = não informada)', 'Ao trocar o disco do servidor ou quando o ana-ctl não lê o desgaste.', 'now', 'low', 'disco', '{installation,node}', 630),
('disk_used_pct', 'Disco: desgaste já usado do SSD (%), quando o ana-ctl não consegue ler', 'Ao trocar o disco do servidor ou quando o ana-ctl não lê o desgaste.', 'now', 'low', 'disco', '{installation,node}', 640);

INSERT INTO technical.server_parameter (env, label, secret) VALUES
('ANA_DB_HOST', 'Banco: servidor', false),
('ANA_DB_PORT', 'Banco: porta', false),
('ANA_DB_NAME', 'Banco: nome', false),
('ANA_DB_USER', 'Banco: usuário', false),
('ANA_DB_PASSWORD', 'Banco: senha', true),
('ANA_DB_POOL', 'Banco: conexões do núcleo', false),
('ANA_DB_POOL_EXEC', 'Banco: conexões dos programas', false),
('ANA_DB_READ_HOSTS', 'Banco: réplicas de leitura', false),
('ANA_HTTP_PORT', 'Porta HTTP do nó', false),
('ANA_COOKIE', 'Segredo do grupo de nós (cookie)', true),
('ANA_MASTER_KEY', 'Chave mestra do cofre', true),
('ANA_ADMIN_PASSWORD', 'Senha inicial do administrador', true),
('ANA_INSTANCE', 'Ambiente (produção, teste…)', false),
('ANA_INSTANCE_NAME', 'Nome do ambiente', false),
('ANA_TIMEZONE', 'Fuso horário da empresa', false),
('ANA_PY_PREWARM', 'Python: processos prontos', false),
('ANA_PY_MEMORY_MB', 'Python: memória por processo (padrão)', false),
('ANA_PY_CPU_S', 'Python: CPU por processo', false),
('ANA_FILES_DIR', 'Arquivos: pasta', false),
('ANA_LICENSE_FILE', 'Licença: arquivo', false),
('ANA_LOG_FORMAT', 'Registros: formato', false),
('ANA_TRUSTED_PROXIES', 'Proxies confiáveis', false),
('ANA_PUBLIC_URL', 'Endereço público', false),
('ANA_PUBLIC_MODE', 'Modo público da API', false),
('ANA_HTTP_MAX_BODY', 'Tamanho máximo do corpo HTTP', false),
('ANA_DRAIN_DELAY_MS', 'Drenagem: espera pelo balanceador (ms)', false),
('ANA_DRAIN_TIMEOUT_MS', 'Drenagem: espera pelas execuções (ms)', false),
('ANA_BREAKER_OPEN_MS', 'Disjuntor de sistemas remotos: tempo aberto (ms)', false),
('ANA_BPM_SWEEP_MS', 'Processos: intervalo da varredura (ms)', false)
;

-- The changes so far (ana_system.setting) become the first version, so the screen shows "changed" with who and when.
INSERT INTO technical.parameter_version (key, scope, before, after, reason, set_by, set_at)
SELECT s.key, 'installation', NULL, s.value, 'valor que já estava em uso', COALESCE(s.updated_by, 'ana'), COALESCE(s.updated_at, now())
  FROM ana_system.setting s JOIN technical.parameter p ON p.key = s.key;

-- A parameter change is a technical action too: the ceremony of the parameter's risk (the higher of the two).
INSERT INTO technical.action (code, name, description, params, effect, impact, risk, success, area, sequence) VALUES
('parameter.set', 'Mudar um parâmetro técnico', 'Muda o valor de um parâmetro para a instalação ou para um nó, com motivo',
 '[{"name":"key","type":"text","label":"parâmetro","required":true},
   {"name":"value","type":"integer","label":"valor (vazio = volta ao padrão)","required":false},
   {"name":"scope","type":"choice","label":"escopo","required":false,"choices":[["installation","instalação"],["node","nó"]]},
   {"name":"node","type":"text","label":"nó","required":false},
   {"name":"minutes","type":"integer","label":"só por (minutos)","required":false},
   {"name":"reason","type":"text","label":"motivo","required":true}]',
 'O parâmetro passa a ter o novo valor no escopo escolhido', 'Depende do parâmetro: veja "quando vale"', 'low',
 'O valor em uso é o novo', 'parametros', 80);
