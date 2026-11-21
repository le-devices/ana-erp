-- Spec 039 (T-039-17b) and 032: programs choose connectors (a process started by a message, the geocoder) and need to
-- see which exist — only the harmless columns: name, kind, state and the programs that handle them. Addresses,
-- options and secrets stay with the core.
GRANT SELECT (name, kind, active, inbound_program, outbound_program) ON integration.connector TO ana_exec;
SELECT ana_system.sync_scoped_role();
