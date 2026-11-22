-- 076 — Automation by default (spec 051): rules "when… then…", the events that wake them, the history of what
-- they did, usage aggregates and suggestions, and the ERP's own tasks (rules and exceptions) in "Minhas tarefas".
CREATE SCHEMA automation;

-- ---------------------------------------------------------------- rules (D2, RF-051-02)
CREATE TABLE automation.rule (
    id                bigserial PRIMARY KEY,
    name              text NOT NULL UNIQUE CHECK (length(trim(name)) BETWEEN 3 AND 120),
    description       text NOT NULL DEFAULT '' CHECK (length(description) <= 2000),
    owner             text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    -- When: a document created, a document changing status, a time, a metric passing a limit, a message received.
    trigger_kind      text NOT NULL CHECK (trigger_kind IN ('created', 'status', 'schedule', 'metric', 'message')),
    entity            text REFERENCES bpm.document(entity),
    status_to         text CHECK (length(status_to) <= 40),
    cron              text CHECK (length(cron) <= 120),
    metric            text CHECK (metric ~ '^[a-z][a-z0-9_]{1,62}$'),
    metric_op         text CHECK (metric_op IN ('>', '>=', '<', '<=')),
    metric_value      numeric,
    connector         text CHECK (length(connector) <= 80),
    -- If: the conditions of the condition builder (spec 020), on the document's facts.
    conditions        jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(conditions) IN ('array', 'object')),
    -- Then: one action of a closed list (run, task, notify, email, connector).
    action            jsonb NOT NULL CHECK (jsonb_typeof(action) = 'object'
                                            AND action ->> 'kind' IN ('run', 'task', 'notify', 'email', 'connector')),
    -- RNF-051-01: never in a loop.
    max_fires         integer NOT NULL DEFAULT 20 CHECK (max_fires BETWEEN 1 AND 10000),
    window_minutes    integer NOT NULL DEFAULT 60 CHECK (window_minutes BETWEEN 1 AND 10080),
    active            boolean NOT NULL DEFAULT false,
    version           integer NOT NULL DEFAULT 1,
    rehearsed_version integer,                               -- turned on only when rehearsed in the current version
    blocked_reason    text,
    blocked_at        timestamptz,
    last_fired_at     timestamptz,
    created_by        text NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        text,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK ((trigger_kind IN ('created', 'status')) = (entity IS NOT NULL)),
    CHECK ((trigger_kind = 'schedule') = (cron IS NOT NULL)),
    CHECK ((trigger_kind = 'metric') = (metric IS NOT NULL AND metric_op IS NOT NULL AND metric_value IS NOT NULL)),
    CHECK ((trigger_kind = 'message') = (connector IS NOT NULL)),
    CHECK (NOT active OR rehearsed_version = version)
);
CREATE INDEX rule_watch_idx ON automation.rule (entity, trigger_kind) WHERE active;

-- Events of documents waiting for the rules (written only when an active rule watches them: no rule, no write).
CREATE TABLE automation.pending (
    id          bigserial PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('created', 'status', 'message')),
    entity      text,
    doc_key     text,
    status_from text,
    status_to   text,
    connector   text,
    chain       bigint[] NOT NULL DEFAULT '{}',              -- rules whose actions led here (loop detection)
    username    text,
    at          timestamptz NOT NULL DEFAULT now()
);

-- What each rule did: every firing, rehearsal and block, with the document and the execution.
CREATE TABLE automation.fire (
    id           bigserial PRIMARY KEY,
    rule_id      bigint NOT NULL REFERENCES automation.rule(id) ON DELETE CASCADE,
    at           timestamptz NOT NULL DEFAULT now(),
    entity       text,
    doc_key      text,
    outcome      text NOT NULL CHECK (outcome IN ('done', 'skipped', 'failed', 'blocked', 'rehearsal')),
    detail       jsonb NOT NULL DEFAULT '{}',
    execution_id uuid,
    chain        bigint[] NOT NULL DEFAULT '{}',
    by           text
);
CREATE INDEX fire_rule_idx ON automation.fire (rule_id, id DESC);
CREATE INDEX fire_at_brin ON automation.fire USING brin (at);

