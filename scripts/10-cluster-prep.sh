#!/bin/sh
# 10 — Wait for the 5-node cluster (server + 4 agents) and apply the provided
# node preparation: spot/on-demand labels and the tainted GPU node.
# Idempotent: prepare.sh uses --overwrite.
set -eu
. /scripts/lib/common.sh

log "waiting for nodes"
wait_for_nodes 5
kubectl get nodes

log "node preparation (troubleshoot/prepare.sh)"
sh /workspace/troubleshoot/prepare.sh
