#!/bin/sh
# Real primary failover with a local PostgreSQL cluster (spec 023, T-023-09).
# Prepares replication on the primary, starts the replica, two core nodes and the
# balancer, runs the tests and restores the single-node environment afterwards
# (the replica lives in memory; the primary is kept).
set -eu
cd "$(dirname "$0")/../.."
FILES="-f docker-compose.yml -f tests/cluster/docker-compose.cluster.yml -f tests/chaos/docker-compose.chaos.yml -f tests/pg_ha/docker-compose.pg-ha.yml"
COMPOSE="docker compose $FILES"
PW=${ANA_TEST_REPL_PASSWORD:-repl-test-password}
$COMPOSE up -d db
until $COMPOSE exec -T db pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
$COMPOSE exec -T db psql -U postgres -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator REPLICATION LOGIN PASSWORD '$PW';
  END IF; END \$\$;" -c "SELECT pg_drop_replication_slot('db2_slot') FROM pg_replication_slots WHERE slot_name = 'db2_slot'"
$COMPOSE exec -T db sh -c 'grep -q "^host replication replicator" "$PGDATA/pg_hba.conf" || echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
$COMPOSE exec -T db psql -U postgres -c "SELECT pg_reload_conf()" >/dev/null
$COMPOSE up -d --build
status=0
python3 -m unittest discover -s tests/pg_ha -v || status=$?
# On failure, keep what the replica said before it is removed (diagnosis on CI, where nothing survives the run).
[ "$status" = 0 ] || { echo "---- db2 (replica) log"; $COMPOSE logs --no-color --tail 120 db2 || true; }
$COMPOSE stop ana2 lb db2 && $COMPOSE rm -f ana2 lb db2 >/dev/null
$COMPOSE exec -T db psql -U postgres -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'db2_slot'" >/dev/null 2>&1 || true
docker compose up -d --remove-orphans
exit $status
