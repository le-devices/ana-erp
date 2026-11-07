-- 060 — Interface performance (spec 050, T-050-03; P18 budget): per day, screen and kind, a histogram
-- of durations sent by the browsers. One row per screen/kind/day, updated at most once a minute (P15).
CREATE TABLE ana_system.ui_perf (
    day         date NOT NULL,
    screen      text NOT NULL CHECK (length(screen) BETWEEN 1 AND 120),
    kind        text NOT NULL CHECK (kind IN ('open', 'api')),
    samples     bigint NOT NULL DEFAULT 0,
    total_ms    bigint NOT NULL DEFAULT 0,
    buckets     bigint[] NOT NULL,                 -- counts <= 50, 100, 200, 500, 1000, 2000, 5000 ms, and above
    long_tasks  bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (day, screen, kind)
);
COMMENT ON TABLE ana_system.ui_perf IS 'Desempenho das telas medido nos navegadores (spec 050): histograma por dia, tela e tipo';
