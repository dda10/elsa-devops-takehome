#!/usr/bin/env bash
# 60 — Part 6: install kube-prometheus-stack, wire quote-api metrics/alert/dashboard,
# then run k6 through the Ingress and record HPA scale-out + placement evidence.
# Results land in loadtest/results-run/ (git-ignored), so a rerun never overwrites the recorded
# evidence committed in loadtest/results/. Idempotent (helm upgrade --install, kubectl apply).
# Set SKIP_LOADTEST=1 to only install the monitoring pieces.
set -euo pipefail
. /scripts/lib/common.sh

STACK_VERSION=92.10.1
NS=quote-api
OUT=/workspace/loadtest/results-run
mkdir -p "$OUT"

log "installing kube-prometheus-stack $STACK_VERSION (OCI chart: no 6 MB repo index download)"
helm upgrade --install kube-prometheus-stack \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version "$STACK_VERSION" -n monitoring --create-namespace \
  -f /workspace/deploy/observability/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m

log "applying ServiceMonitor, PrometheusRule and Grafana dashboard"
kubectl apply -k /workspace/deploy/observability

prom() { curl -fsS -H "Host: prometheus.localhost" http://server/api/v1/query --data-urlencode "query=$1"; }

log "waiting for Prometheus to scrape quote-api"
i=0
until [ "$(prom "sum(up{namespace=\"$NS\"})" | jq -r '.data.result[0].value[1] // 0')" -ge 3 ] 2>/dev/null; do
  i=$((i + 1)); [ "$i" -le 40 ] || die "quote-api targets not up in Prometheus after 4 minutes"
  sleep 6
done
echo "quote-api targets up"

[ "${SKIP_LOADTEST:-0}" = 1 ] && { echo "SKIP_LOADTEST=1: monitoring installed, no load run"; exit 0; }

log "baseline (2 req/s, 60s)"
PROFILE=baseline k6 run --quiet /workspace/loadtest/quote.js 2>&1 | tee "$OUT/k6-baseline.txt" | grep -E "http_req_duration|http_req_failed"

log "scale run: watching HPA and pods while k6 drives load through the Ingress"
RUN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ts() { while IFS= read -r line; do printf '%s %s\n' "$(date +%T)" "$line"; done; }
kubectl get hpa quote-api -n "$NS" -w 2>&1 | ts > "$OUT/hpa-watch.txt" &
W1=$!
kubectl get pods -n "$NS" -o wide -w 2>&1 | ts > "$OUT/pods-watch.txt" &
W2=$!
# Structured sample every 5s (the -w logs above are for humans; checks use this file).
( while :; do
    printf '%s %s\n' "$(date +%T)" \
      "$(kubectl get hpa quote-api -n "$NS" -o jsonpath='current={.status.currentReplicas} desired={.status.desiredReplicas} cpu={.status.currentMetrics[0].resource.current.averageUtilization}%')"
    sleep 5
  done ) > "$OUT/hpa-samples.txt" 2>&1 &
W3=$!
trap 'kill $W1 $W2 $W3 2>/dev/null || true' EXIT

set +e
PROFILE=scale k6 run --quiet /workspace/loadtest/quote.js 2>&1 | tee "$OUT/k6-scale.txt"
K6_RC=${PIPESTATUS[0]}
set -e

MAX_REPLICAS=$(sed -n 's/.*current=\([0-9]*\).*/\1/p' "$OUT/hpa-samples.txt" | sort -n | tail -1)
kill $W1 $W2 $W3 2>/dev/null || true

log "scale-out events (this run only; events from earlier runs are kept for an hour)"
kubectl get events -n "$NS" --sort-by=.lastTimestamp \
  --field-selector reason=SuccessfulRescale -o custom-columns=TIME:.lastTimestamp,MESSAGE:.message --no-headers \
  | awk -v s="$RUN_START" 'BEGIN {print "TIME                   MESSAGE"} $1 >= s' \
  | tee "$OUT/hpa-events.txt"

log "placement at peak (must be spot-preferred, >=1 on-demand, never GPU)"
# The HPA keeps the peak replica count for its 5-minute scale-down window, so the live
# pods right after k6 finishes are the scaled-out set.
{
  printf '%-34s %-9s %s\n' POD NODE CAPACITY
  kubectl get pods -n "$NS" -l app.kubernetes.io/name=quote-api \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | while read -r pod node; do
    printf '%-34s %-9s %s\n' "$pod" "$node" "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.acme\.io/capacity}{.metadata.labels.acme\.io/node-type}')"
  done
} | tee "$OUT/placement.txt"

echo ""
echo "max replicas seen by the HPA watch: ${MAX_REPLICAS:-unknown}"
[ "${MAX_REPLICAS:-0}" -gt 3 ] || die "HPA did not scale beyond 3 replicas"
grep -q ' gpu$' "$OUT/placement.txt" && die "a quote-api pod ran on the GPU node"
grep -q ' on-demand$' "$OUT/placement.txt" || die "no quote-api pod on the on-demand node"
[ "$K6_RC" -eq 0 ] || die "k6 thresholds failed (exit $K6_RC); see $OUT/k6-scale.txt"
echo "PASS: scaled to $MAX_REPLICAS replicas, thresholds met, placement respected"
echo "Grafana: http://grafana.localhost:8080/d/quote-api  Prometheus: http://prometheus.localhost:8080"
