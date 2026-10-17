# AI usage disclosure

## What I used, and how much

I used **Claude Code** (Anthropic's agentic coding tool, in the Claude desktop app) as my main tool for this assignment, and it wrote
most of the code and documentation in this repo: the service, Dockerfile, Helm chart, scripts, compose harness, Terraform,
Karpenter manifests, CI workflow, k6 script, dashboard and the written answers. It also ran the commands against the local cluster
(builds, `kubectl`/`helm`, the scripts, k6, Prometheus queries). I want to be upfront about that rather than
describe it as just autocomplete.

Its documentation lookups (Karpenter and Cloudflare provider docs through Context7, and Docker Hub, PyPI and the Helm/OCI
registries) were used to check that every pinned version and API field exists.

## What I did

- I set the scope: I read the assignment with it, chose to do **all** of Parts 4, 5 and 6 rather than one, and had it publish the repo.
- I ran the project myself on my machine with the assignment's `docker compose up -d` and `./run-all.sh`, and when it hung at
  "waiting for nodes" I sent the screenshot, which led to the cgroup v2 fix below.
- I reviewed the results it reported, asked clarifying questions (for example whether the assignment needs a real cluster),
  and told it about my unrelated EKS cluster so it stayed on the local k3s cluster only.
- I decided what to publish and under which account.

## Prompts that moved the work forward

1. *"read the file assignment"*, then *"go through the folder"*. This produced a summary of every part and a list of the faults in
   `broken-app.yaml` before any code was written, and set the scope.
2. *"why it stuck at this"* (with a screenshot of `run-all.sh` hanging). It led to the k3s / cgroup v2 diagnosis below.
3. *"I want you to do this entirely"*. Asked for the whole assignment to be finished and **run** on a real cluster, not just written.
   Most of the corrections below came out of that verification pass.

## Where the AI was wrong or suboptimal, and how it was caught

Each of these was found by running the code, not by reading it.

1. **The cluster never came up (cgroup v2).** The first compose file ran k3s in a private cgroup namespace. On a cgroup v2 host the
   kubelet failed with `cannot enter cgroupv2 "/sys/fs/cgroup/kubepods"` and the server exited with code 0. It had also sent k3s logs
   to a file inside the container, so `docker compose logs` was empty and my run just hung. Fix: `cgroup: host`, kubelet
   `cgroups-per-qos=false`, and k3s output on stdout so failures are visible.
2. **The simulated CPU work wasn't CPU work.** `burn_cpu()` looped until 100 ms of *wall-clock* time had passed. In the stress test the
   pods were CPU-throttled about 61% of the time but p95 stayed flat at ~150 ms, which is impossible if every request costs 100 ms of
   CPU. Throttled pods were simply doing less work per request, so every latency and max-RPS number from that run was meaningless.
   Fix: budget by `time.thread_time()`, then re-run Part 6 from scratch.
3. **The on-demand guarantee broke on scale-down.** The first design used one Deployment with a hard topology spread on the capacity
   label. It held at deploy time and through the drill, but after the HPA scaled from 6 back to 3, all three replicas were on spot.
   Spread constraints are only checked when a pod is scheduled, and the ReplicaSet picks which pods to delete by its own ranking.
   Fix: a separate 1-replica on-demand Deployment plus the HPA-scaled spot-preferred pool, so the guarantee is structural
   (explained in `values.yaml`).
4. **The deploy script raced Argo CD.** `20-deploy.sh` waited for the Application to be `Healthy`, then waited for the rollout.
   My earlier tests passed because they used `helm install`, which bypasses Argo. Only a fresh-clone run exposed it: a brand-new
   Application reports `Healthy` before its first sync, so the wait returned immediately and a 300 s rollout timeout expired while the
   image was still pulling. Fix: wait for `Synced`, `Healthy` **and** `revision == HEAD`, with a 30-minute deadline and progress output.
5. **The Part 3 write-up claimed DNS would be blocked by `default-deny`.** On this cluster (k3s / kube-router) it was not: `nslookup`
   worked under default-deny and the smoke test passes without the DNS rule. Egress *is* enforced between pods (checked by adding rules
   one at a time). The document now states what was observed, and the DNS rule stays because Calico, Cilium and the EKS VPC CNI do block it.

Smaller ones: a meaningless k3s flag; `run-all.sh` first placed at the repo root although the assignment runs `./scripts/run-all.sh`;
CI building amd64 only; the chart's image path not matching what CI pushes; slow `helm repo add` index downloads (switched to OCI
charts); a Terraform provider download that looked like a hang (added a cache volume and a note); leaked background sampler loops that
corrupted a results file (killed, file removed); and k6 thresholds first written as guesses, then replaced with numbers from three
measured baseline runs.

## What was verified, and what wasn't

**Verified by running the reviewer's path** (fresh `git clone` of the public repo, `docker compose up -d`, then the numbered scripts;
macOS arm64, OrbStack, 10 CPUs / 8 GB): cluster bootstrap and node prep; Argo CD syncing the chart from GitHub to the exact commit; the
multi-arch image pulled anonymously from GHCR; `curl http://localhost:8080/api/quote` from the host; the reclaim drill (537 requests,
0 failed); Part 3 `verify.sh` → `PASS`; Terraform fmt/init/validate; Part 6 end to end (HPA 3 → 6, thresholds met, placement respected,
alert fired on saturation). The GitHub Actions workflow is green (tests, Semgrep gate, multi-arch build and push).

**Not verified:**
- The Karpenter manifests (no EKS cluster here): checked against the v1 docs and parsed as YAML only. `terminationGracePeriod` on a
  NodePool was not in the docs that were checked, so it is flagged in `karpenter/README.md`.
- `terraform plan` / `apply` against a real Cloudflare zone (validate-only, as the assignment says).
- Linux/amd64 at runtime: everything ran on arm64. CI builds amd64 too, but I did not run it.
- Other people's networks: image pulls and the Terraform provider download were slow on mine (see the README troubleshooting notes).

I'm happy to walk through any file in the live review, and I'll say so if there's a part I can't explain.
