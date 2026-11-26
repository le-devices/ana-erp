-- 080 — Change watch (spec 068), part 3: master data watched from the history that already exists (T-068-03, D4) and
-- firing that neither loses nor repeats (RNF-068-04).
--
-- Watching a master adds no write per change: the event IS the row of master.change_log. The leader reads it from the
-- last point (ana_watch_log); what an active rule watches is first CLAIMED — a firing row 'running', unique per rule
-- and event — in the same transaction that records the point read (or that takes the document events from the
-- queue), and only then acted on. A crash leaves 'running' rows, taken again by the leader; the unique key keeps a
-- re-read (after a restart or a leader change) from firing twice.

ALTER TABLE automation.fire DROP CONSTRAINT fire_outcome_check;
ALTER TABLE automation.fire ADD CONSTRAINT fire_outcome_check
    CHECK (outcome IN ('running', 'done', 'skipped', 'failed', 'blocked', 'rehearsal'));
ALTER TABLE automation.fire ADD COLUMN event_ref text CHECK (length(event_ref) <= 200);
CREATE UNIQUE INDEX fire_event_once ON automation.fire (rule_id, event_ref) WHERE event_ref IS NOT NULL;
CREATE INDEX fire_running_idx ON automation.fire (id) WHERE outcome = 'running';

-- The rows of the history after a point (and the ids still missing below it: a longer transaction may commit a smaller
-- id later). Every row comes back with its id, so the reader can tell a gap from a row nobody watches; only the rows of
-- an entity some active rule watches come with their changes, keyed by the catalog's reference ("schema.table.column"
-- or "custom.name"), only real changes (not a change waiting for approval), only fields of the catalog, and a secret field as "***" (D10: the value never leaves the history).
CREATE FUNCTION automation.read_log(p_after bigint, p_missing bigint[], p_limit integer DEFAULT 500)
RETURNS TABLE (id bigint, entity text, row_key text, op text, changes jsonb, username text, origin text, execution_id text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH watched AS (
        SELECT DISTINCT r.entity FROM automation.rule r JOIN automation.watch_entity e ON e.entity = r.entity
         WHERE r.active AND r.trigger_kind = 'changed' AND e.source = 'master'
    ), rows AS (
        SELECT l.* FROM master.change_log l WHERE l.id > p_after
         ORDER BY l.id LIMIT greatest(p_limit, 1)
    ), more AS (
        SELECT l.* FROM master.change_log l WHERE l.id = ANY (p_missing) AND l.id <= p_after
    ), picked AS (
        SELECT * FROM rows UNION ALL SELECT * FROM more
    ), cells AS (
        -- the company's own fields are one change of "custom" in the history: split by field
        SELECT p.id, 'custom.' || k AS ref, p.changes -> 'custom' -> 0 -> k AS before, p.changes -> 'custom' -> 1 -> k AS after
          FROM picked p
         CROSS JOIN LATERAL jsonb_object_keys(COALESCE(p.changes -> 'custom' -> 0, '{}') || COALESCE(p.changes -> 'custom' -> 1, '{}')) k
         WHERE p.entity IN (SELECT entity FROM watched) AND p.op IN ('insert', 'update', 'delete')
           AND jsonb_typeof(p.changes -> 'custom') = 'array'
        UNION ALL
        SELECT p.id, p.table_name || '.' || c.key, c.value -> 0, c.value -> 1
          FROM picked p CROSS JOIN LATERAL jsonb_each(p.changes) c
         WHERE p.entity IN (SELECT entity FROM watched) AND p.op IN ('insert', 'update', 'delete')
           AND c.key <> 'custom' AND jsonb_typeof(c.value) = 'array'
    ), named AS (
        SELECT c.id, c.ref,
               CASE WHEN w.classification = 'secret' THEN '["***", "***"]'::jsonb
                    ELSE jsonb_build_array(c.before, c.after) END AS pair
          FROM cells c JOIN picked p ON p.id = c.id
          JOIN automation.watchable w ON w.entity = p.entity
                                     AND c.ref = CASE WHEN w.custom THEN w.field ELSE w.table_name || '.' || w.field END
         WHERE c.before IS DISTINCT FROM c.after OR c.before = '"***"'::jsonb    -- masked by the history: it changed
    )
    SELECT p.id, p.entity, p.row_key, p.op,
           (SELECT jsonb_object_agg(n.ref, n.pair) FROM named n WHERE n.id = p.id),
           p.username, p.origin, p.execution_id
      FROM picked p
     ORDER BY p.id
$$;

REVOKE ALL ON FUNCTION automation.read_log(bigint, bigint[], integer) FROM PUBLIC;

-- The point read in the history (ana_watch_log): written only with a batch that fired, or every few minutes, and
-- removed when no rule watches a master any more (the next rule starts from that moment, not from the past).
ALTER TABLE automation.mark ADD COLUMN value bigint;
