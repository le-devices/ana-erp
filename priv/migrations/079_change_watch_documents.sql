-- 079 — Change watch (spec 068), part 2: documents watched by field (T-068-04, D5) and the short queue (T-068-09, D8).
--
-- Measured in plan.md: the check exists on a table only while an active rule needs it (no rule: exactly zero cost),
-- as one statement trigger with transition tables writing ONE event per command with the list of changed rows
-- (≈ 4.5 B per row). The trigger function is generated from the catalog by the database itself (never from typed
-- text) and replaced without touching the table; creating or dropping the trigger waits at most 100 ms for the lock
-- (the core retries in the background, ana_watch).

-- ---------------------------------------------------------------- rules that watch fields (fields only; T-068-06 adds the rest)
ALTER TABLE automation.rule DROP CONSTRAINT rule_trigger_kind_check;
ALTER TABLE automation.rule ADD CONSTRAINT rule_trigger_kind_check
    CHECK (trigger_kind IN ('created', 'status', 'schedule', 'metric', 'message', 'changed'));
ALTER TABLE automation.rule DROP CONSTRAINT rule_check;          -- (created, status) = entity: 'changed' has one too
ALTER TABLE automation.rule ADD CONSTRAINT rule_entity_check
    CHECK ((trigger_kind IN ('created', 'status', 'changed')) = (entity IS NOT NULL));
-- A watched entity may be a master (party, product…), not only a BPM document: checked by the trigger below.
ALTER TABLE automation.rule DROP CONSTRAINT rule_entity_fkey;
ALTER TABLE automation.rule ADD COLUMN watch_fields text[] CHECK (array_position(watch_fields, NULL) IS NULL),
    ADD CONSTRAINT rule_changed_fields_check CHECK ((trigger_kind = 'changed') = (COALESCE(cardinality(watch_fields), 0) > 0));

-- The database refuses an entity or a field outside the catalog, whoever writes the rule (CA-068-08, RNF-068-03).
CREATE FUNCTION automation.check_rule_entity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE bad text;
BEGIN
    IF NEW.trigger_kind IN ('created', 'status') THEN
        IF NOT EXISTS (SELECT 1 FROM bpm.document d WHERE d.entity = NEW.entity) THEN
            RAISE EXCEPTION 'INVALID_PARAMETER: documento % não existe', NEW.entity USING ERRCODE = 'foreign_key_violation';
        END IF;
    ELSIF NEW.trigger_kind = 'changed' THEN
        IF NOT EXISTS (SELECT 1 FROM automation.watch_entity e WHERE e.entity = NEW.entity AND e.volume = 'normal') THEN
            RAISE EXCEPTION 'FORBIDDEN: % não pode ser vigiado', NEW.entity USING ERRCODE = 'insufficient_privilege';
        END IF;
        SELECT string_agg(r, ', ') INTO bad FROM unnest(NEW.watch_fields) r
         WHERE NOT EXISTS (SELECT 1 FROM automation.watchable w WHERE w.entity = NEW.entity
                              AND r = CASE WHEN w.custom THEN w.field ELSE w.table_name || '.' || w.field END);
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'FORBIDDEN: campo(s) fora do catálogo: %', bad USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER check_rule_entity BEFORE INSERT OR UPDATE OF trigger_kind, entity, watch_fields ON automation.rule
    FOR EACH ROW EXECUTE FUNCTION automation.check_rule_entity();

-- Rules changed: the core reconciles the installed checks (leader only, ana_watch).
CREATE FUNCTION automation.rules_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_wake', 'watch');
    RETURN NULL;
END $$;
CREATE TRIGGER rules_changed AFTER INSERT OR UPDATE OR DELETE ON automation.rule
    FOR EACH STATEMENT EXECUTE FUNCTION automation.rules_changed();

-- What the active rules need watched on documents (masters are read from the history and need nothing installed).
CREATE VIEW automation.watch_need AS
SELECT DISTINCT f.entity, f.table_name, f.column_name, f.via_column, f.classification
  FROM automation.rule r
 CROSS JOIN LATERAL unnest(r.watch_fields) AS w(ref)
  JOIN automation.watch_field f ON f.entity = r.entity AND f.table_name || '.' || f.column_name = w.ref
  JOIN automation.watch_entity e ON e.entity = f.entity AND e.source = 'document'
 WHERE r.active AND r.trigger_kind = 'changed';

-- ---------------------------------------------------------------- the queue (D8): the one of spec 051, one more kind
ALTER TABLE automation.pending DROP CONSTRAINT pending_kind_check;
ALTER TABLE automation.pending ADD CONSTRAINT pending_kind_check CHECK (kind IN ('created', 'status', 'message', 'changed'));
ALTER TABLE automation.pending
    ADD COLUMN changes jsonb,                                    -- 'changed': [{"k": key, "c": {field: [old, new]}}, …]
    ADD COLUMN rows    integer,                                  -- how many changed rows the command touched
    ADD COLUMN origin  text,
    ADD COLUMN xid     xid8;
