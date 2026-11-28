-- 093 — Guided runbooks (spec 077, T-077-06, D8, RF-077-07; plan §2.4).
--
-- A runbook is a sequence of steps for a known situation. A step is a check (a fixed check of the core, with the
-- expected result: it runs by itself), an action of the catalog (with its ceremony: the person decides) or an
-- instruction (the person does it and confirms). Each says what success is, what to do if it fails (another step or
-- stop and ask for help), the expected time and the layers where it exists (central, rescue, ctl). The product ships
-- its runbooks as versioned data; the company and the partner may add theirs.
CREATE TABLE technical.runbook (
    code        text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    version     integer NOT NULL DEFAULT 1 CHECK (version > 0),
    name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 120),
    when_to_use text NOT NULL CHECK (length(btrim(when_to_use)) >= 3),
    -- [{kind: check|action|instruction, text, check?, expect?: {op, value}, action?, params?, success, on_fail?:
    --   {goto: n} | "stop", minutes, layers: [central, rescue, ctl]}]
    steps       jsonb NOT NULL CHECK (jsonb_typeof(steps) = 'array' AND jsonb_array_length(steps) BETWEEN 1 AND 50),
    product     boolean NOT NULL DEFAULT false,
    active      boolean NOT NULL DEFAULT true,
    created_by  text NOT NULL DEFAULT 'ana',
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (code, version)
);

CREATE TABLE technical.runbook_run (
    id          bigserial PRIMARY KEY,
    code        text NOT NULL,
    version     integer NOT NULL,
    status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'paused', 'waiting', 'done', 'stopped')),
    step        integer NOT NULL DEFAULT 1,                 -- the step now (1-based)
    owner       text NOT NULL,                              -- who is conducting it now (may be handed over)
    started_by  text NOT NULL,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    pending_action bigint,                                  -- a high-risk step waiting for the second person
    log         jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(log) = 'array'),
    FOREIGN KEY (code, version) REFERENCES technical.runbook (code, version)
);
CREATE INDEX runbook_run_open_idx ON technical.runbook_run (status) WHERE status IN ('running', 'paused', 'waiting');

INSERT INTO technical.runbook (code, name, when_to_use, steps, product) VALUES
('disk_full', 'Disco cheio', 'O espaço livre do disco está acabando (alerta de disco ou item da Central)',
 '[{"kind":"check","text":"Conferir o espaço livre do disco do nó","check":"disk_free_pct","expect":{"op":"<","value":15},
    "success":"O disco está mesmo com pouco espaço","on_fail":"stop","minutes":1,"layers":["central","rescue","ctl"]},
   {"kind":"check","text":"Conferir o tamanho do banco","check":"db_size_mb","success":"Tamanho anotado","minutes":1,
    "layers":["central","rescue"]},
   {"kind":"action","text":"Liberar espaço pela retenção (apaga só o que passou do prazo de guarda)","action":"retention.purge",
    "success":"A limpeza terminou","minutes":5,"layers":["central","rescue"]},
   {"kind":"check","text":"Conferir de novo o espaço livre","check":"disk_free_pct","expect":{"op":">=","value":15},
    "success":"O disco voltou a ter folga","on_fail":{"goto":5},"minutes":1,"layers":["central","rescue","ctl"]},
   {"kind":"instruction","text":"Ainda sem folga: aumente o disco do servidor ou reduza os prazos de retenção (Parâmetros → retenção) e fale com o suporte com o pacote de diagnóstico",
    "success":"Providência tomada","minutes":30,"layers":["central","rescue","ctl"]}]', true),
('database_down', 'Banco fora', 'O ERP não alcança o banco de dados',
 '[{"kind":"check","text":"Conferir se o banco responde","check":"db_reachable","expect":{"op":"=","value":false},
    "success":"O banco está mesmo fora","on_fail":"stop","minutes":1,"layers":["rescue","ctl"]},
   {"kind":"instruction","text":"No servidor do banco: confira energia, rede e o serviço (ana-ctl status e ana-ctl doctor)",
    "success":"Causa encontrada","minutes":10,"layers":["rescue","ctl"]},
   {"kind":"check","text":"Conferir se o banco voltou","check":"db_reachable","expect":{"op":"=","value":true},
    "success":"O banco voltou","on_fail":{"goto":2},"minutes":1,"layers":["central","rescue","ctl"]},
   {"kind":"check","text":"Conferir a saúde do ERP","check":"health_not_green","expect":{"op":"=","value":0},
    "success":"Tudo verde","minutes":1,"layers":["central","rescue"]}]', true),
