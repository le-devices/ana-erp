-- SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
-- SPDX-License-Identifier: AGPL-3.0-or-later
CREATE OR REPLACE FUNCTION bench068.stmt_bulk2() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM bench068.rule r WHERE r.active AND r.entity = 'doc') THEN RETURN NULL; END IF;
    INSERT INTO bench068.event_bulk (entity, n, rows)
    SELECT 'doc', count(*), jsonb_build_object('key', array_agg(n.number), 'old', array_agg(o.total), 'new', array_agg(n.total))
      FROM new_rows n JOIN old_rows o USING (id) WHERE o.total IS DISTINCT FROM n.total HAVING count(*) > 0;
    RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION bench068.row_plain() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bench068.event (entity, row_key, changes)
    VALUES ('doc', NEW.number::text, jsonb_build_object('total', jsonb_build_array(OLD.total, NEW.total)));
    RETURN NULL;
END $$;
