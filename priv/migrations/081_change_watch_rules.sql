-- 081 — Change watch (spec 068), part 4: the "changed" trigger of the rules with its filters (T-068-06, D1) and the
-- choice between one firing per record and one grouped firing (T-068-05, D6).

ALTER TABLE automation.rule
    -- From/to, minimum variation (numbers), emptied or filled (D1). Checked by the core; refused on secret fields.
    ADD COLUMN watch_filter jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(watch_filter) = 'object'),
    -- Where the change came from; NULL = every origin but an import (D1: an import is out by default).
    ADD COLUMN watch_origins text[] CHECK (watch_origins <@ ARRAY['screen', 'api', 'import', 'rule', 'integration',
                                                                  'routine', 'other']),
    -- One record only ("warn me when THIS customer changes").
    ADD COLUMN watch_key text CHECK (length(watch_key) BETWEEN 1 AND 100),
    -- auto: grouped for an import or a routine and for a batch of more than 20 records; record: always one firing per
    -- record (with the limit of spec 051); grouped: always one firing with the list.
    ADD COLUMN watch_mode text NOT NULL DEFAULT 'auto' CHECK (watch_mode IN ('auto', 'record', 'grouped'));

-- Where a change came from, by what the database already knows (nothing written for it): the execution's program
-- (an import), a firing of a rule, a connector's program, else the origin of the execution.
CREATE INDEX fire_execution_idx ON automation.fire (execution_id) WHERE execution_id IS NOT NULL;
CREATE FUNCTION automation.origin_kind(p_origin text, p_execution text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE
        WHEN e.program ~ '\.import(_[a-z0-9_]+)?$' THEN 'import'
        WHEN e.id IS NOT NULL AND EXISTS (SELECT 1 FROM automation.fire f WHERE f.execution_id = e.id) THEN 'rule'
        WHEN e.program IN (SELECT c.inbound_program FROM integration.connector c WHERE c.inbound_program IS NOT NULL
                           UNION SELECT c.outbound_program FROM integration.connector c WHERE c.outbound_program IS NOT NULL)
            THEN 'integration'
        WHEN COALESCE(e.origin, p_origin) IN ('remote', 'api') THEN 'api'
        WHEN COALESCE(e.origin, p_origin) IN ('studio', 'master') THEN 'screen'
        WHEN COALESCE(e.origin, p_origin) = 'internal' THEN 'routine'
        ELSE 'other'
    END
    FROM (SELECT NULL::int) one
    LEFT JOIN ana_system.execution e
           ON p_execution ~ '^[0-9a-f-]{36}$' AND e.id = p_execution::uuid
$$;

-- The claimed firings that may be acted on now: ready, or without an execution, or whose execution has finished
-- (its changes are all in, its program is known), or waiting too long (a lost execution never holds a rule back).
CREATE FUNCTION automation.ready_fires(p_limit integer)
RETURNS SETOF bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT f.id FROM automation.fire f
     WHERE f.outcome = 'running'
       AND (f.detail ->> 'ready' = 'true'
            OR NULLIF(f.detail -> 'event' ->> 'execution_id', '') IS NULL
            OR f.at < now() - interval '15 minutes'
            OR EXISTS (SELECT 1 FROM ana_system.execution e
                        WHERE f.detail -> 'event' ->> 'execution_id' ~ '^[0-9a-f-]{36}$'
                          AND e.id = (f.detail -> 'event' ->> 'execution_id')::uuid
                          AND e.status <> 'running' AND e.finished_at < now() - interval '2 seconds'))
     ORDER BY f.id LIMIT p_limit
$$;

REVOKE ALL ON FUNCTION automation.origin_kind(text, text), automation.ready_fires(integer) FROM PUBLIC;
