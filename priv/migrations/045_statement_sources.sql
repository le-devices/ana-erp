-- T-017-05b: where each bank account's statement comes from, fetched by a routine — a folder of the file
-- repository (OFX or CNAB 240 files dropped there) or the bank's API (connector + adapter program).

CREATE TABLE finance.statement_source (
    bank_account text PRIMARY KEY REFERENCES finance.bank_account(code) ON UPDATE CASCADE ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('folder', 'api')),
    folder       text,                                         -- repository path, e.g. /Extratos/ITAU
    connector    text,                                         -- integration.connector (kind http_api)
    adapter      text,                                         -- program that talks to the bank
    options      jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(options) = 'object'),   -- for the adapter (path, account at the bank)
    since        date,                                         -- api: next fetch starts here
    active       boolean NOT NULL DEFAULT true,
    last_run_at  timestamptz,
    last_status  text,
    last_lines   integer,
    updated_by   text NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (kind <> 'folder' OR folder IS NOT NULL),
    CHECK (kind <> 'api' OR (connector IS NOT NULL AND adapter IS NOT NULL))
);
COMMENT ON TABLE finance.statement_source IS 'Fonte automática do extrato de cada conta: pasta de arquivos (OFX, CNAB 240) ou API do banco';

-- Files of a folder already read (one version once): dropping the same file again changes nothing.
CREATE TABLE finance.statement_file (
    file_id      bigint NOT NULL,
    version      integer NOT NULL,
    bank_account text NOT NULL,
    statement_id bigint REFERENCES finance.bank_statement(id),
    status       text NOT NULL CHECK (status IN ('imported', 'failed')),
    error        text,
    read_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (file_id, version)
);

ALTER TABLE finance.bank_statement DROP CONSTRAINT IF EXISTS bank_statement_source_check;
ALTER TABLE finance.bank_statement ADD CONSTRAINT bank_statement_source_check
    CHECK (source IN ('ofx', 'csv', 'cnab240', 'cnab400', 'api', 'lines'));

GRANT SELECT, INSERT, UPDATE, DELETE ON finance.statement_source, finance.statement_file TO ana_exec;
GRANT SELECT ON finance.statement_source, finance.statement_file TO ana_read;
