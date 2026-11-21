-- 033 — Documents for customers and suppliers, with controlled download (spec 037)
--
-- Rule of the owner: customers never reach internal documents. A folder is "external" when it
-- was made for a partner (created by the core for published documents, or marked by an
-- administrator); only external folders (and what is inside them) can be shared with external
-- accounts or get download links.
ALTER TABLE files.folder ADD COLUMN external boolean NOT NULL DEFAULT false;

CREATE FUNCTION files.is_external(p_folder bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE chain AS (
        SELECT id, parent_id, external FROM files.folder WHERE id = p_folder
        UNION ALL
        SELECT f.id, f.parent_id, f.external FROM files.folder f JOIN chain c ON f.id = c.parent_id)
    SELECT COALESCE(bool_or(external), false) FROM chain
$$;

-- Existing partner folders: "Faturas" of a customer and "Entregáveis" of a project.
UPDATE files.folder s SET external = true
FROM files.folder p
WHERE s.parent_id = p.id AND ((p.entity_kind = 'party' AND s.name = 'Faturas')
                           OR (p.entity_kind = 'project' AND s.name = 'Entregáveis'));
