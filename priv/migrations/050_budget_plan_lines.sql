-- Spec 020 (RF-020-15) on spec 027 (RF-027-05): the budget planning grid keeps, per cost center × account,
-- its situation and a comment besides the monthly amounts (finance.cost_center_budget).
CREATE TABLE finance.cost_center_budget_line (
    cost_center text NOT NULL REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    account     text NOT NULL REFERENCES finance.account(code),
    status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'review', 'approved')),
    comment     text NOT NULL DEFAULT '' CHECK (length(comment) <= 500),
    updated_by  text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cost_center, account)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON finance.cost_center_budget_line TO ana_exec;
GRANT SELECT ON finance.cost_center_budget_line TO ana_read;
SELECT ana_system.sync_scoped_role();
