# Part 6 — Load test, scaling proof, observability

All numbers are from runs on the compose cluster: macOS arm64, OrbStack VM with 10 CPUs and 8 GB, 5 k3s nodes **sharing that VM**.
Load was sent by k6 in the toolbox to `http://server/api/quote`, which goes **through Traefik** (the Ingress), not to the Service or pods.
Raw output is in `loadtest/results/`.

Each request does 100 ms of real CPU (measured by thread CPU time). Each pod has `cpu: 200m` request (the HPA's 100%) and `500m` limit.

## Baseline → thresholds

At 2 req/s (no queueing) on 3 + 1 replicas, k6 client-side:

| run | median | p95 | p99 | errors |
|---|---|---|---|---|
| 1 | 177 ms | 214 ms | 378 ms | 0 / 121 |
| 2 | 166 ms | 198 ms | 216 ms | 0 / 121 |
| 3 | 159 ms | 205 ms | 216 ms | 0 / 121 |

The ~165 ms median is the 100 ms of CPU stretched by the 500m limit (CFS throttling) plus ingress and network overhead.
k6 thresholds (`loadtest/quote.js`): **p95 < 400 ms, p99 < 800 ms, errors < 1%**. That is about 1.8× the worst baseline p95 and
about 2× the worst baseline p99. It leaves room for queueing while the HPA reacts, but a saturated pod (seconds) fails it immediately.

## Scale run: HPA past 3, placement respected

`PROFILE=scale`: ramp to 12 req/s over 1 min, hold 5 min. 12 req/s is ~80% of what 3 + 1 pods can serve, but ~170% of
their CPU *request*, so the HPA must scale.

- **Result:** 4,200 requests, **0 failed**, p95 **207 ms**, p99 **296 ms**. All thresholds pass.
- **HPA:** 3 → 5 → 6 replicas in 15 s (`results/hpa-events.txt`, `results/hpa-watch.txt`, `results/hpa-samples.txt`):
  ```
  2026-10-17T14:38:20Z   New size: 5; reason: cpu resource utilization (percentage of request) above target
  2026-10-17T14:38:35Z   New size: 6; reason: cpu resource utilization (percentage of request) above target
  ```
- **Placement at peak** (`results/placement.txt`): all 6 pool replicas on spot (agent-1 ×3, agent-2 ×3), the anchor on on-demand
  (agent-3), **nothing on the GPU node**. The script fails if either rule breaks.
- **Scale-down:** back to 3 at 15:07:24, after the HPA's 5-minute stabilization window and a long quiet period
  (`results/placement-after-scaledown.txt`). Placement after scale-down is covered by the anchor Deployment: the on-demand replica
  is a separate Deployment, so the HPA never touches it. This is the case a single Deployment with a hard spread failed (see README).
- **Dashboard** (`deploy/observability/grafana-dashboard.json`), screenshot taken mid-hold: `loadtest/grafana-under-load.png`.
  It shows the request rate reaching 12 req/s, total replicas 4 → 7, server-side p95 peaking ~340 ms during scale-up and settling ~200 ms,
  and per-pod CPU at the request line.

## Max sustainable RPS

`PROFILE=stress` at 6 + 1 replicas, stepping 15 → 35 req/s. Server-side, from Prometheus (`results/stress-per-step.txt`, `results/k6-stress.txt`):

| req/s | p95 | p99 | app CPU (cores) | CFS throttled |
|---|---|---|---|---|
| 15 | 199 ms | 243 ms | 1.50 | 34% |
| 20 | 195 ms | 199 ms | 2.03 | 39% |
| 25 | 196 ms | 213 ms | 2.53 | 48% |
| 30 | 196 ms | 200 ms | 2.96 | 61% |
| **34** | **0.9–1.9 s** | **1.5–2.0 s** | **3.50** | **85–100%** |

**Max sustainable: ~30 req/s** at 6 + 1 replicas. At 34 req/s, latency rises 5–10× within 30 s. Client-side for the whole
stress run: 11,230 requests, 0 errors, but p95 1.26 s and 20 dropped iterations, all from the final step.

Held longer, overload turns into failures: `PROFILE=saturate` (36 req/s for 7 min, `results/k6-saturate.txt`) gave **41% failed
requests** (10 s timeouts), median 6 s, and 2,444 dropped iterations. There is no spare capacity once the HPA is at max, so queues grow without bound.

## Where the bottleneck is

**The app's CPU limit times the HPA's maxReplicas.** At the knee, the 7 pods used **3.50 cores = 7 × 0.5 limit**, throttled ~100%.
- *Not the nodes:* the cluster used ~3.6 of the VM's 10 cores (`results/stress-bottleneck.txt`). The per-node allocatable of 10 CPUs is
  an artefact of 5 nodes sharing one VM.
- *Not the ingress:* Traefik used **0.016 cores** at the peak.
- Theory check: 7 pods × 0.5 core ÷ 0.1 core per request = 35 req/s ceiling, and ~30 sustainable after per-request overhead. That matches the measurement.

## What I'd scale first in production, and why

1. **HPA `maxReplicas` + node autoscaling (Karpenter, spot first).** The ceiling is the replica cap, not the code or the
   platform. The HPA was pinned at 6 while nodes sat idle. Horizontal scaling is linear here (each pod adds ~5 req/s), and spot
   capacity keeps it cheap. The on-demand anchor keeps the availability floor.
2. **Not vertical first.** One uvicorn process holds the GIL, so a pod can't use more than ~1 core however high the limit.
   Raising the limit from 0.5 to 1 core would roughly double per-pod throughput once; past that it needs more workers per pod,
   which is the same as more pods but with a bigger blast radius.
3. **Keep the HPA target at 60% of request.** It scaled 3 → 6 in 15 s here, with p95 staying under 350 ms. In production I'd add a
   scale-up policy for faster steps and keep the 5-minute scale-down window to avoid flapping.

## Alert rule

`QuoteApiHighLatencyP95` (`deploy/observability/prometheusrule.yaml`): server-side p95 of `/api/quote` **> 400 ms for 5 minutes**,
while traffic is above 1 req/s.

**Why 400 ms / 5 min.** Steady state at any load up to 30 req/s was p95 ≈ 200 ms, so 400 ms is a 2× margin. The worst
non-saturated moment was the HPA scale-up (p95 ≈ 340 ms for about a minute). That stays under 400 ms and ends well before 5 minutes, so it doesn't page.
Real saturation sends p95 to 0.9–5 s within 30 s and doesn't recover without more capacity, so it crosses the line by
2–10× and stays there. That is exactly when a human (or a higher `maxReplicas`) is needed.

**Checked live** (`results/alert-states.txt`, `results/alert-check.txt`):
- *Fires on saturation.* `PROFILE=saturate` (36 req/s, above the 30 req/s max): **pending** at 14:54:30, **firing** at 14:59:30, with p95 at
  the 5 s top bucket. That's five minutes, exactly the `for:` window.
- *Silent during scale-out.* The rule was created after the scale run, so instead I evaluated its expression over that window in Prometheus:
  the 5-minute p95 peaked at **330 ms**, below the 400 ms line, so it would not have gone pending.
