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
