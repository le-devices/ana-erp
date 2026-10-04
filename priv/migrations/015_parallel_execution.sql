-- 015 — Parallel execution: parts of an execution and two-phase commit decisions (spec 022)

-- RF-022-07: parts point to the main execution.
ALTER TABLE ana_system.execution ADD COLUMN parent_execution_id uuid;
CREATE INDEX execution_parent_idx ON ana_system.execution (parent_execution_id)
    WHERE parent_execution_id IS NOT NULL;

-- RF-022-04: commit decision written before COMMIT PREPARED, so recovery
-- after a crash finishes what was decided (and undoes everything else).
CREATE TABLE ana_system.parallel_decision (
    main_gid   text PRIMARY KEY,
    gids       text[] NOT NULL,
    decision   text NOT NULL CHECK (decision IN ('commit')),
    node       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
