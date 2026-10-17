-- 039 — BPM (spec 039): process catalog, models with versions, cases, tasks, events, simulations.
--
-- The model is canonical JSON (BPMN meaning). Navigation of cases runs only in the core's engine
-- (ana_bpm, on the leader, under a lock of the case); programs and screens only complete tasks.
-- The esteiras (spec 030) run in the same engine and appear in the catalog as processes.

CREATE SCHEMA bpm;

-- ---------------------------------------------------------------- catalog (RF-039-01)
CREATE TABLE bpm.process (
    code         text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
    name         text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
    parent_code  text REFERENCES bpm.process(code) ON UPDATE CASCADE ON DELETE SET NULL,
    level        text NOT NULL DEFAULT 'process' CHECK (level IN ('chain', 'process', 'subprocess')),
    owner        text,
    objective    text NOT NULL DEFAULT '',
    trigger_text text NOT NULL DEFAULT '',
    outcome      text NOT NULL DEFAULT '',
    kpi          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(kpi) = 'object'),   -- targets: cycle_hours, cost, on_time_pct
    tags         text[] NOT NULL DEFAULT '{}',
    position     integer NOT NULL DEFAULT 0,
    flow_code    text UNIQUE REFERENCES flow.definition(code),                       -- an esteira shown as a process
    active       boolean NOT NULL DEFAULT true,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   text,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_code IS DISTINCT FROM code)
);
CREATE INDEX process_parent_idx ON bpm.process (parent_code, position);

-- RF-039-06: draft → published → retired; a published model never changes.
CREATE TABLE bpm.version (
    process_code text NOT NULL REFERENCES bpm.process(code) ON UPDATE CASCADE ON DELETE CASCADE,
    version      integer NOT NULL CHECK (version > 0),
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'retired')),
    model        jsonb NOT NULL CHECK (jsonb_typeof(model) = 'object'),
    compiled     jsonb,                                   -- reachability, start trigger… (set at publication)
    sim          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(sim) = 'object'),
    comment      text NOT NULL DEFAULT '',
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    published_by text,
    published_at timestamptz,
    retired_at   timestamptz,
    PRIMARY KEY (process_code, version),
    CHECK ((status = 'draft') = (published_at IS NULL))
);
CREATE UNIQUE INDEX version_one_published ON bpm.version (process_code) WHERE status = 'published';
CREATE UNIQUE INDEX version_one_draft ON bpm.version (process_code) WHERE status = 'draft';
CREATE INDEX version_starts_idx ON bpm.version ((compiled ->> 'starts_on')) WHERE status = 'published';

CREATE FUNCTION bpm.version_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'draft' AND (NEW.model IS DISTINCT FROM OLD.model OR NEW.compiled IS DISTINCT FROM OLD.compiled) THEN
        RAISE EXCEPTION 'VERSION_PUBLISHED: versão publicada não se altera; edite o rascunho e publique uma nova versão'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
        RAISE EXCEPTION 'VERSION_RETIRED: versão aposentada não volta' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER version_immutable BEFORE UPDATE ON bpm.version FOR EACH ROW EXECUTE FUNCTION bpm.version_immutable();

-- ---------------------------------------------------------------- documents and facts of the ERP (P17)
-- What a case can follow (its facts become case data) and the facts a model can wait for or test.
CREATE TABLE bpm.document (
    entity     text PRIMARY KEY CHECK (entity ~ '^[a-z][a-z0-9_]{1,40}$'),
    label      text NOT NULL,
    facts_sql  text NOT NULL,                 -- $1 = document key (text) → one row
    cancel_sql text,                          -- $1 → true when cancelled
    program    text                           -- program that opens the document (docs.view kind)
);
CREATE TABLE bpm.fact (
    code   text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    entity text NOT NULL REFERENCES bpm.document(entity),
    name   text NOT NULL,
    sql    text NOT NULL                      -- $1 = document key → true when the fact happened
);

INSERT INTO bpm.document (entity, label, facts_sql, cancel_sql, program)
SELECT CASE code WHEN 'sales' THEN 'sales_order' WHEN 'purchase' THEN 'purchase_request' WHEN 'field' THEN 'service_order'
                 ELSE 'work_order' END, document, facts_sql, cancel_sql,
       CASE code WHEN 'sales' THEN 'order' WHEN 'purchase' THEN 'purchase_request' WHEN 'field' THEN 'service_order'
                 ELSE 'work_order' END
