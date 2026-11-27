-- 088 — Who invoices a project (spec 008, H6; issue #30): its manager, an administrator, or the finance team —
-- the people in an access group whose routines include the bank statement (finance.import_statement). Restricted to
-- them by default: a user outside such a group never invoices a project they do not manage.
INSERT INTO ana_system.access_group (name, description, program_patterns)
VALUES ('finance', 'Financeiro: extrato, conciliação, títulos e faturamento de projetos', ARRAY['finance.*'])
ON CONFLICT DO NOTHING;

-- Programs never read ana_system (P10): one narrow answer.
CREATE FUNCTION projects.is_finance(p_user text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
    SELECT EXISTS (
        SELECT 1 FROM ana_system.app_user u WHERE u.username = p_user AND u.active
           AND (u.role = 'admin' OR EXISTS (
                SELECT 1 FROM ana_system.user_group ug
                  JOIN ana_system.access_group g ON g.name = ug.group_name
                 CROSS JOIN LATERAL unnest(g.program_patterns) AS pat
                 WHERE ug.username = u.username
                   AND (pat = 'finance.import_statement'
                        OR (right(pat, 1) = '*'
                            AND starts_with('finance.import_statement', left(pat, -1)))))))
$$;
REVOKE ALL ON FUNCTION projects.is_finance(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION projects.is_finance(text) TO ana_exec;

-- The usage simulation's finance persona is in the finance team (spec 067: personas meet the real permissions).
UPDATE ana_system.sim_persona SET groups = array_append(groups, 'finance')
 WHERE name = 'financeiro' AND NOT 'finance' = ANY (groups);
