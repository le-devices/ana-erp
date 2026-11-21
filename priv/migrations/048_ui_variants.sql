-- Spec 020 (RF-020-17, RF-020-18): what each person leaves on a screen comes back on the next visit, on any
-- computer — table variants (columns, order, sorting, filters; named, one default) and screen state (position
-- of the dividers, collapsed panels, pinned header).

CREATE TABLE ana_system.ui_variant (
    id         bigserial PRIMARY KEY,
    username   text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    screen     text NOT NULL CHECK (length(screen) BETWEEN 1 AND 200),
    name       text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
    is_default boolean NOT NULL DEFAULT false,
    state      jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object' AND pg_column_size(state) <= 16384),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ui_variant_name ON ana_system.ui_variant (username, screen, lower(btrim(name)));
CREATE UNIQUE INDEX ui_variant_default ON ana_system.ui_variant (username, screen) WHERE is_default;
COMMENT ON TABLE ana_system.ui_variant IS 'Variantes de tabela por usuário e tela: colunas, ordem, ordenação e filtros';

CREATE TABLE ana_system.ui_setting (
    username   text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    key        text NOT NULL CHECK (length(key) BETWEEN 1 AND 200),
    value      jsonb NOT NULL CHECK (pg_column_size(value) <= 4096),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (username, key)
);
COMMENT ON TABLE ana_system.ui_setting IS 'Estado de tela por usuário: divisores, painéis recolhidos, cabeçalho fixado';
