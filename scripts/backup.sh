#!/bin/sh
# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
# Continuous backup of the database (spec 023, RF-023-06).
#
#   scripts/backup.sh enable   turns on WAL archiving (restarts the database once)
#   scripts/backup.sh base     takes a base backup (run daily, e.g. from cron)
#   scripts/backup.sh list     lists base backups and archived WAL
#
# Archive and backups live in the "wal_archive" volume, mounted in the db
# container at /var/lib/postgresql/archive. In production, copy that volume
# to another machine or object storage (a backup on the same disk is not a backup).
# P15: archiving writes every WAL segment once more; it is off by default in
# development and mandatory in production.
set -eu
cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
ARCHIVE=/var/lib/postgresql/archive

# Spec 033: the ERP checks the age of the last good backup (Administração → Verificações).
record() {
  $COMPOSE exec -T db psql -U postgres -d "${ANA_DB_NAME:-ana}" -q -v ON_ERROR_STOP=1 \
    -c "INSERT INTO ana_system.ops_event (kind, ok, detail) VALUES ('backup_base', $1, '$2')" >/dev/null 2>&1 \
    || echo "warning: could not record the backup event in the ERP" >&2
}

case "${1:-}" in
  enable)
    $COMPOSE exec -T -u root db sh -c "mkdir -p $ARCHIVE/wal $ARCHIVE/base && chown -R postgres:postgres $ARCHIVE"
    $COMPOSE exec -T db psql -U postgres -v ON_ERROR_STOP=1 \
      -c "ALTER SYSTEM SET archive_mode = 'on'" \
      -c "ALTER SYSTEM SET archive_command = 'test ! -f $ARCHIVE/wal/%f && cp %p $ARCHIVE/wal/%f'" \
      -c "ALTER SYSTEM SET archive_timeout = '${ANA_PG_ARCHIVE_TIMEOUT:-300}'"
    $COMPOSE restart db
    echo "WAL archiving enabled; take a base backup now: scripts/backup.sh base"
    ;;
  base)
    name="base-$(date -u +%Y%m%dT%H%M%SZ)"
    if $COMPOSE exec -T -u postgres db sh -c "pg_basebackup -U postgres -D $ARCHIVE/base/$name -Ft -z -X fetch --checkpoint=fast"; then
      record true "$name"
      echo "$name"
    else
      record false "$name"
      exit 1
    fi
    ;;
  list)
    $COMPOSE exec -T db sh -c "ls -1 $ARCHIVE/base; echo; ls $ARCHIVE/wal | wc -l | xargs echo 'archived WAL segments:'"
    ;;
  *)
    echo "usage: $0 enable | base | list" >&2
    exit 2
    ;;
esac