FROM flow.definition;
INSERT INTO bpm.document (entity, label, facts_sql, cancel_sql, program) VALUES
    ('project', 'projeto',
     'SELECT p.code, p.name, p.status, p.customer_id, c.name AS customer, p.manager, p.billing, p.budget_amount AS budget '
     'FROM projects.project p LEFT JOIN base.party c ON c.id = p.customer_id WHERE p.code = $1',
     'SELECT status = ''closed'' AND false FROM projects.project WHERE code = $1', 'project'),
    ('none', 'sem documento (processo avulso)', 'SELECT $1::text AS key', NULL, NULL);

INSERT INTO bpm.fact (code, entity, name, sql)
SELECT d.entity || '.' || s.code, d.entity, s.name || ' concluída', s.done_sql
FROM flow.step s JOIN flow.definition f ON f.code = s.flow_code
JOIN bpm.document d ON d.label = f.document;

-- ---------------------------------------------------------------- execution (RF-039-11..14)
CREATE TABLE bpm.case (
    id            bigserial PRIMARY KEY,
    process_code  text NOT NULL,
    version       integer NOT NULL,
    status        text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'waiting', 'failed', 'done', 'cancelled')),
    doc_entity    text NOT NULL DEFAULT 'none' REFERENCES bpm.document(entity),
    doc_key       text,
    title         text NOT NULL,
    data          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(data) = 'object'),
    parent_task   bigint,                                     -- started by a subprocess task
    started_by    text NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    reason        text,
    FOREIGN KEY (process_code, version) REFERENCES bpm.version(process_code, version)
);
CREATE UNIQUE INDEX case_document_once ON bpm.case (process_code, doc_entity, doc_key)
    WHERE doc_key IS NOT NULL AND parent_task IS NULL AND status IN ('running', 'waiting', 'failed');
CREATE INDEX case_open_idx ON bpm.case (process_code, status) WHERE status IN ('running', 'waiting', 'failed');
CREATE INDEX case_started_brin ON bpm.case USING brin (started_at);

-- A token marks where the case is; a task is the work of one token on one element.
CREATE TABLE bpm.token (
    id         bigserial PRIMARY KEY,
    case_id    bigint NOT NULL REFERENCES bpm.case(id) ON DELETE CASCADE,
    node       text NOT NULL,
    status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'joining', 'done', 'cancelled')),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX token_case_idx ON bpm.token (case_id) WHERE status IN ('active', 'joining');

CREATE TABLE bpm.task (
    id           bigserial PRIMARY KEY,
    case_id      bigint NOT NULL REFERENCES bpm.case(id) ON DELETE CASCADE,
    token_id     bigint NOT NULL REFERENCES bpm.token(id) ON DELETE CASCADE,
    node         text NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('human', 'approval', 'auto', 'send', 'rule', 'timer', 'fact', 'subprocess')),
    name         text NOT NULL,
    status       text NOT NULL DEFAULT 'ready'
                 CHECK (status IN ('ready', 'running', 'waiting', 'done', 'failed', 'cancelled')),
    advanced     boolean NOT NULL DEFAULT false,              -- the engine moved the case on after it finished
    assignee     text,
    role         text,
    group_name   text,
    program      text,
    params       jsonb NOT NULL DEFAULT '{}',
    instructions text NOT NULL DEFAULT '',
    priority     integer NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    due_at       timestamptz,
    warn_at      timestamptz,
    warned       boolean NOT NULL DEFAULT false,
    escalated    boolean NOT NULL DEFAULT false,
    attempts     integer NOT NULL DEFAULT 0,
    next_at      timestamptz,
    lease_until  timestamptz,
    execution_id uuid,
    child_case   bigint,
    fact         text,                                       -- ERP fact that completes it (event, or "done when")
    escalate     jsonb,                                      -- {"to": user, "mode": notify | reassign | path}
    result       jsonb,
    error        jsonb,
    outcome      text,                                       -- e.g. approved / rejected / error / timeout
    comment      text,
    how          text CHECK (how IN ('auto', 'manual', 'outside', 'skipped', 'timeout')),
    done_by      text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    started_at   timestamptz,
    finished_at  timestamptz
);
CREATE INDEX task_due_idx ON bpm.task (next_at) WHERE status = 'ready';
CREATE INDEX task_open_idx ON bpm.task (status, assignee) WHERE status IN ('ready', 'waiting', 'running', 'failed');
CREATE INDEX task_advance_idx ON bpm.task (case_id) WHERE status IN ('done', 'failed') AND NOT advanced;
CREATE INDEX task_case_idx ON bpm.task (case_id);
CREATE INDEX task_finished_brin ON bpm.task USING brin (finished_at);

