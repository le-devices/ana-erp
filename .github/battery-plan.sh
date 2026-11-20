#!/usr/bin/env bash
# Which suites of the battery a run needs (minutes are billed: run only what the change can break).
#
#   battery-plan.sh select < files       → the suites the changed files touch ("static integration ...")
#
# The rules, from the narrowest to the widest:
#   - documentation (specs/, *.md) touches nothing;
#   - a test file touches its own suite; the screens touch the Studio suite;
#   - programs, the Python runtime, the core in general and the migrations touch integration, trails and Studio;
#   - the parts the cluster, the failover, the replica and the installation depend on (database access, supervision,
#     listener, events, scheduler, release, image, configuration, this workflow) — and anything unknown — touch all.
# Any code at all also runs "static" (compilation, dialyzer, eunit, runtime: one minute).
set -euo pipefail

ALL="static integration trails studio cluster chaos pgha install"
CORE="static integration trails studio"
INFRA_SRC='^src/ana_(db|ha|listener|sup|area_sup|app|events|parallel|migrate|config|instance|scheduler|scheduler_worker|cron|rpc|http|security|license|health|disk)\.erl$'

select_suites() {
  local out="" f
  add() { local s; for s in "$@"; do case " $out " in *" $s "*) ;; *) out="$out $s" ;; esac; done; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      specs/*|*.md) ;;                                                     # documentation
      priv/www/*|tests/studio/*|tests/a11y/*) add static studio ;;
      tests/integration/*) add static integration ;;
      tests/trails/*) add static trails ;;
      tests/cluster/*) add static cluster ;;
      tests/chaos/*) add static chaos ;;
      tests/pg_ha/*) add static pgha ;;
      tests/install/*) add static install ;;
      tests/runtime/*|test/*) add static ;;
      tests/load/*|tools/*|clients/*) add static ;;
      priv/python/*|priv/programs/*|priv/*.json) add $CORE ;;
      priv/migrations/*) add $ALL ;;                                        # the installation and the replica migrate too
      src/*)
        if printf '%s\n' "$f" | grep -Eq "$INFRA_SRC"; then add $ALL; else add $CORE; fi ;;
      *) add $ALL ;;                                                        # image, release, config, scripts, workflow, unknown
    esac
  done
  echo "${out# }"
}

case "${1:-}" in
  select) select_suites ;;
  *) echo "uso: $0 select < arquivos" >&2; exit 2 ;;
esac
