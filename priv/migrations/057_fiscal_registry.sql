-- 057 — Fiscal registry of persons (spec 043): alphanumeric CNPJ, CPF, person kind, state and municipal
-- registrations, ICMS taxpayer indicator and tax regime; one rule in the database for every path (D1).

-- ---------------------------------------------------------------- documents (RF-043-01, 02, D2, D3)
-- Only 0-9 and A-Z, upper case: "12.abc.345/01de-35" → "12ABC34501DE35".
CREATE FUNCTION base.tax_id_norm(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT upper(regexp_replace(COALESCE(p, ''), '[^0-9A-Za-z]', '', 'g'))
$$;

-- CPF: 11 digits after normalization (letters are never ignored).
CREATE OR REPLACE FUNCTION base.valid_cpf(p text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE d text := base.tax_id_norm(p); s int; r int; i int;
BEGIN
    IF d !~ '^\d{11}$' OR d ~ '^(\d)\1{10}$' THEN RETURN false; END IF;
    s := 0; FOR i IN 1..9 LOOP s := s + substr(d, i, 1)::int * (11 - i); END LOOP;
    r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
    IF r <> substr(d, 10, 1)::int THEN RETURN false; END IF;
    s := 0; FOR i IN 1..10 LOOP s := s + substr(d, i, 1)::int * (12 - i); END LOOP;
    r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
    RETURN r = substr(d, 11, 1)::int;
END $$;

-- CNPJ, numeric or alphanumeric (Receita Federal, from July 2026): 12 positions 0-9A-Z + 2 numeric check
-- digits; each character is worth its ASCII code − 48 in the same modulo 11 (digits keep their value).
CREATE OR REPLACE FUNCTION base.valid_cnpj(p text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE d text := base.tax_id_norm(p); w int[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2]; s int; r int; i int;
BEGIN
    IF d !~ '^[0-9A-Z]{12}\d{2}$' OR d ~ '^(.)\1{13}$' THEN RETURN false; END IF;
    s := 0; FOR i IN 1..12 LOOP s := s + (ascii(substr(d, i, 1)) - 48) * w[i + 1]; END LOOP;
    r := s % 11; r := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
    IF r <> substr(d, 13, 1)::int THEN RETURN false; END IF;
    s := 0; FOR i IN 1..13 LOOP s := s + (ascii(substr(d, i, 1)) - 48) * w[i]; END LOOP;
    r := s % 11; r := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
    RETURN r = substr(d, 14, 1)::int;
END $$;

CREATE OR REPLACE FUNCTION base.format_tax_id(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN n ~ '^\d{11}$' THEN regexp_replace(n, '^(\d{3})(\d{3})(\d{3})(\d{2})$', '\1.\2.\3-\4')
        WHEN n ~ '^[0-9A-Z]{12}\d{2}$' THEN regexp_replace(n, '^(.{2})(.{3})(.{3})(.{4})(.{2})$', '\1.\2.\3/\4-\5')
        ELSE NULLIF(btrim(p), '') END
    FROM (SELECT base.tax_id_norm(p) AS n) x
$$;

CREATE FUNCTION base.person_kind(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN base.tax_id_norm(p) ~ '^\d{11}$' THEN 'individual'
                WHEN base.tax_id_norm(p) ~ '^[0-9A-Z]{14}$' THEN 'company' END
$$;

-- The first 8 positions of a CNPJ: the same company, any branch (D5).
CREATE FUNCTION base.tax_id_root(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN base.tax_id_norm(p) ~ '^[0-9A-Z]{14}$' THEN left(base.tax_id_norm(p), 8) END
$$;

-- ---------------------------------------------------------------- state registration (RF-043-03)
-- Format by state (length and characters); "ISENTO" for exempt. Check digits per state: T-043-02b.
CREATE FUNCTION base.valid_state_registration(uf text, ie text) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN n = 'ISENTO' THEN true
        WHEN upper(uf) = 'SP' AND n ~ '^P\d{12}$' THEN true          -- rural producer
        WHEN n !~ '^\d+$' THEN false
        ELSE length(n) = ANY (CASE upper(uf)
            WHEN 'AC' THEN ARRAY[13] WHEN 'AL' THEN ARRAY[9] WHEN 'AP' THEN ARRAY[9] WHEN 'AM' THEN ARRAY[9]
            WHEN 'BA' THEN ARRAY[8, 9] WHEN 'CE' THEN ARRAY[9] WHEN 'DF' THEN ARRAY[13] WHEN 'ES' THEN ARRAY[9]
            WHEN 'GO' THEN ARRAY[9] WHEN 'MA' THEN ARRAY[9] WHEN 'MT' THEN ARRAY[9, 11] WHEN 'MS' THEN ARRAY[9]
            WHEN 'MG' THEN ARRAY[13] WHEN 'PA' THEN ARRAY[9] WHEN 'PB' THEN ARRAY[9] WHEN 'PR' THEN ARRAY[10]
            WHEN 'PE' THEN ARRAY[9, 14] WHEN 'PI' THEN ARRAY[9] WHEN 'RJ' THEN ARRAY[8] WHEN 'RN' THEN ARRAY[9, 10]
            WHEN 'RS' THEN ARRAY[10] WHEN 'RO' THEN ARRAY[9, 14] WHEN 'RR' THEN ARRAY[9] WHEN 'SC' THEN ARRAY[9]
            WHEN 'SP' THEN ARRAY[12] WHEN 'SE' THEN ARRAY[9] WHEN 'TO' THEN ARRAY[9, 11]
            ELSE ARRAY[]::int[] END)
    END
    FROM (SELECT base.tax_id_norm(ie) AS n) x
$$;

-- ---------------------------------------------------------------- fiscal data (D4)
ALTER TABLE base.party
    ADD COLUMN person_kind text CHECK (person_kind IN ('individual', 'company', 'foreign')),
    ADD COLUMN country text NOT NULL DEFAULT 'BR' CHECK (country ~ '^[A-Z]{2}$'),
    ADD COLUMN foreign_id text CHECK (length(foreign_id) BETWEEN 1 AND 40),
    ADD COLUMN state_registration text,
    ADD COLUMN icms_taxpayer text CHECK (icms_taxpayer IN ('taxpayer', 'exempt', 'non_taxpayer')),
    ADD COLUMN municipal_registration text CHECK (length(municipal_registration) BETWEEN 1 AND 20),
    ADD COLUMN tax_regime text CHECK (tax_regime IN ('simples', 'simples_excess', 'presumed', 'real', 'mei', 'public',
                                                     'nonprofit')),
    ADD COLUMN final_consumer boolean;
ALTER TABLE base.company
    ADD COLUMN person_kind text CHECK (person_kind IN ('individual', 'company', 'foreign')),
    ADD COLUMN country text NOT NULL DEFAULT 'BR' CHECK (country ~ '^[A-Z]{2}$'),
    ADD COLUMN state_registration text,
    ADD COLUMN icms_taxpayer text CHECK (icms_taxpayer IN ('taxpayer', 'exempt', 'non_taxpayer')),
    ADD COLUMN municipal_registration text CHECK (length(municipal_registration) BETWEEN 1 AND 20),
    ADD COLUMN tax_regime text CHECK (tax_regime IN ('simples', 'simples_excess', 'presumed', 'real', 'mei', 'public',
                                                     'nonprofit'));
ALTER TABLE projects.employee ADD COLUMN tax_id text UNIQUE;

-- Existing documents: the kind only (nothing is revalidated, RNF-043-01).
UPDATE base.party SET person_kind = base.person_kind(tax_id) WHERE tax_id IS NOT NULL;
UPDATE base.company SET person_kind = base.person_kind(tax_id);

CREATE INDEX party_tax_root_idx ON base.party (base.tax_id_root(tax_id)) WHERE person_kind = 'company';

-- ---------------------------------------------------------------- one rule for every path (D1)
-- Checked only when a fiscal field changes: old rows stay editable (RNF-043-01).
CREATE FUNCTION base.fiscal_profile() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE other record;
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.tax_id, NEW.country, NEW.state_registration, NEW.icms_taxpayer, NEW.tax_regime, NEW.state)
       IS NOT DISTINCT FROM (OLD.tax_id, OLD.country, OLD.state_registration, OLD.icms_taxpayer, OLD.tax_regime, OLD.state) THEN
        RETURN NEW;
    END IF;
    NEW.tax_id := NULLIF(btrim(NEW.tax_id), '');
    IF NEW.country <> 'BR' THEN
        IF NEW.tax_id IS NOT NULL THEN
            RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: estrangeiro não tem CNPJ/CPF: use a identificação estrangeira'
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.person_kind := 'foreign';
    ELSE
        IF NEW.tax_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.tax_id IS DISTINCT FROM OLD.tax_id) THEN
            IF NOT base.valid_tax_id(NEW.tax_id) THEN
                RAISE EXCEPTION 'INVALID_TAX_ID: CNPJ/CPF % inválido: confira os números e letras (dígito verificador)', NEW.tax_id
                    USING ERRCODE = 'check_violation';
            END IF;
            NEW.tax_id := base.format_tax_id(NEW.tax_id);
            IF TG_TABLE_NAME = 'party' THEN
                SELECT id, name INTO other FROM base.party WHERE tax_id = NEW.tax_id AND id IS DISTINCT FROM NEW.id LIMIT 1;
                IF FOUND THEN
                    RAISE EXCEPTION 'DUPLICATE_TAX_ID: CNPJ/CPF % já está no cadastro "%" (%): use esse cadastro',
                        NEW.tax_id, other.name, other.id USING ERRCODE = 'check_violation';
                END IF;
            END IF;
        END IF;
        NEW.person_kind := base.person_kind(NEW.tax_id);
    END IF;
    -- State registration: normalized; "ISENTO" means exempt; a taxpayer needs one, a non-taxpayer has none.
    NEW.state_registration := NULLIF(base.tax_id_norm(NEW.state_registration), '');
    IF NEW.state_registration IS NOT NULL THEN
        IF NEW.country <> 'BR' THEN
            RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: inscrição estadual é só para quem está no Brasil' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.state_registration <> 'ISENTO' AND NEW.state IS NULL THEN
            RAISE EXCEPTION 'INVALID_STATE_REGISTRATION: informe a UF para conferir a inscrição estadual' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT base.valid_state_registration(COALESCE(NEW.state, ''), NEW.state_registration) THEN
            RAISE EXCEPTION 'INVALID_STATE_REGISTRATION: inscrição estadual % não tem o formato de %', NEW.state_registration, NEW.state
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.state_registration = 'ISENTO' THEN
            NEW.icms_taxpayer := COALESCE(NEW.icms_taxpayer, 'exempt');
        END IF;
    END IF;
    IF NEW.icms_taxpayer = 'non_taxpayer' AND NEW.state_registration IS NOT NULL AND NEW.state_registration <> 'ISENTO' THEN
        RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: não contribuinte do ICMS não tem inscrição estadual' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.icms_taxpayer = 'taxpayer' AND (NEW.state_registration IS NULL OR NEW.state_registration = 'ISENTO') THEN
        RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: contribuinte do ICMS precisa da inscrição estadual' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.icms_taxpayer = 'exempt' AND NEW.state_registration IS NOT NULL AND NEW.state_registration <> 'ISENTO' THEN
        RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: isento do ICMS: use ISENTO na inscrição estadual ou mude o indicador'
            USING ERRCODE = 'check_violation';
    END IF;
    -- Regimes are of companies (MEI included).
    IF NEW.tax_regime IS NOT NULL AND NEW.person_kind IS DISTINCT FROM 'company' THEN
        RAISE EXCEPTION 'TAX_PROFILE_MISMATCH: regime tributário só para pessoa jurídica (informe o CNPJ)' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER party_tax_id ON base.party;
DROP FUNCTION base.party_tax_id();
CREATE TRIGGER fiscal_profile BEFORE INSERT OR UPDATE ON base.party
    FOR EACH ROW EXECUTE FUNCTION base.fiscal_profile();
CREATE TRIGGER fiscal_profile BEFORE INSERT OR UPDATE ON base.company
    FOR EACH ROW EXECUTE FUNCTION base.fiscal_profile();

-- People who work for the company: CPF only.
CREATE FUNCTION base.employee_tax_id() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.tax_id IS DISTINCT FROM OLD.tax_id THEN
        NEW.tax_id := NULLIF(btrim(NEW.tax_id), '');
        IF NEW.tax_id IS NOT NULL THEN
            IF NOT base.valid_cpf(NEW.tax_id) THEN
                RAISE EXCEPTION 'INVALID_TAX_ID: CPF % inválido: confira os números (dígito verificador)', NEW.tax_id
                    USING ERRCODE = 'check_violation';
            END IF;
            NEW.tax_id := base.format_tax_id(NEW.tax_id);
            IF EXISTS (SELECT 1 FROM projects.employee WHERE tax_id = NEW.tax_id AND id IS DISTINCT FROM NEW.id) THEN
                RAISE EXCEPTION 'DUPLICATE_TAX_ID: CPF % já está em outro colaborador', NEW.tax_id USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER employee_tax_id BEFORE INSERT OR UPDATE OF tax_id ON projects.employee
    FOR EACH ROW EXECUTE FUNCTION base.employee_tax_id();

COMMENT ON COLUMN base.party.person_kind IS 'Pessoa física, jurídica ou estrangeira: mantido pelo banco a partir do documento';
COMMENT ON COLUMN base.party.icms_taxpayer IS 'Indicador de contribuinte do ICMS: contribuinte, isento ou não contribuinte';
COMMENT ON COLUMN base.party.final_consumer IS 'Consumidor final (vazio: o motor de impostos decide pelo tipo de pessoa)';

-- The CNPJ lookup (D6) finds its connector by options.purpose; options hold no secrets (the vault does).
GRANT SELECT (options) ON integration.connector TO ana_exec;
