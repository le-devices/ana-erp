-- Spec 010 (RNF-010-10, T-010-06b): circuit breaker per API client.
-- Too many technical failures (internal errors, timeouts) suspend the client for a
-- while on every node (the client cache already follows NOTIFY "ana_api"); each
-- opening is kept with its numbers and, when released by hand, who released it.

ALTER TABLE ana_system.api_client ADD COLUMN suspended_until timestamptz;

CREATE TABLE ana_system.api_breaker_event (
    id          bigserial PRIMARY KEY,
    client_id   text NOT NULL REFERENCES ana_system.api_client(client_id) ON DELETE CASCADE,
    node        text NOT NULL,
    failures    integer NOT NULL CHECK (failures >= 0),
    calls       integer NOT NULL CHECK (calls >= failures),
    opened_at   timestamptz NOT NULL DEFAULT now(),
    until       timestamptz NOT NULL,
    released_by text,
    released_at timestamptz
);
CREATE INDEX api_breaker_event_client_idx ON ana_system.api_breaker_event (client_id, opened_at DESC);
