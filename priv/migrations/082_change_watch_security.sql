-- 082 — Change watch (spec 068), part 5: security at firing and on the way out (T-068-07, D9, D10, CA-068-01, CA-068-07).

-- ---------------------------------------------------------------- personal data to a connector (D10)
-- A connector may receive personal data (LGPD) only with a declared purpose, asked by one person and approved by
-- another (four eyes, enforced by the database); both stay in the audit log. Revoking clears the approval.
ALTER TABLE integration.connector
    ADD COLUMN personal_purpose      text CHECK (length(btrim(personal_purpose)) BETWEEN 10 AND 500),
    ADD COLUMN personal_requested_by text,
    ADD COLUMN personal_requested_at timestamptz,
    ADD COLUMN personal_approved_by  text,
    ADD COLUMN personal_approved_at  timestamptz,
    ADD CONSTRAINT connector_personal_request_check
        CHECK ((personal_purpose IS NULL) = (personal_requested_by IS NULL)),
    ADD CONSTRAINT connector_personal_four_eyes_check
        CHECK (personal_approved_by IS NULL
               OR (personal_requested_by IS NOT NULL AND personal_approved_by <> personal_requested_by));

-- ---------------------------------------------------------------- a check by someone else (CA-068-01)
-- A task may name the one person who must not do it (who made the change it asks to check): the database refuses
-- that person taking or finishing it, administrator or not.
ALTER TABLE bpm.task ADD COLUMN not_by text;
CREATE FUNCTION bpm.task_not_by() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.not_by IS NOT NULL AND (NEW.assignee = NEW.not_by OR NEW.done_by = NEW.not_by) THEN
        RAISE EXCEPTION 'FORBIDDEN: quem fez a alteração não pode conferir a própria alteração (quatro olhos)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER task_not_by BEFORE UPDATE OF assignee, done_by, status ON bpm.task
    FOR EACH ROW WHEN (NEW.not_by IS NOT NULL) EXECUTE FUNCTION bpm.task_not_by();

-- A task of a rule about master data (CA-068-01): the case has no BPM document of that kind. The person who must not
-- do it is set here, when the task is born (SECURITY DEFINER): no program can set or clear it afterwards (ana_exec has
-- no UPDATE on bpm.task.not_by).
CREATE FUNCTION automation.create_task(p_name text, p_kind text, p_entity text, p_key text, p_assignee text, p_role text,
                                       p_group text, p_instructions text, p_program text, p_params jsonb, p_context jsonb,
                                       p_actions jsonb, p_resolve jsonb, p_priority integer, p_by text, p_not_by text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c bigint; t bigint; tk bigint;
    ent text := CASE WHEN EXISTS (SELECT 1 FROM bpm.document d WHERE d.entity = p_entity) THEN p_entity ELSE 'none' END;
BEGIN
    IF p_kind NOT IN ('human', 'approval') THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: tarefa é "human" ou "approval"' USING ERRCODE = 'check_violation';
    END IF;
    IF p_assignee IS NULL AND p_role IS NULL AND p_group IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: diga para quem é a tarefa (pessoa, papel ou grupo)' USING ERRCODE = 'check_violation';
    END IF;
    IF p_not_by IS NOT NULL AND p_assignee = p_not_by THEN
        RAISE EXCEPTION 'FORBIDDEN: quem fez a alteração não pode conferir a própria alteração (quatro olhos)'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    INSERT INTO bpm.case (process_code, version, doc_entity, doc_key, title, data, started_by)
    VALUES ('erp.tarefa', 1, ent, p_key,
            p_name || CASE WHEN p_key IS NULL THEN '' ELSE ' — ' || p_key END, '{}', p_by)
    RETURNING id INTO c;
    INSERT INTO bpm.token (case_id, node) VALUES (c, 'tarefa') RETURNING id INTO tk;
    INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, assignee, role, group_name, program, params,
                          instructions, priority, context, actions, resolve, not_by)
    VALUES (c, tk, 'tarefa', p_kind, p_name, 'waiting', p_assignee, p_role, p_group, p_program, COALESCE(p_params, '{}'),
            COALESCE(p_instructions, ''), COALESCE(p_priority, 3), p_context, p_actions, p_resolve, p_not_by)
    RETURNING id INTO t;
    INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES (c, 'tarefa', 'enter', p_by,
        jsonb_build_object('document', ent, 'key', p_key));
    IF p_assignee IS NOT NULL THEN
        INSERT INTO bpm.notification (username, task_id, case_id, kind, message) VALUES (p_assignee, t, c, 'task', p_name);
    END IF;
    RETURN t;
END $$;

-- The version of spec 051 (15 parameters) keeps working for its callers.
CREATE OR REPLACE FUNCTION automation.create_task(p_name text, p_kind text, p_entity text, p_key text, p_assignee text,
                                                  p_role text, p_group text, p_instructions text, p_program text,
                                                  p_params jsonb, p_context jsonb, p_actions jsonb, p_resolve jsonb,
                                                  p_priority integer, p_by text) RETURNS bigint
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT automation.create_task(p_name, p_kind, p_entity, p_key, p_assignee, p_role, p_group, p_instructions, p_program,
                                  p_params, p_context, p_actions, p_resolve, p_priority, p_by, NULL)
$$;

REVOKE ALL ON FUNCTION automation.create_task(text, text, text, text, text, text, text, text, text, jsonb, jsonb, jsonb,
                                              jsonb, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION automation.create_task(text, text, text, text, text, text, text, text, text, jsonb, jsonb, jsonb,
                                                 jsonb, integer, text, text) TO ana_exec;
