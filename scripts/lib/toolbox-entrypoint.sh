#!/bin/sh
# Starts the toolbox: waits for the k3s server to publish its kubeconfig,
# points it at the in-network API address, runs the node preparation as part of
# the compose bootstrap, then idles for `docker compose exec`.
set -eu

until [ -s /kube/k3s.yaml ]; do
  sleep 2
done

mkdir -p /root/.kube
sed 's#https://127.0.0.1:6443#https://server:6443#' /kube/k3s.yaml > /root/.kube/config
chmod 600 /root/.kube/config

# Bootstrap: label/taint the nodes (troubleshoot/prepare.sh). Idempotent, so
# scripts/10-cluster-prep.sh can safely run it again.
sh /scripts/10-cluster-prep.sh || echo "bootstrap node prep failed; scripts/10-cluster-prep.sh will retry"

echo "toolbox ready"
exec sleep infinity
