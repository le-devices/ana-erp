-- 028 — Payment terms, credit limits and blocking for delinquency (spec 031)

CREATE TABLE finance.payment_term (
    code             text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name             text NOT NULL,
    method           text NOT NULL CHECK (method IN ('pix', 'boleto', 'credit_card', 'debit_card', 'direct_credit', 'cash', 'transfer')),
    installments     jsonb NOT NULL CHECK (jsonb_typeof(installments) = 'array' AND jsonb_array_length(installments) BETWEEN 1 AND 48),
    down_payment_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (down_payment_pct BETWEEN 0 AND 100),
    adjust_pct       numeric(5,2) NOT NULL DEFAULT 0 CHECK (adjust_pct BETWEEN -50 AND 100),
    fee_pct          numeric(5,2) NOT NULL DEFAULT 0 CHECK (fee_pct BETWEEN 0 AND 50),
    min_amount       numeric(14,2) NOT NULL DEFAULT 0 CHECK (min_amount >= 0),
    connector        text REFERENCES integration.connector(name) ON UPDATE CASCADE,
    active           boolean NOT NULL DEFAULT true
);
CREATE INDEX payment_term_connector_idx ON finance.payment_term (connector);

-- Installments: [{"days": 30, "pct": 50}, …]; with the down payment they add up to 100 %.
CREATE FUNCTION finance.payment_term_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_sum numeric;
    v_bad integer;
BEGIN
    SELECT COALESCE(sum((x->>'pct')::numeric), 0),
           count(*) FILTER (WHERE (x->>'days') IS NULL OR (x->>'days')::int < 0 OR (x->>'days')::int > 3650
                                 OR (x->>'pct') IS NULL OR (x->>'pct')::numeric <= 0)
      INTO v_sum, v_bad FROM jsonb_array_elements(NEW.installments) x;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'INVALID_INSTALLMENTS: cada parcela precisa de dias (0 a 3650) e percentual positivo'
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_sum + NEW.down_payment_pct <> 100 THEN
        RAISE EXCEPTION 'INVALID_INSTALLMENTS: parcelas (%%) + entrada (%%) devem somar 100%%, somam %', v_sum + NEW.down_payment_pct
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER payment_term_guard BEFORE INSERT OR UPDATE ON finance.payment_term
    FOR EACH ROW EXECUTE FUNCTION finance.payment_term_guard();

-- The product ships two simple terms; companies add theirs (P13).
INSERT INTO finance.payment_term (code, name, method, installments) VALUES
    ('AVISTA', 'À vista', 'transfer', '[{"days": 0, "pct": 100}]'),
    ('D30', 'Boleto 30 dias', 'boleto', '[{"days": 30, "pct": 100}]')
ON CONFLICT DO NOTHING;

CREATE TABLE finance.party_payment_term (
    party_id integer NOT NULL REFERENCES base.party(id),
    term     text NOT NULL REFERENCES finance.payment_term(code) ON UPDATE CASCADE,
    PRIMARY KEY (party_id, term)
);
CREATE INDEX party_payment_term_term_idx ON finance.party_payment_term (term);

