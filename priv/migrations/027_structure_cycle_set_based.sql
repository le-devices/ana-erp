-- 027 — Structure cycle check, set-based (spec 014, RNF-014-01/03)
-- The row trigger of 025 ran one recursive query per inserted line: bulk loads of large
-- structures grew too slow. Now one query per statement, over the transition table of the
-- new lines (pairs parent → component deduplicated, so the walk always ends).

DROP TRIGGER IF EXISTS structure_line_cycle ON production.structure_line;

CREATE FUNCTION production.structure_lines_cycle_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_hit integer;
BEGIN
    WITH RECURSIVE down(parent, comp) AS (
        SELECT s.product_id, n.component_id FROM new_lines n JOIN production.structure s ON s.id = n.structure_id
        UNION
        SELECT d.parent, l.component_id FROM down d
        JOIN production.structure s ON s.product_id = d.comp AND s.active
        JOIN production.structure_line l ON l.structure_id = s.id
    )
    SELECT parent INTO v_hit FROM down WHERE comp = parent LIMIT 1;
    IF v_hit IS NOT NULL THEN
        RAISE EXCEPTION 'STRUCTURE_CYCLE: a estrutura faria o item conter a si mesmo' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER structure_lines_cycle_insert AFTER INSERT ON production.structure_line
    REFERENCING NEW TABLE AS new_lines FOR EACH STATEMENT EXECUTE FUNCTION production.structure_lines_cycle_guard();
CREATE TRIGGER structure_lines_cycle_update AFTER UPDATE ON production.structure_line
    REFERENCING NEW TABLE AS new_lines FOR EACH STATEMENT EXECUTE FUNCTION production.structure_lines_cycle_guard();

REVOKE EXECUTE ON FUNCTION production.structure_lines_cycle_guard() FROM PUBLIC;
