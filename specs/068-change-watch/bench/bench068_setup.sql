-- SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Spec 068 plan.md measurements. Scratch schema, dropped at the end.
DROP SCHEMA IF EXISTS bench068 CASCADE;
CREATE SCHEMA bench068;
CREATE TABLE bench068.doc (LIKE sales.sales_order INCLUDING DEFAULTS INCLUDING INDEXES INCLUDING CONSTRAINTS);
ALTER TABLE bench068.doc ADD COLUMN delivery_date date;
INSERT INTO bench068.doc SELECT *, order_date + 10 FROM sales.sales_order ORDER BY id LIMIT 10000;
CREATE TABLE bench068.rule (entity text, field text, active boolean);
CREATE INDEX ON bench068.rule (entity) WHERE active;
INSERT INTO bench068.rule SELECT 'x' || g, 'notes', true FROM generate_series(1, 20) g;   -- other rules exist

-- Event queue (fields as jsonb {field: [old, new]}).
CREATE TABLE bench068.event (id bigserial PRIMARY KEY, xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    entity text NOT NULL, row_key text NOT NULL, changes jsonb NOT NULL, username text, origin text,
    at timestamptz NOT NULL DEFAULT now());
-- One event per document per transaction, by upsert.
CREATE TABLE bench068.event_once (xid xid8 NOT NULL DEFAULT pg_current_xact_id(), entity text NOT NULL,
    row_key text NOT NULL, changes jsonb NOT NULL, PRIMARY KEY (xid, entity, row_key));
-- One event per statement (bulk).
CREATE TABLE bench068.event_bulk (id bigserial PRIMARY KEY, xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    entity text NOT NULL, n integer NOT NULL, rows jsonb NOT NULL, at timestamptz NOT NULL DEFAULT now());

-- V1: row trigger, EXISTS on the rules per row (spec 051 style).
CREATE FUNCTION bench068.row_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM bench068.rule r WHERE r.active AND r.entity = 'doc') THEN RETURN NULL; END IF;
    IF OLD.total IS DISTINCT FROM NEW.total THEN
        INSERT INTO bench068.event (entity, row_key, changes)
        VALUES ('doc', NEW.number::text, jsonb_build_object('total', jsonb_build_array(OLD.total, NEW.total)));
    END IF;
    RETURN NULL;
END $$;
-- V1b: row trigger, upsert = one event per document per transaction.
CREATE FUNCTION bench068.row_once() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM bench068.rule r WHERE r.active AND r.entity = 'doc') THEN RETURN NULL; END IF;
    IF OLD.total IS DISTINCT FROM NEW.total THEN
        INSERT INTO bench068.event_once (entity, row_key, changes)
        VALUES ('doc', NEW.number::text, jsonb_build_object('total', jsonb_build_array(OLD.total, NEW.total)))
        ON CONFLICT (xid, entity, row_key) DO UPDATE
           SET changes = jsonb_build_object('total', jsonb_build_array(bench068.event_once.changes -> 'total' -> 0, EXCLUDED.changes -> 'total' -> 1));
    END IF;
    RETURN NULL;
END $$;
-- V2: statement trigger with transition tables: one rule lookup per statement, one INSERT … SELECT of changed rows.
CREATE FUNCTION bench068.stmt_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM bench068.rule r WHERE r.active AND r.entity = 'doc') THEN RETURN NULL; END IF;
    INSERT INTO bench068.event (entity, row_key, changes)
    SELECT 'doc', n.number::text, jsonb_build_object('total', jsonb_build_array(o.total, n.total))
      FROM new_rows n JOIN old_rows o USING (id) WHERE o.total IS DISTINCT FROM n.total;
    RETURN NULL;
END $$;
-- V2b: statement trigger, one row per statement with the list (D6 bulk).
CREATE FUNCTION bench068.stmt_bulk() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c integer; j jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM bench068.rule r WHERE r.active AND r.entity = 'doc') THEN RETURN NULL; END IF;
    SELECT count(*), jsonb_agg(jsonb_build_array(n.number, o.total, n.total)) INTO c, j
      FROM new_rows n JOIN old_rows o USING (id) WHERE o.total IS DISTINCT FROM n.total;
    IF c > 0 THEN INSERT INTO bench068.event_bulk (entity, n, rows) VALUES ('doc', c, j); END IF;
    RETURN NULL;
END $$;

-- Measurement: elapsed ms and WAL bytes of one statement, in its own transaction.
CREATE FUNCTION bench068.measure(stmt text, OUT ms numeric, OUT wal bigint) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; l0 pg_lsn;
BEGIN
    l0 := pg_current_wal_insert_lsn(); t0 := clock_timestamp();
    EXECUTE stmt;
    ms := round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1);
    wal := pg_current_wal_insert_lsn() - l0;
END $$;

CREATE TABLE bench068.result (seq serial, case_name text, run int, ms numeric, wal bigint);