CREATE INDEX pending_changed_idx ON automation.pending (id) WHERE kind = 'changed';

-- ---------------------------------------------------------------- installing the check (D5)
-- The trigger function of a table compares only the watched columns; a secret column says "changed", never the value.
CREATE FUNCTION automation.watch_body(p_table text) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    e automation.watch_entity;
    rel regclass := p_table::regclass;
    via text;
    pk text[];
    keyexpr text;
    cmp text;
    obj text;
BEGIN
    SELECT we.* INTO e FROM automation.watch_entity we
     WHERE we.source = 'document' AND we.volume = 'normal'
       AND EXISTS (SELECT 1 FROM automation.watch_field f WHERE f.entity = we.entity AND f.table_name = p_table);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORBIDDEN: % não pode ser vigiada', p_table USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT string_agg(format('o.%1$I IS DISTINCT FROM n.%1$I', column_name), ' OR ' ORDER BY column_name),
           string_agg(format('%1$L, CASE WHEN o.%2$I IS DISTINCT FROM n.%2$I THEN %3$s END', column_name, column_name,
                             CASE WHEN classification = 'secret' THEN '''["***", "***"]''::jsonb'
                                  ELSE format('jsonb_build_array(to_jsonb(o.%1$I), to_jsonb(n.%1$I))', column_name) END),
                      ', ' ORDER BY column_name),
           max(via_column)
      INTO cmp, obj, via
      FROM automation.watch_need WHERE table_name = p_table;
    IF cmp IS NULL THEN
        RETURN 'BEGIN RETURN NULL; END';                         -- nothing watched any more (dropped later, lazily)
    END IF;
    SELECT array_agg(a.attname ORDER BY a.attnum) INTO pk
      FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
     WHERE i.indrelid = rel AND i.indisprimary;
    IF pk IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: % não tem chave primária', p_table USING ERRCODE = 'check_violation';
    END IF;
    keyexpr := CASE WHEN via IS NULL THEN format('n.%I::text', e.key_column)
                    ELSE format('(SELECT p.%I::text FROM %s p WHERE p.%I = n.%I)', e.key_column, e.table_name::regclass,
                                e.id_column, via) END;
    RETURN format($f$
BEGIN
    INSERT INTO automation.pending (kind, entity, changes, rows, chain, username, origin, xid)
    SELECT 'changed', %1$L, jsonb_agg(jsonb_build_object('k', c.k, 'c', c.c)), count(*),
           COALESCE(string_to_array(NULLIF(current_setting('ana.rule_chain', true), ''), ',')::bigint[], '{}'),
           NULLIF(current_setting('ana.username', true), ''), NULLIF(current_setting('ana.origin', true), ''),
           pg_current_xact_id()
      FROM (SELECT %2$s AS k, jsonb_strip_nulls(jsonb_build_object(%3$s)) AS c
              FROM new_rows n JOIN old_rows o USING (%4$s) WHERE %5$s) c
    HAVING count(*) > 0;
    IF FOUND THEN PERFORM pg_notify('ana_wake', 'rules'); END IF;
    RETURN NULL;
END$f$, e.entity, keyexpr, obj, (SELECT string_agg(format('%I', x), ', ') FROM unnest(pk) x), cmp);
END $$;

-- Installs, updates or (p_drop) removes the check of one table. Returns what it did. Changing the function never
-- locks the table; creating or dropping the trigger waits at most 100 ms (lock_timeout), else it fails and the core
-- tries again later.
CREATE FUNCTION automation.install_watch(p_table text, p_drop boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET lock_timeout = '100ms' AS $$
DECLARE
    rel regclass;
    fn text;
    body text;
    hash text;
    has_trigger boolean;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM automation.watch_field f JOIN automation.watch_entity e USING (entity)
                    WHERE f.table_name = p_table AND e.source = 'document' AND e.volume = 'normal') THEN
        RAISE EXCEPTION 'FORBIDDEN: % não pode ser vigiada', p_table USING ERRCODE = 'insufficient_privilege';
    END IF;
    rel := p_table::regclass;
    fn := 'automation.' || quote_ident('w_' || replace(p_table, '.', '__'));
    has_trigger := EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'automation_watch');
    IF p_drop THEN
        IF EXISTS (SELECT 1 FROM automation.watch_need WHERE table_name = p_table) THEN
            RETURN 'needed';
        END IF;
        IF has_trigger THEN
            EXECUTE format('DROP TRIGGER automation_watch ON %s', rel);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS %s()', fn);
        RETURN CASE WHEN has_trigger THEN 'removed' ELSE 'unchanged' END;
    END IF;
    body := automation.watch_body(p_table);
    hash := md5(body);
    IF to_regprocedure(fn || '()') IS NOT NULL AND obj_description(to_regprocedure(fn || '()'), 'pg_proc') = hash
       AND has_trigger THEN
        RETURN 'unchanged';
    END IF;
    EXECUTE format('CREATE OR REPLACE FUNCTION %s() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER '
                   'SET search_path = pg_catalog, pg_temp AS %L', fn, body);
    EXECUTE format('REVOKE ALL ON FUNCTION %s() FROM PUBLIC', fn);
    EXECUTE format('COMMENT ON FUNCTION %s() IS %L', fn, hash);
    IF NOT has_trigger THEN
        EXECUTE format('CREATE TRIGGER automation_watch AFTER UPDATE ON %s REFERENCING OLD TABLE AS old_rows '
                       'NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION %s()', rel, fn);
        RETURN 'installed';
    END IF;
    RETURN 'updated';
END $$;

-- What ana_watch reconciles: every table that needs a check or still has one, and whether it is up to date.
CREATE FUNCTION automation.watch_plan()
RETURNS TABLE (table_name text, needed boolean, installed boolean, current boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH t AS (
        SELECT DISTINCT n.table_name FROM automation.watch_need n
        UNION
        SELECT c.oid::regclass::text FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid WHERE g.tgname = 'automation_watch'
    )
    SELECT t.table_name,
           EXISTS (SELECT 1 FROM automation.watch_need n WHERE n.table_name = t.table_name),
           EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgrelid = to_regclass(t.table_name) AND g.tgname = 'automation_watch'),
           COALESCE(obj_description(to_regprocedure('automation.' || quote_ident('w_' || replace(t.table_name, '.', '__')) || '()'),
                                    'pg_proc') = md5(automation.watch_body(t.table_name)), false)
      FROM t
$$;

-- ---------------------------------------------------------------- taking the events (D8, RNF-068-01)
-- Takes the events of whole transactions (never half of one), deletes them and returns ONE event per document and
-- per transaction: the first "before" and the last "after" of each field; a field that came back to its value in
-- the same transaction is not a change, and a document left with no change is not an event.
CREATE FUNCTION automation.take_changed(p_max integer DEFAULT 200)
RETURNS TABLE (entity text, doc_key text, changes jsonb, xid xid8, first_id bigint, username text, origin text,
               chain bigint[], command_rows integer)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH tx AS (
        SELECT p.xid FROM automation.pending p WHERE p.kind = 'changed'
         GROUP BY p.xid ORDER BY min(p.id) LIMIT greatest(p_max, 1)
    ), gone AS (
        DELETE FROM automation.pending p USING tx WHERE p.kind = 'changed' AND p.xid = tx.xid RETURNING p.*
    ), cells AS (
        SELECT g.id, g.entity, g.xid, g.username, g.origin, g.chain, g.rows, r.ord, r.v ->> 'k' AS k, c.key AS field,
               c.value AS pair
          FROM gone g
         CROSS JOIN LATERAL jsonb_array_elements(g.changes) WITH ORDINALITY AS r(v, ord)
         CROSS JOIN LATERAL jsonb_each(r.v -> 'c') AS c
    ), per_field AS (
        SELECT entity, xid, k, field,
               (array_agg(pair -> 0 ORDER BY id, ord))[1] AS before,
               (array_agg(pair -> 1 ORDER BY id DESC, ord DESC))[1] AS after,
               min(id) AS first_id
          FROM cells GROUP BY entity, xid, k, field
    ), meta AS (
        SELECT DISTINCT ON (entity, xid, k) entity, xid, k, username, origin, chain
          FROM cells ORDER BY entity, xid, k, id
    )
    SELECT f.entity, f.k, jsonb_object_agg(f.field, jsonb_build_array(f.before, f.after)), f.xid, min(f.first_id),
           m.username, m.origin, m.chain,
           (SELECT sum(g.rows)::integer FROM gone g WHERE g.xid = f.xid AND g.entity = f.entity)
      FROM per_field f JOIN meta m USING (entity, xid, k)
     WHERE f.before IS DISTINCT FROM f.after OR f.before = '"***"'::jsonb
     GROUP BY f.entity, f.xid, f.k, m.username, m.origin, m.chain
     ORDER BY min(f.first_id), f.k
$$;

REVOKE ALL ON FUNCTION automation.install_watch(text, boolean), automation.watch_plan(), automation.take_changed(integer),
    automation.watch_body(text), automation.check_rule_entity(), automation.rules_changed() FROM PUBLIC;
