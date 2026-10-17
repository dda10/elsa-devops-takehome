# Troubleshooting — Part 3 (`troubleshoot/broken-app.yaml`)

Nine independent faults: seven in the workloads, one in the Service selector/port pair, one in the network path.
Nodes were not touched (the labels and taint from `prepare.sh` stay in place), and `default-deny` was kept.

## Method

The faults are **layered**: some stay hidden until an earlier one is fixed. A Pending pod never pulls its image,
and a pod that can't mount its volume never runs its probes. So I applied `broken-app.yaml` as-is, then fixed one layer
at a time with `kubectl patch` and recorded the next symptom at each step. All output below is from that run on the
compose cluster (k3s v1.31.4, 4 agents labelled by `prepare.sh`). The final fix is `troubleshoot/fixed-app.yaml`, applied
from a clean namespace by `scripts/30-troubleshoot.sh`.

Commands are run in the toolbox (`docker compose exec toolbox sh`):

```bash
kubectl get pods,endpoints -n troubleshoot -o wide
kubectl get events -n troubleshoot --sort-by=.lastTimestamp
kubectl describe pod -n troubleshoot <pod>          # Events section
kubectl get nodes -L acme.io/capacity -L acme.io/node-type
kubectl describe node agent-4 | grep Taints
kubectl get svc web-svc -n troubleshoot -o jsonpath='{.spec.selector} {.spec.ports[0].targetPort}'
kubectl logs -n troubleshoot job/smoke-test
```

---

## Layer 1 — nothing schedules

```
pod/ai-inference-6d8f44c6bf-gxk6p   0/1   Pending
pod/web-748969dcc-fq9rs             0/1   Pending
pod/web-748969dcc-nr9fq             0/1   Pending
endpoints/web-svc   <none>
```

### 1. `web`: memory request can never be satisfied

- **Symptom:** `FailedScheduling … 0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 Insufficient memory.`
- **Diagnose:** `kubectl get events` → `Insufficient memory` on all four schedulable nodes. The template asks for `requests.memory: 16Gi`,
  more than any node in this cluster has.
- **Root cause:** a 16Gi request (and limit) for a static nginx page.
- **Fix:** `requests.memory: 64Mi`, `limits.memory: 128Mi`.

### 2. `ai-inference`: nodeSelector key doesn't exist on any node

- **Symptom:** `FailedScheduling … 1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 node(s) didn't match Pod's node affinity/selector.`
- **Diagnose:** `kubectl get nodes -L acme.io/node-type` → the GPU node carries `acme.io/node-type=gpu`. The pod selects `node-type: gpu`.
  Note the scheduler message is misleading at this layer: it reports the taint for agent-4, even though agent-4 *also* fails the selector.
  The selector has to be fixed first, then the taint.
- **Root cause:** the selector is missing the `acme.io/` prefix that `prepare.sh` uses for every label.
- **Fix:** `nodeSelector: {acme.io/node-type: gpu}`.

### 3. `ai-inference`: GPU taint not tolerated

- **Symptom:** after fix 2, still Pending: `1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 node(s) didn't match Pod's node affinity/selector.`
  This time agent-4 *does* match the selector and is rejected only by the taint.
- **Diagnose:** `kubectl describe node agent-4 | grep Taints` → `nvidia.com/gpu=true:NoSchedule`. The pod spec has no `tolerations`.
- **Root cause:** the taint exists to keep everything except GPU workloads off the node, and this GPU workload never declared it was one.
- **Fix:** toleration `nvidia.com/gpu` `Equal` `"true"` `NoSchedule`. Result: `ai-inference … Running … agent-4`.

## Layer 2 — `web` schedules but can't start

### 4. ConfigMap name mismatch

- **Symptom:** pod stuck `ContainerCreating`:
  `Warning FailedMount (x8 over 75s) kubelet MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found`
- **Diagnose:** `kubectl describe pod` (Events). `kubectl get configmap -n troubleshoot` lists only `web-config`.
- **Root cause:** the volume references `web-conf`; the ConfigMap is `web-config`.
- **Fix:** `configMap.name: web-config`.

### 5. Image tag doesn't exist

- **Symptom:** after fix 4, `ErrImagePull` → `ImagePullBackOff`:
  `Failed to pull image "nginx:1.25.99": … docker.io/library/nginx:1.25.99: not found`
- **Diagnose:** `kubectl describe pod`. Confirmed outside the cluster:
  `https://hub.docker.com/v2/repositories/library/nginx/tags/1.25.99` → 404, `…/tags/1.25.5` → 200.
- **Root cause:** nonexistent tag (1.25.x ended long before .99).
- **Fix:** `image: nginx:1.25.5`, pinned to a real patch version rather than a floating tag.

## Layer 3 — `web` runs but is never Ready, and restarts

### 6. Probes on the wrong port

