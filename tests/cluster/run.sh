#!/bin/sh
# Runs the cluster tests and restores the single-node environment afterwards.
set -eu
cd "$(dirname "$0")/../.."
COMPOSE="docker compose -f docker-compose.yml -f tests/cluster/docker-compose.cluster.yml"
$COMPOSE up -d --build
status=0
python3 -m unittest discover -s tests/cluster -v || status=$?
$COMPOSE stop ana2 && $COMPOSE rm -f ana2 >/dev/null
docker compose up -d --remove-orphans
exit $status
