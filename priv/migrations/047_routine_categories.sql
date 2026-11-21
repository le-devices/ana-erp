-- Spec 020 (RF-020-19..23): routines by business area and category; categories made by the company and by
-- each person, holding shortcuts to routines (the routine stays one: same version, permissions and history).

-- "Área/Categoria" declared in the program's header (# ana:category …); kept by the core on every save.
ALTER TABLE ana_system.program ADD COLUMN category text;
UPDATE ana_system.program SET category = btrim(substring(source from '#[ \t]*ana:category[ \t]+([^\r\n]+)'))
 WHERE source ~ '#[ \t]*ana:category[ \t]+';

CREATE TABLE ana_system.routine_category (
    id         bigserial PRIMARY KEY,
    name       text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 60),
    owner      text REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,  -- NULL = the company's
    groups     text[] NOT NULL DEFAULT '{}',          -- company category: groups that see it (empty = everyone)
    position   integer NOT NULL DEFAULT 0,
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX routine_category_name ON ana_system.routine_category (COALESCE(owner, ''), lower(btrim(name)));
COMMENT ON TABLE ana_system.routine_category IS 'Categorias de rotinas: pessoais (owner) ou da empresa (owner nulo, visíveis aos grupos)';

CREATE TABLE ana_system.routine_shortcut (
    id          bigserial PRIMARY KEY,
    category_id bigint NOT NULL REFERENCES ana_system.routine_category(id) ON DELETE CASCADE,
    program     text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    label       text CHECK (label IS NULL OR length(btrim(label)) BETWEEN 2 AND 80),
    params      jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    position    integer NOT NULL DEFAULT 0,
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX routine_shortcut_category_idx ON ana_system.routine_shortcut (category_id, position);
CREATE INDEX routine_shortcut_program_idx ON ana_system.routine_shortcut (program);