- **Symptom:** `0/1 Running`, restart count climbing:
  ```
  Readiness probe failed: Get "http://10.42.3.3:8080/": dial tcp 10.42.3.3:8080: connect: connection refused
  Liveness probe failed: Get "http://10.42.3.3:8080/": dial tcp 10.42.3.3:8080: connect: connection refused
  Container nginx failed liveness probe, will be restarted
  ```
- **Diagnose:** `kubectl exec <pod> -- curl -s -o /dev/null -w '%{http_code}' localhost:80` → `200`; `localhost:8080` → connection refused.
  nginx itself is healthy; the probes are aimed at the wrong port.
- **Root cause:** liveness and readiness probes use `8080`; nginx listens on `80`.
- **Fix:** both probes on `port: 80`. `kubectl rollout status deploy/web` → `successfully rolled out`.

## Layer 4 — pods Ready, Service still broken

### 7. Service selector matches nothing

- **Symptom:** pods `1/1 Running` but `endpoints/web-svc <none>`.
- **Diagnose:** `kubectl get svc web-svc -o jsonpath='{.spec.selector}'` → `{"app":"webapp"}`.
  `kubectl get pods -l app=web --show-labels` → `app=web`.
- **Root cause:** selector `app: webapp`, pods labelled `app: web`.
- **Fix:** `selector.app: web`. Endpoints appear: `10.42.3.4:8080,10.42.4.4:8080`.

### 8. Service targetPort wrong

- **Symptom:** the endpoints that appeared after fix 7 are on **:8080**, where nothing listens.
- **Diagnose:** the endpoint list itself shows the port. `kubectl get svc web-svc -o jsonpath='{.spec.ports[0].targetPort}'` → `8080`.
- **Root cause:** `targetPort: 8080`; nginx is on `80`.
- **Fix:** `targetPort: 80`. Endpoints: `10.42.3.4:80,10.42.4.4:80`.

## Layer 5 — the network path

### 9. `default-deny` with no allow rules

- **Symptom:** smoke job fails fast:
  `curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server`
- **Diagnose:** `kubectl get netpol -n troubleshoot` → only `default-deny` (ingress **and** egress, all pods).
  Curl exit code **7** (connect failed), not 6 (resolve failed), so the name resolved. I confirmed that separately with
  `nslookup` from a pod labelled `app=smoke-client`: DNS resolved under default-deny on this cluster.
  I then added the rules one at a time:
  - ingress allow on `web` only → still `curl: (7)`. **Egress is enforced** pod-to-pod.
  - plus egress allow from `smoke-client` to `web:80` → `TROUBLESHOOT-OK`.
- **Root cause:** a correct default-deny with no allow rules for the one legitimate flow (smoke-client → web:80).
- **Fix** (in `fixed-app.yaml`, `default-deny` kept):
  - `allow-smoke-client-ingress-to-web`: `web` accepts TCP 80 from `app=smoke-client` only
  - `allow-smoke-client-to-web`: `smoke-client` may send to `app=web` on TCP 80 only
  - `allow-dns-egress`: all pods → `kube-dns` pods in `kube-system` on UDP/TCP 53

**About the DNS rule.** On k3s's kube-router, DNS to CoreDNS was not blocked by default-deny in my test, so the smoke test
passes without `allow-dns-egress`. I kept it on purpose: Calico, Cilium, and the EKS VPC CNI network-policy agent *do*
block DNS under default-deny egress, so without it the manifest would break as soon as it ran on a production CNI. It
is scoped to the kube-dns pods on port 53, so it stays least-privilege. Lesson: verify a NetworkPolicy on the CNI you
actually run, because enforcement details differ.

---

## Result (clean namespace → `scripts/30-troubleshoot.sh`)

```
[1/7] default-deny NetworkPolicy must still exist (deleting it is not a fix)...
[2/7] Node labels and taints must be untouched (fixing the nodes is not a fix)...
[3/7] Deployment 'web' must be fully rolled out...
deployment "web" successfully rolled out
[4/7] Deployment 'ai-inference' must be fully rolled out...
deployment "ai-inference" successfully rolled out
[5/7] ai-inference pod must be running ON the GPU node...
[6/7] Service must have ready endpoints...
[7/7] In-cluster smoke test through the Service...

PASS
```

```
ai-inference-f7c7694fb-j595z   Running     agent-4   (GPU node)
web-7665c9bd9-kgqvd            Running     agent-1
web-7665c9bd9-vlgzw            Running     agent-3
smoke-test-vzhjx               Completed   agent-2
```

## Notes on the provided files

- `prepare.sh` picks workers by the absence of the `node-role.kubernetes.io/control-plane` label. k3s v1.31 sets that label
  on the server (`ROLES control-plane,master`), so the server is correctly excluded. On a distribution that only sets the legacy
  `master` role, the server would be labelled as the first spot node. That doesn't happen here, but it's worth checking.
- No other provided file was changed.
