#!/bin/sh
# 25 — Spot reclaim drill: cordon + drain one spot node while a curl loop hits
# the service through Traefik, show the rescheduling, then uncordon.
# Fails if any request during the drill failed. Uncordons even if the drill fails.
set -eu
. /scripts/lib/common.sh

NS=quote-api
URL=http://server/api/quote
WORK=$(mktemp -d)
LOOP_RESULT="$WORK/result"
trap 'kubectl uncordon "${NODE:-}" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# Pick the first spot node that currently runs a quote-api pod.
NODE=""
for candidate in $(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl get pods -n "$NS" --field-selector "spec.nodeName=$candidate" --no-headers 2>/dev/null | grep -q .; then
    NODE=$candidate
    break
  fi
done
[ -n "$NODE" ] || die "no spot node runs a quote-api pod"

log "before drill: pods"
kubectl get pods -n "$NS" -o wide -L app.kubernetes.io/component

log "starting traffic loop against $URL"
touch "$WORK/running"
(
  ok=0; fail=0
  while [ -f "$WORK/running" ]; do
    if curl -fsS --max-time 2 "$URL" >/dev/null 2>&1; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    sleep 0.2
  done
  echo "$ok $fail" > "$LOOP_RESULT"
) &

log "cordon + drain $NODE (reclaim simulation)"
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s

log "rescheduling: pods after drain"
kubectl rollout status deployment/quote-api -n "$NS" --timeout=300s
kubectl get pods -n "$NS" -o wide -L app.kubernetes.io/component
sleep 5

log "uncordon $NODE"
kubectl uncordon "$NODE"

rm -f "$WORK/running"
wait
read -r ok fail < "$LOOP_RESULT"
echo "requests during drill: ok=$ok failed=$fail"
[ "$fail" -eq 0 ] || die "$fail requests failed during the drill"
echo "PASS: service answered every request while $NODE was drained"