-- A document created or changing status: queued for the rules that watch it, woken after the COMMIT.
CREATE FUNCTION automation.document_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    ent text := TG_ARGV[0];
    kind text := CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'status' END;
    s_new text; s_old text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM automation.rule r WHERE r.active AND r.entity = ent AND r.trigger_kind = kind) THEN
        RETURN NULL;
    END IF;
    s_new := to_jsonb(NEW) ->> 'status';
    IF TG_OP = 'UPDATE' THEN
        s_old := to_jsonb(OLD) ->> 'status';
        IF s_old IS NOT DISTINCT FROM s_new OR NOT EXISTS (
            SELECT 1 FROM automation.rule r WHERE r.active AND r.entity = ent AND r.trigger_kind = 'status'
               AND (r.status_to IS NULL OR r.status_to = s_new)) THEN
            RETURN NULL;
        END IF;
    END IF;
    INSERT INTO automation.pending (kind, entity, doc_key, status_from, status_to, chain, username)
    VALUES (kind, ent, to_jsonb(NEW) ->> TG_ARGV[1], s_old, s_new,
            COALESCE(string_to_array(NULLIF(current_setting('ana.rule_chain', true), ''), ',')::bigint[], '{}'),
            NULLIF(current_setting('ana.username', true), ''));
    PERFORM pg_notify('ana_wake', 'rules');
    RETURN NULL;
END $$;
CREATE TRIGGER automation_event AFTER INSERT OR UPDATE OF status ON sales.sales_order
    FOR EACH ROW EXECUTE FUNCTION automation.document_event('sales_order', 'number');
CREATE TRIGGER automation_event AFTER INSERT OR UPDATE OF status ON supply.purchase_request
    FOR EACH ROW EXECUTE FUNCTION automation.document_event('purchase_request', 'number');
CREATE TRIGGER automation_event AFTER INSERT OR UPDATE OF status ON field.service_order
    FOR EACH ROW EXECUTE FUNCTION automation.document_event('service_order', 'number');
CREATE TRIGGER automation_event AFTER INSERT OR UPDATE OF status ON production.work_order
    FOR EACH ROW EXECUTE FUNCTION automation.document_event('work_order', 'number');
CREATE TRIGGER automation_event AFTER INSERT OR UPDATE OF status ON projects.project
    FOR EACH ROW EXECUTE FUNCTION automation.document_event('project', 'code');

-- A message received by a connector (spec 017).
CREATE FUNCTION automation.message_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM automation.rule r WHERE r.active AND r.trigger_kind = 'message' AND r.connector = NEW.connector) THEN
        INSERT INTO automation.pending (kind, doc_key, connector) VALUES ('message', NEW.id::text, NEW.connector);
        PERFORM pg_notify('ana_wake', 'rules');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER automation_event AFTER INSERT ON integration.inbox FOR EACH ROW EXECUTE FUNCTION automation.message_event();

-- ---------------------------------------------------------------- usage and suggestions (D3, RF-051-03, RNF-051-02)
-- What people ran, per day (from the execution log, in the background — never in the execution itself).
CREATE TABLE automation.usage_day (
    day         date NOT NULL,
    username    text NOT NULL,
    program     text NOT NULL,
    params_hash text NOT NULL,
    params      jsonb NOT NULL,
    first_at    time NOT NULL,                               -- first run of the day, in the company's time zone
    runs        integer NOT NULL,
    variant     boolean NOT NULL DEFAULT false,               -- some run that day came from a variant
    PRIMARY KEY (day, username, program, params_hash)
);
CREATE TABLE automation.mark (
    name text PRIMARY KEY,
    at   timestamptz NOT NULL
);
CREATE TABLE automation.suggestion (
    id          bigserial PRIMARY KEY,
    username    text NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('schedule', 'variant')),
    fingerprint text NOT NULL,
    program     text NOT NULL,
    title       text NOT NULL,
    explanation text NOT NULL,
    payload     jsonb NOT NULL,
    status      text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'accepted', 'declined')),
    result      jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    decided_at  timestamptz,
    UNIQUE (username, fingerprint)                            -- declined, it never comes back
);
CREATE INDEX suggestion_open_idx ON automation.suggestion (username) WHERE status = 'new';

-- ---------------------------------------------------------------- ERP tasks (D4, RF-051-05)
-- Tasks the ERP itself gives people (a rule, an exception): one built-in process, start → task → end, so they live in
-- "Minhas tarefas" with everything the engine already does (claim, delegate, deadline, escalation, trail).
ALTER TABLE bpm.task ADD COLUMN context jsonb, ADD COLUMN actions jsonb, ADD COLUMN resolve jsonb;
DROP INDEX bpm.case_document_once;
CREATE UNIQUE INDEX case_document_once ON bpm.case (process_code, doc_entity, doc_key)
    WHERE doc_key IS NOT NULL AND parent_task IS NULL AND status IN ('running', 'waiting', 'failed') AND process_code <> 'erp.tarefa';