CREATE TABLE finance.credit_policy (
    id           integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    auto_block   boolean NOT NULL DEFAULT false,
    grace_days   integer NOT NULL DEFAULT 5 CHECK (grace_days BETWEEN 0 AND 365),
    default_term text REFERENCES finance.payment_term(code) ON UPDATE CASCADE
);
INSERT INTO finance.credit_policy (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE finance.credit_profile (
    party_id     integer PRIMARY KEY REFERENCES base.party(id),
    credit_limit numeric(14,2) CHECK (credit_limit >= 0),
    grace_days   integer CHECK (grace_days BETWEEN 0 AND 365),
    auto_block   boolean,
    default_term text REFERENCES finance.payment_term(code) ON UPDATE CASCADE,
    updated_by   text NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX credit_profile_term_idx ON finance.credit_profile (default_term);

CREATE TABLE finance.credit_block (
    id             bigserial PRIMARY KEY,
    party_id       integer NOT NULL REFERENCES base.party(id),
    reason         text NOT NULL CHECK (length(reason) >= 3),
    until          date,
    blocked_by     text NOT NULL,
    blocked_at     timestamptz NOT NULL DEFAULT now(),
    released_by    text,
    released_at    timestamptz,
    release_reason text,
    CHECK ((released_at IS NULL) = (released_by IS NULL))
);
CREATE INDEX credit_block_active_idx ON finance.credit_block (party_id) WHERE released_at IS NULL;

CREATE TABLE finance.credit_release (
    id             bigserial PRIMARY KEY,
    party_id       integer NOT NULL REFERENCES base.party(id),
    sales_order_id integer REFERENCES sales.sales_order(id),
    scope          text NOT NULL CHECK (scope IN ('order', 'invoice')),
    reason         text NOT NULL CHECK (length(reason) >= 3),
    granted_by     text NOT NULL,
    granted_at     timestamptz NOT NULL DEFAULT now(),
    used_at        timestamptz
);
CREATE INDEX credit_release_party_idx ON finance.credit_release (party_id) WHERE used_at IS NULL;
CREATE INDEX credit_release_order_idx ON finance.credit_release (sales_order_id);

ALTER TABLE sales.sales_order ADD COLUMN payment_term text REFERENCES finance.payment_term(code) ON UPDATE CASCADE;
CREATE INDEX sales_order_payment_term_idx ON sales.sales_order (payment_term);
ALTER TABLE finance.bill ADD COLUMN installment smallint, ADD COLUMN installments smallint,
    ADD COLUMN payment_method text, ADD COLUMN payment_term text REFERENCES finance.payment_term(code) ON UPDATE CASCADE;
CREATE INDEX bill_payment_term_idx ON finance.bill (payment_term);
CREATE INDEX bill_overdue_idx ON finance.bill (party_id, due_date) WHERE status = 'open' AND kind = 'receivable';

-- RF-031-05: one place decides whether a customer may buy (or be invoiced) now.
CREATE FUNCTION finance.credit_status(p_party integer, p_extra numeric DEFAULT 0)
RETURNS TABLE (blocked boolean, reason text, open_amount numeric, open_orders numeric, overdue_amount numeric,
               max_days_overdue integer, credit_limit numeric, available numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_auto boolean;
    v_grace integer;
    v_limit numeric;
    v_manual text;
BEGIN
    SELECT COALESCE(cp.auto_block, pol.auto_block), COALESCE(cp.grace_days, pol.grace_days), cp.credit_limit
      INTO v_auto, v_grace, v_limit
      FROM finance.credit_policy pol LEFT JOIN finance.credit_profile cp ON cp.party_id = p_party WHERE pol.id = 1;
    SELECT b.reason INTO v_manual FROM finance.credit_block b
     WHERE b.party_id = p_party AND b.released_at IS NULL AND (b.until IS NULL OR b.until >= current_date)
     ORDER BY b.blocked_at DESC LIMIT 1;
    SELECT COALESCE(sum(amount), 0),
           COALESCE(sum(amount) FILTER (WHERE due_date < current_date - v_grace), 0),
           COALESCE(max(current_date - due_date) FILTER (WHERE due_date < current_date), 0)
      INTO open_amount, overdue_amount, max_days_overdue
      FROM finance.bill WHERE party_id = p_party AND kind = 'receivable' AND status = 'open';
    SELECT COALESCE(sum(total), 0) INTO open_orders FROM sales.sales_order WHERE customer_id = p_party AND status = 'OPEN';
    credit_limit := v_limit;
    available := CASE WHEN v_limit IS NULL THEN NULL ELSE v_limit - open_amount - open_orders END;
    IF v_manual IS NOT NULL THEN
        blocked := true; reason := 'bloqueio manual: ' || v_manual;
    ELSIF v_auto AND overdue_amount > 0 THEN
        blocked := true; reason := format('inadimplência: %s em atraso há mais de %s dia(s)', to_char(overdue_amount, 'FM999G999G990D00'), v_grace);
    ELSIF v_limit IS NOT NULL AND open_amount + open_orders + COALESCE(p_extra, 0) > v_limit THEN
        blocked := true; reason := format('limite de crédito: disponível %s', to_char(greatest(available, 0), 'FM999G999G990D00'));
    ELSE
        blocked := false; reason := NULL;
    END IF;
    RETURN NEXT;
END $$;

DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON finance.payment_term, finance.party_payment_term, finance.credit_policy,
        finance.credit_profile, finance.credit_block, finance.credit_release TO ana_exec;
    GRANT USAGE, SELECT ON finance.credit_block_id_seq, finance.credit_release_id_seq TO ana_exec;
    GRANT SELECT ON finance.payment_term, finance.party_payment_term, finance.credit_policy, finance.credit_profile,
        finance.credit_block, finance.credit_release TO ana_read;
    REVOKE EXECUTE ON FUNCTION finance.payment_term_guard() FROM PUBLIC;
END $$;
