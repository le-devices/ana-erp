-- 071 — Home panel (spec 048): indicator programs, the company's spaces of blocks published by access group.

-- D1: "# ana:indicator <seconds>" in the program header — a light, read-only program whose answer
-- {value, status, text} is shown on a block, cached per user for that many seconds.
ALTER TABLE ana_system.program ADD COLUMN indicator_refresh_s integer CHECK (indicator_refresh_s BETWEEN 60 AND 86400);

-- D2: spaces the company publishes to access groups (none = everyone), each with its blocks.
CREATE TABLE ana_system.home_space (
    id             serial PRIMARY KEY,
    name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 60),
    description    text NOT NULL DEFAULT '' CHECK (length(description) <= 300),
    position       integer NOT NULL DEFAULT 0,
    access_groups  text[] NOT NULL DEFAULT '{}' CHECK (array_position(access_groups, NULL) IS NULL),
    updated_by     text NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    product_blocks boolean NOT NULL DEFAULT false   -- the product's blocks were added once (never again, if removed)
);
CREATE UNIQUE INDEX home_space_name_uk ON ana_system.home_space (lower(btrim(name)));
COMMENT ON TABLE ana_system.home_space IS 'Espaços do painel inicial publicados por grupo de acesso (spec 048)';

CREATE TABLE ana_system.home_block (
    id                serial PRIMARY KEY,
    space_id          integer NOT NULL REFERENCES ana_system.home_space(id) ON DELETE CASCADE,
    position          integer NOT NULL DEFAULT 0,
    title             text NOT NULL CHECK (length(btrim(title)) BETWEEN 2 AND 80),
    program           text NOT NULL REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE CASCADE,
    variant_id        integer REFERENCES ana_system.run_variant(id) ON DELETE SET NULL,
    params            jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    indicator         text REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE SET NULL,
    indicator_params  jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(indicator_params) = 'object'),
    size              text NOT NULL DEFAULT 'medium' CHECK (size IN ('small', 'medium', 'wide'))
);
CREATE INDEX home_block_space_idx ON ana_system.home_block (space_id, position);
COMMENT ON TABLE ana_system.home_block IS 'Blocos dos espaços do painel inicial: rotina que abre e indicador (spec 048)';

-- The product's space, for everyone; its blocks are added once by the seed, after the programs exist.
INSERT INTO ana_system.home_space (name, description, position, updated_by)
VALUES ('Visão geral', 'O que pede atenção agora: pedidos com falta, títulos vencidos, compras a aprovar.', 0, 'ana');
