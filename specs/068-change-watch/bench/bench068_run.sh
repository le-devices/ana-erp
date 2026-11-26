#!/bin/bash
# Spec 068 plan.md measurements on the dev database (container capped). Steady state: no CHECKPOINT between runs,
# the first run of each case is a warm-up and is discarded; cases are interleaved so drift hits all of them.
set -e
C=$(cd /home/andre/ana-erp && docker compose ps -q db)
DIR=$(dirname "$0")
q() { docker exec -i "$C" nice -n 19 psql -U postgres -d ana -v ON_ERROR_STOP=1 -Atq "$@"; }
hot() { local t; t=$(sensors | awk '/Package id 0/ {gsub(/[+°C]/,"",$4); print int($4)}'); while [ "$t" -ge 84 ]; do sleep 20; t=$(sensors | awk '/Package id 0/ {gsub(/[+°C]/,"",$4); print int($4)}'); done; }
q < "$DIR/bench068_setup.sql" >/dev/null 2>&1
RUNS=${RUNS:-9}

trig() {
  local s="DROP TRIGGER IF EXISTS w ON bench068.doc;"
  case $1 in
    row) s="$s CREATE TRIGGER w AFTER UPDATE ON bench068.doc FOR EACH ROW EXECUTE FUNCTION bench068.row_check();";;
    row_once) s="$s CREATE TRIGGER w AFTER UPDATE ON bench068.doc FOR EACH ROW EXECUTE FUNCTION bench068.row_once();";;
    stmt) s="$s CREATE TRIGGER w AFTER UPDATE ON bench068.doc REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION bench068.stmt_check();";;
    stmt_bulk) s="$s CREATE TRIGGER w AFTER UPDATE ON bench068.doc REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION bench068.stmt_bulk();";;
  esac
  s="$s DELETE FROM bench068.rule WHERE entity = 'doc';"
  [ "$2" = on ] && s="$s INSERT INTO bench068.rule VALUES ('doc', 'total', true);"
  q -c "$s"
}
one() {  # case name, statement, run
  q -c "VACUUM bench068.doc" -c "VACUUM bench068.event" -c "VACUUM bench068.event_bulk" -c "VACUUM bench068.event_once"
  q -c "INSERT INTO bench068.result (case_name, run, ms, wal) SELECT '$1', $3, ms, wal FROM bench068.measure(\$s\$$2\$s\$);"
}
W="UPDATE bench068.doc SET total = total + 1"
O="UPDATE bench068.doc SET notes = coalesce(notes,'') || '.'"
CASES=(
  "A none-norule|none|off|$W"   "A row-norule|row|off|$W"   "A stmt-norule|stmt|off|$W"
  "B row-rule|row|on|$W"        "B stmt-rule|stmt|on|$W"    "B stmtbulk-rule|stmt_bulk|on|$W"
  "C none-other|none|off|$O"    "C row-rule-other|row|on|$O" "C stmt-rule-other|stmt|on|$O"
)
for i in $(seq 0 $RUNS); do
  hot
  for c in "${CASES[@]}"; do IFS='|' read -r name v r stmt <<< "$c"; trig $v $r; one "$name" "$stmt" $i; done
done

# Single documents: 200 transactions of 1 update, and 200 transactions of 3 updates of the same document.
ONE="UPDATE bench068.doc SET total = total + 1 WHERE id = (SELECT min(id) FROM bench068.doc);"
THREE="BEGIN; $ONE $ONE $ONE COMMIT;"
single() {  # name, variant, rule, sql
  trig $2 $3; q -c "VACUUM bench068.doc"
  for k in 1 2 3; do
    L0=$(q -c "SELECT pg_current_wal_insert_lsn()"); T0=$(date +%s%N)
    for j in $(seq 1 200); do echo "$4"; done | q >/dev/null
    q -c "INSERT INTO bench068.result (case_name, run, ms, wal) SELECT '$1', $k, ($(date +%s%N)-$T0)/1e6/200, (pg_current_wal_insert_lsn() - '$L0'::pg_lsn)/200"
  done
}
hot
for v in none row row_once stmt; do
  r=on; [ $v = none ] && r=off
  single "D 1doc x1 $v" $v $r "$ONE"
  single "D 1doc x3 $v" $v $r "$THREE"
