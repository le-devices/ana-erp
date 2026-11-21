-- 036 — Access trail accepts the public API credentials (spec 010 + spec 024)
ALTER TABLE ana_system.access_event DROP CONSTRAINT access_event_auth_check;
ALTER TABLE ana_system.access_event ADD CONSTRAINT access_event_auth_check
    CHECK (auth IN ('session', 'api_key', 'password', 'anonymous', 'node', 'api_token', 'publishable'));
