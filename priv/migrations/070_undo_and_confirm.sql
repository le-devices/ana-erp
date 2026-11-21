-- 070 — Premium experience, phase 2 (spec 050): the standard undo of reversible routines and the confirmation that
-- says the consequence of irreversible ones.

-- D5 (RF-050-05): a routine offers its undo (ana.offer_undo) in the same transaction as what it undoes. The undo runs
-- once, by the same user, within the time given, as an ordinary execution of the routine that undoes (permission,
-- audit and validation as always); the parameters come from here, never from the screen.
CREATE TABLE ana_system.undo_offer (
    id              uuid PRIMARY KEY,
    execution_id    uuid NOT NULL,                                   -- the execution that offered it
    username        text NOT NULL,
    program         text NOT NULL,                                   -- the routine that did it
    undo_program    text NOT NULL CHECK (undo_program ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
    params          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    label           text NOT NULL CHECK (length(label) BETWEEN 1 AND 200),
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    used_at         timestamptz,
    undo_execution  uuid,
    CHECK (expires_at > created_at)
);
CREATE INDEX undo_offer_user_idx ON ana_system.undo_offer (username, created_at DESC);
CREATE INDEX undo_offer_created_brin ON ana_system.undo_offer USING brin (created_at);
COMMENT ON TABLE ana_system.undo_offer IS 'Desfazer oferecido pelas rotinas reversíveis (spec 050, D5)';

-- D5: "# ana:confirm <consequence>" in the program header — the screen asks before running, saying the consequence.
ALTER TABLE ana_system.program ADD COLUMN confirm text CHECK (length(confirm) BETWEEN 1 AND 300);

-- CA-050-03: undoing the cancellation of a sales order restores, by document, what was cancelled with it. The only way
-- back from "cancelled" the database accepts: a purchase request cancelled by that order's cancellation (its reason
-- says so) and a work order made for that order, once the order itself is open again (reopened in the same
-- transaction). Anything else stays as the rules always said.
CREATE OR REPLACE FUNCTION supply.status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    ok boolean;
BEGIN
    IF NEW.status = OLD.status THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME = 'purchase_order' THEN
        ok := (OLD.status, NEW.status) IN (('draft', 'sent'), ('draft', 'cancelled'), ('sent', 'partially_received'),
               ('sent', 'received'), ('sent', 'cancelled'), ('partially_received', 'received'),
               ('partially_received', 'cancelled'));
    ELSE
        ok := (OLD.status, NEW.status) IN (('draft', 'submitted'), ('draft', 'cancelled'), ('submitted', 'approved'),
               ('submitted', 'rejected'), ('submitted', 'cancelled'), ('approved', 'ordered'), ('approved', 'cancelled'))
              OR (OLD.status = 'cancelled' AND NEW.status IN ('draft', 'submitted', 'approved') AND EXISTS (
                     SELECT 1 FROM supply.purchase_request_line l JOIN sales.sales_order o ON o.id = l.sales_order_id
                      WHERE l.request_id = OLD.id AND o.status = 'OPEN'
                        AND OLD.rejection_reason = 'pedido de venda ' || o.number || ' cancelado'));
    END IF;
    IF NOT ok THEN
        RAISE EXCEPTION 'INVALID_STATE: % não pode passar de % para %', TG_TABLE_NAME, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION production.order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'cancelled' AND NEW.status = 'planned' AND to_jsonb(NEW) - 'status' = to_jsonb(OLD) - 'status'
       AND EXISTS (SELECT 1 FROM sales.sales_order o WHERE o.id = OLD.sales_order_id AND o.status = 'OPEN')
       AND NOT EXISTS (SELECT 1 FROM production.order_component c WHERE c.order_id = OLD.id AND c.issued_qty > 0)
       AND NOT EXISTS (SELECT 1 FROM production.operation_report r WHERE r.order_id = OLD.id) THEN
        RETURN NEW;
    END IF;
    IF OLD.status IN ('closed', 'cancelled') THEN
        RAISE EXCEPTION 'ORDER_CLOSED: ordem % está %', OLD.number, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
        ('planned', 'released'), ('planned', 'cancelled'), ('released', 'in_progress'), ('released', 'cancelled'),
        ('released', 'completed'), ('in_progress', 'completed'), ('in_progress', 'cancelled'), ('completed', 'closed'))) THEN
        RAISE EXCEPTION 'INVALID_STATE: ordem % não pode passar de % para %', OLD.number, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
