-- ANA ERP on a managed PostgreSQL (spec 036). Run once as the administrator user of the
-- database service (RDS, Cloud SQL, Azure Database…). The core never uses a superuser (P10):
-- role "ana" owns the database and creates only the roles it administers (ana_exec, ana_read).
--   psql "host=… user=<admin> dbname=postgres" -v ana_password='…' -f initdb-managed.sql
CREATE ROLE ana LOGIN CREATEROLE PASSWORD :'ana_password';
GRANT ana TO CURRENT_USER;                -- some services require it to create a database owned by ana
CREATE DATABASE ana OWNER ana ENCODING 'UTF8' TEMPLATE template0;
REVOKE ALL ON DATABASE ana FROM PUBLIC;
\c ana
ALTER SCHEMA public OWNER TO ana;
-- Optional: buffer prewarming and settings view (when the service allows).
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
GRANT pg_read_all_settings TO ana;
-- Columnar analytics (Citus) are optional: without them the ERP uses ordinary tables.
