-- Run once by the superuser when the volume is created.
-- The core does NOT use a superuser (P10): role "ana" owns the database and
-- can only create the roles it administers (ana_exec, ana_read).
\set ana_password `echo "$ANA_DB_PASSWORD"`
CREATE ROLE ana LOGIN CREATEROLE PASSWORD :'ana_password';
CREATE DATABASE ana OWNER ana ENCODING 'UTF8' TEMPLATE template0;
REVOKE ALL ON DATABASE ana FROM PUBLIC;
\c ana
ALTER SCHEMA public OWNER TO ana;
-- Spec 007: columnar storage and buffer prewarming, enabled by the superuser so
-- the core (non-superuser) only needs to use them.
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
-- Lets the core show memory/extension settings in the admin monitor (read-only).
GRANT pg_read_all_settings TO ana;