('replica_lagging', 'Réplica atrasada', 'Uma réplica do banco está atrasada em relação ao primário',
 '[{"kind":"check","text":"Medir o atraso das réplicas","check":"replica_lag_s","expect":{"op":">","value":30},
    "success":"Há réplica atrasada","on_fail":"stop","minutes":1,"layers":["central","rescue"]},
   {"kind":"instruction","text":"Veja no console a consulta pronta Réplicas e confira a rede entre os servidores do banco",
    "success":"Causa anotada","minutes":10,"layers":["central"]},
   {"kind":"check","text":"Medir de novo","check":"replica_lag_s","expect":{"op":"<=","value":30},
    "success":"A réplica alcançou o primário","on_fail":{"goto":2},"minutes":5,"layers":["central","rescue"]}]', true),
('node_down', 'Nó que não sobe', 'Um nó do ERP não volta a ficar pronto',
 '[{"kind":"check","text":"Contar os nós prontos","check":"nodes_ready","success":"Contagem anotada","minutes":1,
    "layers":["central","rescue"]},
   {"kind":"check","text":"Conferir o Python dos programas neste nó","check":"python_ready","expect":{"op":">","value":0},
    "success":"Python pronto","on_fail":{"goto":4},"minutes":1,"layers":["central","rescue"]},
   {"kind":"check","text":"Conferir a saúde dos componentes","check":"health_not_green","expect":{"op":"=","value":0},
    "success":"Componentes verdes","on_fail":{"goto":4},"minutes":1,"layers":["central","rescue"]},
   {"kind":"instruction","text":"No servidor do nó: ana-ctl status, ana-ctl logs e ana-ctl doctor; se uma atualização recente causou a falha, ana-ctl rollback",
    "success":"O nó voltou","minutes":20,"layers":["rescue","ctl"]}]', true),
('crash_loop', 'Laço de quedas', 'A aplicação cai e volta seguidamente',
 '[{"kind":"check","text":"Contar as quedas de subsistemas na última hora","check":"restarts_last_hour","expect":{"op":">","value":3},
    "success":"Há quedas repetidas","on_fail":"stop","minutes":1,"layers":["central","rescue"]},
   {"kind":"instruction","text":"Abra os registros do nó no console (nível erro) e anote o subsistema que cai",
    "success":"Subsistema anotado","minutes":5,"layers":["central","rescue"]},
   {"kind":"action","text":"Ligar o modo somente leitura enquanto investiga","action":"mode.read_only",
    "params":{"message":"instabilidade em análise: consultas funcionam"},"success":"Modo ligado","minutes":1,"layers":["central","rescue"]},
   {"kind":"instruction","text":"Corrija a causa (configuração, integração ou atualização) ou acione o suporte com o pacote de diagnóstico",
    "success":"Causa tratada","minutes":30,"layers":["central","rescue","ctl"]},
   {"kind":"action","text":"Voltar ao funcionamento normal","action":"mode.normal","success":"Normal","minutes":1,
    "layers":["central","rescue"]}]', true),
('expiring_credentials', 'Licença, segredos ou certificados vencendo', 'Uma licença, chave ou segredo está perto de vencer',
 '[{"kind":"check","text":"Dias até a licença vencer","check":"license_days_left","expect":{"op":">","value":30},
    "success":"A licença tem folga","on_fail":{"goto":3},"minutes":1,"layers":["central"]},
   {"kind":"action","text":"Rodar as verificações de segurança (chaves e segredos antigos)","action":"checks.run",
    "params":{"category":"security"},"success":"Verificações atualizadas","minutes":2,"layers":["central"]},
   {"kind":"instruction","text":"Renove a licença (Administração → Licença) ou gire os segredos indicados nas Verificações",
    "success":"Renovado","minutes":15,"layers":["central"]}]', true),
('stuck_queue', 'Fila de integração parada', 'Mensagens de integração não saem ou não entram',
 '[{"kind":"check","text":"Contar mensagens paradas há mais de 15 minutos","check":"queue_stuck","expect":{"op":">","value":0},
    "success":"Há mensagens paradas","on_fail":"stop","minutes":1,"layers":["central","rescue"]},
   {"kind":"instruction","text":"Em Integrações, veja o erro das mensagens e o conector; corrija a configuração ou o sistema do outro lado",
    "success":"Causa tratada","minutes":15,"layers":["central"]},
   {"kind":"check","text":"Contar de novo","check":"queue_stuck","expect":{"op":"=","value":0},
    "success":"A fila andou","on_fail":{"goto":2},"minutes":5,"layers":["central","rescue"]}]', true);