done
trig none off

# Queue disposal (D8).
q <<'SQL'
CREATE TABLE bench068.q_plain (id bigserial PRIMARY KEY, entity text, row_key text, changes jsonb, at timestamptz DEFAULT now());
CREATE TABLE bench068.q_part (id bigserial, entity text, row_key text, changes jsonb, at timestamptz NOT NULL DEFAULT now()) PARTITION BY RANGE (at);
CREATE TABLE bench068.q_part_d1 PARTITION OF bench068.q_part FOR VALUES FROM ('2026-01-01') TO ('2100-01-01');
INSERT INTO bench068.q_plain (entity, row_key, changes) SELECT 'doc', g::text, '{"total":[1,2]}' FROM generate_series(1,100000) g;
INSERT INTO bench068.q_part (entity, row_key, changes) SELECT 'doc', g::text, '{"total":[1,2]}' FROM generate_series(1,100000) g;
CHECKPOINT;
SQL
q -c "INSERT INTO bench068.result (case_name, run, ms, wal) SELECT 'E queue 100k DELETE x1000', 1, ms, wal FROM bench068.measure(\$s\$DO \$d\$ BEGIN FOR i IN 0..99 LOOP DELETE FROM bench068.q_plain WHERE id IN (SELECT id FROM bench068.q_plain ORDER BY id LIMIT 1000); END LOOP; END \$d\$\$s\$);"
L0=$(q -c "SELECT pg_current_wal_insert_lsn()"); T0=$(date +%s%N)
q -c "VACUUM bench068.q_plain"
q -c "INSERT INTO bench068.result (case_name, run, ms, wal) SELECT 'E queue 100k VACUUM after', 1, ($(date +%s%N)-$T0)/1e6, pg_current_wal_insert_lsn() - '$L0'::pg_lsn"
q -c "INSERT INTO bench068.result (case_name, run, ms, wal) SELECT 'E queue 100k DROP partition', 1, ms, wal FROM bench068.measure('DROP TABLE bench068.q_part_d1');"

# Lock (D5, RNF-068-02): a writer holds an open transaction; installing a trigger with lock_timeout 100 ms.
( q -c "BEGIN; UPDATE bench068.doc SET notes = 'x' WHERE id = (SELECT min(id) FROM bench068.doc); SELECT pg_sleep(3); COMMIT;" >/dev/null ) &
sleep 0.5
T0=$(date +%s%N)
R=$(q -c "SET lock_timeout = '100ms'; CREATE TRIGGER w AFTER UPDATE ON bench068.doc FOR EACH ROW EXECUTE FUNCTION bench068.row_check();" 2>&1 || true)
echo "F install while writer open: $(( ($(date +%s%N)-T0)/1000000 )) ms -> ${R:-ok}"
wait
T0=$(date +%s%N)
q -c "SET lock_timeout = '100ms'; CREATE TRIGGER w AFTER UPDATE ON bench068.doc FOR EACH ROW EXECUTE FUNCTION bench068.row_check(); DROP TRIGGER w ON bench068.doc;"
echo "F install+drop, no writer: $(( ($(date +%s%N)-T0)/1000000 )) ms"

q -F ' | ' -c "SELECT rpad(case_name, 30), count(*), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS ms_med, round(min(ms)::numeric,2), round(max(ms)::numeric,2), percentile_cont(0.5) WITHIN GROUP (ORDER BY wal)::bigint AS wal_med, min(wal), max(wal) FROM bench068.result WHERE run > 0 OR case_name LIKE 'E%' GROUP BY case_name ORDER BY min(seq);"
