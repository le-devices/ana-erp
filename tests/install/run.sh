#!/bin/sh
# Installation test (spec 036): installs a second, isolated production stack with deploy/install.sh
# (own project, ports and directory), checks it, upgrades it under load, uninstalls it keeping the
# data, and finally removes everything it created.
set -eu
cd "$(dirname "$0")/../.."
export ANA_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ana-install-XXXXXX")"
export ANA_INSTALL_PROJECT="ana-install-test"
cleanup() {
  [ -x "$ANA_INSTALL_DIR/ana-ctl" ] && "$ANA_INSTALL_DIR/ana-ctl" --dir "$ANA_INSTALL_DIR" uninstall --purge --yes >/dev/null 2>&1 || true
  rm -rf "$ANA_INSTALL_DIR"
}
trap cleanup EXIT
./deploy/install.sh --ip 127.0.0.1 --http-port 18081 --https-port 18443 --nodes 2 --project "$ANA_INSTALL_PROJECT" \
  --dir "$ANA_INSTALL_DIR" --archive-minutes 10 --no-cron --non-interactive
python3 -m unittest -v tests/install/test_install.py
# Kubernetes manifests (RF-036-05): assembled by kustomize and validated against the API schemas.
docker run --rm -v "$PWD/deploy/k8s:/k8s:ro" registry.k8s.io/kustomize/kustomize:v5.4.3 build /k8s \
  | docker run --rm -i ghcr.io/yannh/kubeconform:latest -summary -strict -
