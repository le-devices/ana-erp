#!/bin/sh
# Verified restore (spec 023, RF-023-06): restores the latest base backup in a
# throwaway container, replays the archived WAL up to a point in time and
# checks the restored database. Nothing touches the running database.
#
#   scripts/restore-test.sh ["2026-10-04 12:00:00+00"] [extra SQL check]
#
# Prints the result of the check; exits non-zero if the restore fails.
set -eu
cd "$(dirname "$0")/.."
TARGET=${1:-}
CHECK=${2:-SELECT count(*) FROM ana_system.migration}
VOLUME=$(docker volume ls -q | grep -E '(^|_)wal_archive$' | head -1)
IMAGE=citusdata/citus:12.1
# Recovery needs these at least as high as on the primary (docker-compose.yml).
PG_ARGS=${ANA_RESTORE_PG_ARGS:--c max_connections=300 -c max_prepared_transactions=600}
NAME=ana-restore-test-$$
[ -n "$VOLUME" ] || { echo "wal_archive volume not found" >&2; exit 1; }

RECOVERY="restore_command = 'cp /archive/wal/%f %p'"
[ -n "$TARGET" ] && RECOVERY="$RECOVERY
recovery_target_time = '$TARGET'
recovery_target_action = 'promote'"

docker run -d --name "$NAME" -v "$VOLUME":/archive:ro -e POSTGRES_PASSWORD=restore \
  --entrypoint sh "$IMAGE" -c "
    set -e
    base=\$(ls -1d /archive/base/base-* | tail -1)
    mkdir -p /tmp/pg
    tar -xzf \$base/base.tar.gz -C /tmp/pg
    chown -R postgres /tmp/pg && chmod 700 /tmp/pg
    printf '%s\n' \"$RECOVERY\" >> /tmp/pg/postgresql.auto.conf
    chown postgres /tmp/pg/postgresql.auto.conf
    su postgres -c 'touch /tmp/pg/recovery.signal'
    exec su postgres -c 'postgres -D /tmp/pg -c archive_mode=off -c shared_preload_libraries=citus $PG_ARGS'
  " >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  if docker exec "$NAME" su postgres -c "psql -At -d ana -c 'SELECT NOT pg_is_in_recovery()'" 2>/dev/null | grep -q t; then
    docker exec "$NAME" su postgres -c "psql -At -d ana -c \"$CHECK\""
    exit 0
  fi
  sleep 1
done
echo "restore did not finish" >&2
docker logs --tail 30 "$NAME" >&2
exit 1
