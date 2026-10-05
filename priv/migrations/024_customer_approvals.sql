-- 024 — Customer acceptance of deliverables on the portal (spec 021, H8, T-021-11)

CREATE TABLE projects.deliverable_acceptance (
    id          bigserial PRIMARY KEY,
    task_id     integer NOT NULL REFERENCES projects.task(id),
    decision    text NOT NULL CHECK (decision IN ('accepted', 'rejected')),
    comment     text NOT NULL DEFAULT '',
    decided_by  text NOT NULL,
    decided_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (decision = 'accepted' OR length(comment) >= 3)
);
CREATE INDEX deliverable_acceptance_task_idx ON projects.deliverable_acceptance (task_id, decided_at DESC);

DO $$
BEGIN
    GRANT SELECT, INSERT ON projects.deliverable_acceptance TO ana_exec;
    GRANT USAGE, SELECT ON projects.deliverable_acceptance_id_seq TO ana_exec;
    GRANT SELECT ON projects.deliverable_acceptance TO ana_read;
END $$;