INSERT INTO bpm.process (code, name, level, objective, trigger_text, outcome, created_by)
VALUES ('erp.tarefa', 'Tarefas do ERP', 'process',
        'O que foge da política vira tarefa de uma pessoa, com o contexto e as ações possíveis (spec 051)',
        'Regra "quando… então…" ou exceção de uma automação', 'Exceção resolvida', 'system');
INSERT INTO bpm.version (process_code, version, status, model, compiled, created_by, published_by, published_at, comment)
VALUES ('erp.tarefa', 1, 'published',
        '{"lanes": [], "variables": [], "document": null,
          "nodes": [{"id": "start", "type": "start", "name": "Início", "x": 60, "y": 120, "props": {}},
                    {"id": "tarefa", "type": "task_human", "name": "Tarefa", "x": 240, "y": 110, "props": {}},
                    {"id": "end", "type": "end", "name": "Fim", "x": 420, "y": 120, "props": {}}],
          "edges": [{"id": "e1", "from": "start", "to": "tarefa"}, {"id": "e2", "from": "tarefa", "to": "end"}]}',
        '{"start": "start", "starts_on": null, "run_as": "system",
          "reach": {"start": ["tarefa", "end"], "tarefa": ["end"], "end": []}}',
        'system', 'system', now(), 'Processo embutido das tarefas do ERP (spec 051)');

CREATE FUNCTION automation.create_task(p_name text, p_kind text, p_entity text, p_key text, p_assignee text, p_role text,
                                       p_group text, p_instructions text, p_program text, p_params jsonb, p_context jsonb,
                                       p_actions jsonb, p_resolve jsonb, p_priority integer, p_by text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c bigint; t bigint; tk bigint; ent text := COALESCE(p_entity, 'none');
BEGIN
    IF p_kind NOT IN ('human', 'approval') THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: tarefa é "human" ou "approval"' USING ERRCODE = 'check_violation';
    END IF;
    IF p_assignee IS NULL AND p_role IS NULL AND p_group IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: diga para quem é a tarefa (pessoa, papel ou grupo)' USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO bpm.case (process_code, version, doc_entity, doc_key, title, data, started_by)
    VALUES ('erp.tarefa', 1, ent, p_key,
            p_name || CASE WHEN p_key IS NULL THEN '' ELSE ' — ' || p_key END, '{}', p_by)
    RETURNING id INTO c;
    INSERT INTO bpm.token (case_id, node) VALUES (c, 'tarefa') RETURNING id INTO tk;
    INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, assignee, role, group_name, program, params,
                          instructions, priority, context, actions, resolve)
    VALUES (c, tk, 'tarefa', p_kind, p_name, 'waiting', p_assignee, p_role, p_group, p_program, COALESCE(p_params, '{}'),
            COALESCE(p_instructions, ''), COALESCE(p_priority, 3), p_context, p_actions, p_resolve)
    RETURNING id INTO t;
    INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES (c, 'tarefa', 'enter', p_by,
        jsonb_build_object('document', ent, 'key', p_key));
    IF p_assignee IS NOT NULL THEN
        INSERT INTO bpm.notification (username, task_id, case_id, kind, message) VALUES (p_assignee, t, c, 'task', p_name);
    END IF;
    RETURN t;
END $$;

-- A notice to a person or to every member of a group (the bell of "Minhas tarefas").
CREATE FUNCTION automation.notify(p_user text, p_group text, p_message text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer;
BEGIN
    INSERT INTO bpm.notification (username, kind, message)
    SELECT DISTINCT u.username, 'warn', left(p_message, 1900) FROM ana_system.app_user u
     WHERE u.active AND u.kind = 'human'
       AND (u.username = p_user OR u.username IN (SELECT g.username FROM ana_system.user_group g WHERE g.group_name = p_group));
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

REVOKE ALL ON FUNCTION automation.document_event(), automation.message_event() FROM PUBLIC;
REVOKE ALL ON FUNCTION automation.create_task(text, text, text, text, text, text, text, text, text, jsonb, jsonb, jsonb,
                                              jsonb, integer, text), automation.notify(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION automation.create_task(text, text, text, text, text, text, text, text, text, jsonb, jsonb, jsonb,
                                                 jsonb, integer, text), automation.notify(text, text, text) TO ana_exec;
GRANT USAGE ON SCHEMA automation TO ana_exec;
GRANT SELECT ON automation.rule, automation.fire, automation.suggestion TO ana_exec;