-- Every move of a case (monitoring, heat map, discovery, trail).
CREATE TABLE bpm.event (
    id      bigserial PRIMARY KEY,
    at      timestamptz NOT NULL DEFAULT now(),
    case_id bigint NOT NULL,
    node    text,
    kind    text NOT NULL CHECK (kind IN ('start', 'enter', 'done', 'skip', 'warn', 'escalate', 'error', 'retry', 'cancel',
                                          'end', 'delegate', 'claim', 'release', 'comment', 'migrate', 'wait', 'fail')),
    by      text,
    detail  jsonb
);
CREATE INDEX event_at_brin ON bpm.event USING brin (at);
CREATE INDEX event_case_idx ON bpm.event (case_id, id);

-- Notices to people (new task, about to expire, escalated).
CREATE TABLE bpm.notification (
    id         bigserial PRIMARY KEY,
    username   text NOT NULL,
    task_id    bigint,
    case_id    bigint,
    kind       text NOT NULL CHECK (kind IN ('task', 'warn', 'escalated', 'done', 'failed')),
    message    text NOT NULL,
    read       boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notification_user_idx ON bpm.notification (username, read, id DESC);

-- ---------------------------------------------------------------- simulation (RF-039-08..10)
CREATE TABLE bpm.simulation (
    id           bigserial PRIMARY KEY,
    process_code text NOT NULL REFERENCES bpm.process(code) ON UPDATE CASCADE ON DELETE CASCADE,
    version      integer NOT NULL,
    name         text NOT NULL,
    params       jsonb NOT NULL,
    result       jsonb NOT NULL,
    seed         integer NOT NULL,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX simulation_process_idx ON bpm.simulation (process_code, id DESC);

-- ---------------------------------------------------------------- business time (RF-039-13)
-- Adds working hours (Mon–Fri, 08:00–12:00 and 13:00–18:00 in the company's time zone, no holidays).
CREATE FUNCTION bpm.business_add(p_start timestamptz, p_hours numeric) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    tz text := COALESCE(NULLIF(current_setting('ana.timezone', true), ''), 'America/Sao_Paulo');
    t timestamp := (p_start AT TIME ZONE tz);
    left_min numeric := greatest(p_hours, 0) * 60;
    d date; win record; s timestamp; e timestamp; take numeric;
BEGIN
    IF left_min = 0 THEN RETURN p_start; END IF;
    d := t::date;
    FOR i IN 0..730 LOOP
        IF extract(isodow FROM d) < 6 AND NOT EXISTS (SELECT 1 FROM scheduler.holiday h WHERE h.day = d) THEN
            FOR win IN SELECT * FROM (VALUES (time '08:00', time '12:00'), (time '13:00', time '18:00')) AS w(a, b) LOOP
                s := greatest(t, d + win.a);
                e := d + win.b;
                IF s < e THEN
                    take := least(left_min, extract(epoch FROM e - s) / 60);
                    left_min := left_min - take;
                    IF left_min <= 0 THEN
                        RETURN (s + make_interval(mins => take::int)) AT TIME ZONE tz;
                    END IF;
                END IF;
            END LOOP;
        END IF;
        d := d + 1;
        t := d::timestamp;
    END LOOP;
    RETURN p_start + make_interval(hours => p_hours::int);
END $$;

-- ---------------------------------------------------------------- start by a document (RF-039-11)
-- Published, active processes whose start event follows this kind of document get a case.
CREATE FUNCTION bpm.start_document(p_entity text, p_key text, p_user text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; n integer := 0; c bigint; t bigint;
BEGIN
    FOR v IN SELECT ver.process_code, ver.version, ver.compiled, p.name FROM bpm.version ver
             JOIN bpm.process p ON p.code = ver.process_code
             WHERE ver.status = 'published' AND p.active AND p.flow_code IS NULL AND ver.compiled ->> 'starts_on' = p_entity LOOP
        INSERT INTO bpm.case (process_code, version, doc_entity, doc_key, title, started_by)
        VALUES (v.process_code, v.version, p_entity, p_key, v.name || ' — ' || p_key, p_user)
        ON CONFLICT DO NOTHING RETURNING id INTO c;
        IF c IS NOT NULL THEN
            INSERT INTO bpm.token (case_id, node) VALUES (c, v.compiled ->> 'start') RETURNING id INTO t;
            INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, advanced, how, finished_at)
            VALUES (c, t, v.compiled ->> 'start', 'rule', 'Início', 'done', false, 'auto', now());
            INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES (c, v.compiled ->> 'start', 'start', p_user,
                jsonb_build_object('document', p_entity, 'key', p_key));
            n := n + 1;
        END IF;
    END LOOP;
    IF n > 0 THEN PERFORM pg_notify('ana_bpm', 'start'); END IF;
    RETURN n;
END $$;

CREATE FUNCTION bpm.start_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM bpm.start_document(TG_ARGV[0], to_jsonb(NEW) ->> TG_ARGV[1],
                               COALESCE(NULLIF(current_setting('ana.username', true), ''), 'system'));
    RETURN NULL;
END $$;
CREATE TRIGGER bpm_start AFTER INSERT ON sales.sales_order FOR EACH ROW EXECUTE FUNCTION bpm.start_trigger('sales_order', 'number');
CREATE TRIGGER bpm_start AFTER INSERT ON supply.purchase_request FOR EACH ROW EXECUTE FUNCTION bpm.start_trigger('purchase_request', 'number');
CREATE TRIGGER bpm_start AFTER INSERT ON field.service_order FOR EACH ROW EXECUTE FUNCTION bpm.start_trigger('service_order', 'number');
CREATE TRIGGER bpm_start AFTER INSERT ON production.work_order FOR EACH ROW EXECUTE FUNCTION bpm.start_trigger('work_order', 'number');
CREATE TRIGGER bpm_start AFTER INSERT ON projects.project FOR EACH ROW EXECUTE FUNCTION bpm.start_trigger('project', 'code');

-- Tasks done by people (screens, API) wake the engine.
CREATE FUNCTION bpm.task_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('done', 'failed') AND NOT NEW.advanced THEN
        PERFORM pg_notify('ana_bpm', NEW.case_id::text);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER task_changed AFTER INSERT OR UPDATE OF status ON bpm.task FOR EACH ROW EXECUTE FUNCTION bpm.task_changed();

-- ---------------------------------------------------------------- the esteiras in the catalog (CA-039-07)
INSERT INTO bpm.process (code, name, level, objective, trigger_text, outcome, flow_code, created_by)
SELECT 'esteira.' || f.code, f.name, 'process', f.description, 'Criação de ' || f.document,
       'Documento concluído de ponta a ponta', f.code, 'system'
FROM flow.definition f;
INSERT INTO bpm.version (process_code, version, status, model, compiled, created_by, published_by, published_at, comment)
SELECT 'esteira.' || f.code, 1, 'published',
       jsonb_build_object(
           'lanes', '[]'::jsonb,
           'variables', '[]'::jsonb,
           'document', d.entity,
           'nodes', jsonb_build_array(jsonb_build_object('id', 'start', 'type', 'start', 'name', 'Início', 'x', 60, 'y', 120,
                                                         'props', jsonb_build_object('trigger', 'document', 'entity', d.entity)))
                    || COALESCE((SELECT jsonb_agg(jsonb_build_object(
                           'id', s.code, 'type', CASE s.mode WHEN 'wait' THEN 'event_fact' WHEN 'auto' THEN 'task_auto' ELSE 'task_human' END,
                           'name', s.name, 'x', 60 + 180 * s.seq, 'y', 110,
                           'props', jsonb_build_object('program', s.program, 'params', s.params, 'fact', d.entity || '.' || s.code,
                                                       'done_fact', d.entity || '.' || s.code))
                         ORDER BY s.seq) FROM flow.step s WHERE s.flow_code = f.code), '[]'::jsonb)
                    || jsonb_build_array(jsonb_build_object('id', 'end', 'type', 'end', 'name', 'Fim',
                                                            'x', 60 + 180 * ((SELECT max(seq) FROM flow.step WHERE flow_code = f.code) + 1),
                                                            'y', 120, 'props', '{}'::jsonb)),
           'edges', (SELECT jsonb_agg(jsonb_build_object('id', 'e' || k, 'from', a, 'to', b) ORDER BY k) FROM (
                        SELECT row_number() OVER (ORDER BY seq) AS k, a, b FROM (
                            SELECT s.seq, lag(s.code, 1, 'start') OVER (ORDER BY s.seq) AS a, s.code AS b
                            FROM flow.step s WHERE s.flow_code = f.code
                            UNION ALL
                            SELECT 1000, (SELECT code FROM flow.step WHERE flow_code = f.code ORDER BY seq DESC LIMIT 1), 'end') x) y)),
       jsonb_build_object('engine', 'esteira', 'starts_on', NULL, 'start', 'start'),
       'system', 'system', now(), 'Esteira da spec 030 (configure em Esteiras: modos, condições e robô)'
FROM flow.definition f JOIN bpm.document d ON d.label = f.document;

-- A person cancels a case (reason kept): tasks and tokens stop with it.
CREATE FUNCTION bpm.cancel_case(p_case bigint, p_by text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF length(coalesce(trim(p_reason), '')) < 3 THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: diga o motivo do cancelamento' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE bpm.task SET status = 'cancelled', advanced = true, finished_at = now()
     WHERE case_id = p_case AND status IN ('ready', 'running', 'waiting', 'failed');
    UPDATE bpm.token SET status = 'cancelled' WHERE case_id = p_case AND status IN ('active', 'joining');
    UPDATE bpm.case SET status = 'cancelled', reason = p_reason, finished_at = now(), updated_at = now()
     WHERE id = p_case AND status IN ('running', 'waiting', 'failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_STATE: o caso não está em andamento' USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO bpm.event (case_id, kind, by, detail) VALUES (p_case, 'cancel', p_by, jsonb_build_object('reason', p_reason));
END $$;

-- Moving running cases to another version (RF-039-06): only where every open element exists there.
CREATE FUNCTION bpm.migrate_case(p_case bigint, p_version integer, p_by text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_model jsonb; v_missing text;
BEGIN
    SELECT v.model INTO v_model FROM bpm.case c JOIN bpm.version v ON v.process_code = c.process_code AND v.version = p_version
     WHERE c.id = p_case;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'NOT_FOUND: versão inexistente' USING ERRCODE = 'check_violation';
    END IF;
    SELECT string_agg(DISTINCT t.node, ', ') INTO v_missing FROM bpm.token t
     WHERE t.case_id = p_case AND t.status IN ('active', 'joining')
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_model -> 'nodes') n WHERE n ->> 'id' = t.node);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_BLOCKED: a versão % não tem os elementos onde o caso está: %', p_version, v_missing
            USING ERRCODE = 'check_violation';
    END IF;
    UPDATE bpm.case SET version = p_version, updated_at = now() WHERE id = p_case;
    INSERT INTO bpm.event (case_id, kind, by, detail) VALUES (p_case, 'migrate', p_by, jsonb_build_object('version', p_version));
END $$;

-- What the modeler and the task list need from the system schema (executions cannot read it).
CREATE FUNCTION bpm.program_names() RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT name FROM ana_system.program WHERE active AND kind = 'program' ORDER BY name
$$;
CREATE FUNCTION bpm.group_names() RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT name FROM ana_system.access_group ORDER BY name
$$;
CREATE FUNCTION bpm.user_groups(p_user text) RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT group_name FROM ana_system.user_group WHERE username = p_user
$$;
CREATE FUNCTION bpm.user_exists(p_user text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM ana_system.app_user WHERE username = p_user AND active AND kind = 'human')
$$;

-- ---------------------------------------------------------------- grants
GRANT USAGE ON SCHEMA bpm TO ana_exec, ana_read;
GRANT SELECT ON ALL TABLES IN SCHEMA bpm TO ana_exec, ana_read;
GRANT INSERT, UPDATE, DELETE ON bpm.process, bpm.version, bpm.simulation TO ana_exec;
GRANT INSERT ON bpm.case, bpm.token, bpm.event TO ana_exec;
GRANT UPDATE (status, advanced, assignee, done_by, how, outcome, result, comment, finished_at, priority, due_at, error,
              next_at, attempts, lease_until) ON bpm.task TO ana_exec;
GRANT INSERT ON bpm.task TO ana_exec;
GRANT UPDATE (data, status, updated_at, finished_at, reason) ON bpm.case TO ana_exec;
GRANT UPDATE (read) ON bpm.notification TO ana_exec;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA bpm TO ana_exec;
GRANT EXECUTE ON FUNCTION bpm.business_add(timestamptz, numeric), bpm.start_document(text, text, text),
    bpm.cancel_case(bigint, text, text), bpm.migrate_case(bigint, integer, text), bpm.program_names(), bpm.group_names(),
    bpm.user_groups(text), bpm.user_exists(text) TO ana_exec;
REVOKE ALL ON FUNCTION bpm.start_trigger() FROM PUBLIC;
