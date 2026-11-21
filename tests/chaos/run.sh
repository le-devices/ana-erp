#!/bin/sh
# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
# Chaos tests (spec 023): starts two nodes and a balancer, runs the suite and
# restores the single-node environment afterwards.
set -eu
cd "$(dirname "$0")/../.."
COMPOSE="docker compose -f docker-compose.yml -f tests/cluster/docker-compose.cluster.yml -f tests/chaos/docker-compose.chaos.yml"
$COMPOSE up -d --build
status=0
python3 -m unittest discover -s tests/chaos -v || status=$?
$COMPOSE stop ana2 lb && $COMPOSE rm -f ana2 lb >/dev/null
docker compose up -d --remove-orphans
exit $status
