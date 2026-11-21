-- Spec 023 (RF-023-08): sessions and the public API's anti-replay nonces survive a primary switch-over and a
-- crash. As UNLOGGED tables they were never streamed to the replica (a promoted replica had no session: every
-- user was signed out once the core's cache expired) and were emptied by crash recovery; a lost nonce also let
-- a signed request captured just before a switch-over be replayed. Both are small and written seldom (sign-in
-- and sign-out; one row per signed request), so the WAL they add is negligible.
ALTER TABLE ana_system.session SET LOGGED;
ALTER TABLE ana_system.api_nonce SET LOGGED;
