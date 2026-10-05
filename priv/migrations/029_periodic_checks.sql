-- 029 — Periodic checks: security, vulnerable components, integrity, robustness, performance (spec 033)

-- RF-033-08: one finding model for the advisor (spec 019) and the checks.
ALTER TABLE ana_system.advice ADD COLUMN category text NOT NULL DEFAULT 'performance'
    CHECK (category IN ('security', 'dependencies', 'integrity', 'robustness', 'performance'));
UPDATE ana_system.advice SET category = CASE rule
    WHEN 'file_integrity' THEN 'integrity'
    WHEN 'near_limit' THEN 'robustness'
    WHEN 'recurring_timeouts' THEN 'robustness'
    ELSE 'performance' END
WHERE category IS DISTINCT FROM CASE rule
    WHEN 'file_integrity' THEN 'integrity'
    WHEN 'near_limit' THEN 'robustness'
    WHEN 'recurring_timeouts' THEN 'robustness'
    ELSE 'performance' END;
CREATE INDEX advice_category_idx ON ana_system.advice (category, status);

-- RF-033-01: current inventory of the installation (rewritten only when it changes, P15).
CREATE TABLE ana_system.component (
    ecosystem  text NOT NULL CHECK (length(ecosystem) BETWEEN 1 AND 40),
    name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    version    text NOT NULL CHECK (length(version) BETWEEN 1 AND 100),
    source     text NOT NULL CHECK (source IN ('runtime', 'image', 'database')),
    node       text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (ecosystem, name)
);

-- RF-033-02: OSV advisories, one row per affected range of a package.
CREATE TABLE ana_system.vulnerability (
    id            bigserial PRIMARY KEY,
    osv_id        text NOT NULL CHECK (length(osv_id) BETWEEN 1 AND 100),
    ecosystem     text NOT NULL CHECK (length(ecosystem) BETWEEN 1 AND 60),
    package       text NOT NULL CHECK (length(package) BETWEEN 1 AND 200),
    introduced    text,
    fixed         text,
    last_affected text,
    versions      text[] NOT NULL DEFAULT '{}',
    severity      text NOT NULL CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    summary       text NOT NULL DEFAULT '',
    aliases       text[] NOT NULL DEFAULT '{}',
    modified      timestamptz,
    imported_by   text NOT NULL,
    imported_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX vulnerability_package_idx ON ana_system.vulnerability (lower(package));
CREATE INDEX vulnerability_osv_idx ON ana_system.vulnerability (osv_id);

-- RF-033-05: operational events written outside the core (backup.sh, restore-test.sh).
CREATE TABLE ana_system.ops_event (
    id     bigserial PRIMARY KEY,
    kind   text NOT NULL CHECK (kind ~ '^[a-z_]{3,40}$'),
    ok     boolean NOT NULL,
    detail text NOT NULL DEFAULT '' CHECK (length(detail) <= 2000),
    at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ops_event_kind_idx ON ana_system.ops_event (kind, at DESC);

-- RF-033-06: synthetic probe samples (a few per hour; purged after 30 days).
CREATE TABLE ana_system.perf_sample (
    probe text NOT NULL CHECK (probe ~ '^[a-z_]{3,40}$'),
    at    timestamptz NOT NULL DEFAULT now(),
    ms    real NOT NULL CHECK (ms >= 0)
);
CREATE INDEX perf_sample_probe_idx ON ana_system.perf_sample (probe, at);

-- RF-033-09: system notices for administrators (the bell shows them with the scheduler's).
CREATE TABLE ana_system.notice (
    id         bigserial PRIMARY KEY,
    kind       text NOT NULL CHECK (kind ~ '^[a-z_]{3,40}$'),
    severity   text NOT NULL CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    message    text NOT NULL CHECK (length(message) <= 2000),
    link       text CHECK (link ~ '^#/'),
    read       boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notice_created_idx ON ana_system.notice (created_at DESC);

-- CA-033-06: a dismissed finding comes back when its severity gets worse.
CREATE FUNCTION ana_system.severity_rank(text) RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT CASE $1 WHEN 'critical' THEN 3 WHEN 'serious' THEN 2 WHEN 'warning' THEN 1 ELSE 0 END $$;
