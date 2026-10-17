# AI usage disclosure

## Tools and how they were used

- **Claude Code (Anthropic), agentic mode in the Claude desktop app**: the main tool, and it did most of the work.
  I gave it the assignment and the provided package. It wrote nearly every file in this repo, and it ran the commands
  against the local cluster: building images, applying manifests, running the scripts, k6, and the Prometheus queries.
  My role was directing it, setting scope, catching where it got stuck, and reviewing what it produced.
- **Docs lookups done by the agent**: Context7 (Karpenter and Cloudflare Terraform provider docs), Docker Hub / PyPI /
  Helm and OCI registries, to check that every pinned version and API field actually exists.

Because so much was generated, I treated **running it** as the review. Every claim in the docs is backed by output
from a real run on the compose cluster. The few things that couldn't be run locally are listed at the end.

## Prompts that moved the work forward

1. *"read the file assignment … go through the folder"*. It produced a summary of all parts and a list of every
   fault in `broken-app.yaml` before any code was written, which set the scope.
2. *"why it stuck at this"* (with a screenshot of `run-all.sh` hanging at "waiting for nodes"). It led to the
   diagnosis of the k3s/cgroup v2 crash described below.
3. *"I want you to do this entirely"*. Asked for the whole assignment to be finished and verified on the live cluster,
   not just written. Most of the corrections below came from that verification pass.

## Where the AI was wrong, and how it was caught

Each of these was caught by running the code, not by reading it.

1. **The cluster never came up (cgroup v2).** The first compose file started k3s in a private cgroup namespace. On a
   cgroup v2 host the kubelet failed with `cannot enter cgroupv2 "/sys/fs/cgroup/kubepods" … invalid state` and the
   server exited with code 0. It had also sent k3s logs to a file inside the container, so `docker compose logs` showed
   nothing and the script just hung. I noticed it was stuck; the agent then copied the log out of the dead container
   and found the error. Fix: `cgroup: host`, kubelet `cgroups-per-qos=false`, and k3s output on stdout so failures are visible.
2. **Simulated CPU work wasn't CPU work.** `burn_cpu()` looped until 100 ms of *wall-clock* time had passed. In the stress test,
   pods were CPU-throttled 61% of the time but p95 stayed flat at ~150 ms. That's impossible if each request costs 100 ms of CPU:
   throttled pods were just doing less work per request. Every latency and max-RPS number from that run was meaningless.
   Fix: budget by `time.thread_time()`. Checked: 4 concurrent calls now take 400 ms (GIL), and Part 6 was re-run from scratch.
3. **The on-demand guarantee broke on scale-down.** The first design used one Deployment with a hard topology spread on the
   capacity label. It held at deploy time and through the drill, but after an HPA scale-down from 6 to 3, all three survivors were on
   spot. Spread constraints are only checked at scheduling time; the ReplicaSet picks which pods to delete by its own ranking.
   Fix: a separate 1-replica on-demand anchor Deployment plus the HPA-scaled spot-preferred pool. The guarantee is now
   structural instead of statistical (see `values.yaml`).
4. **Deployment started at 1 replica.** With the HPA enabled the chart omitted `replicas`, so each new rollout began at 1 pod
   until the HPA caught up. Fix: render `replicas: minReplicas`, and have Argo CD ignore `/spec/replicas` so it doesn't fight the HPA.
5. **Part 3 doc stated DNS would be blocked by default-deny.** On this cluster (k3s, kube-router) it wasn't. `nslookup` worked
   under default-deny, and the smoke test passes without the DNS rule. Egress *is* enforced pod-to-pod (verified by adding rules
   one at a time). The doc now says what was observed. The DNS rule is kept because Calico, Cilium and the EKS VPC CNI do block it.
6. **The deploy script raced Argo CD.** `20-deploy.sh` waited for the Application to be `Healthy` and then rolled out the
   Deployments. Every local test passed because I had been deploying with `helm install`, which bypasses Argo. Only the reviewer's
   path (fresh clone, real sync from GitHub) exposed it: a brand-new Application reports `Healthy` before its first sync, so the wait
   returned at once, and the following 300 s rollout timeout expired while the image was still pulling at ~2–4 min per node on this
   network. Fix: wait for `Synced`, `Healthy` **and** `revision == HEAD`, with a 30-minute deadline and progress output.
7. **Terraform looked fine on the host but hung in the toolbox.** The 43 MB Cloudflare provider downloads from GitHub's release CDN
   (~58 KB/s here, ~12 min). Added a `tfcache` volume and a message so the first run doesn't look hung.
8. **Leaked background sampler loops** from my own load tests kept writing into `loadtest/results/` after the runs ended
   (found because the files had NUL bytes). I killed them by restarting the toolbox, deleted the corrupted file, and removed the
   per-request warnings from one log. Results cited in `LOADTEST.md` come from the clean runs.
9. **Smaller ones:** a nonsense k3s flag (`--disable=local-storage=false`); `run-all.sh` placed at the repo root although the Golden Rule
   runs `./scripts/run-all.sh`; CI building amd64 only (Apple Silicon reviewers run arm64 nodes); the chart's image path
   not matching what CI pushes; `helm repo add` taking 30–70 s to download repo indexes (switched to OCI charts); awk
   column parsing that would break on `kubectl` output like `cpu: 3%/60%`; k6 thresholds first written as guesses, then replaced
   with numbers from three measured baseline runs.

## What was verified, and what wasn't

Verified by running it here (macOS, arm64, Docker 8 GB): the cluster bootstrap, Part 3 `verify.sh` → `PASS` from a clean namespace,
chart install and placement, the reclaim drill (0 failed requests), Part 6 end to end (HPA 3 → 6, thresholds, placement,
dashboard), app tests, Semgrep (0 findings), Terraform fmt/init/validate, and a server-side dry run of every manifest.

Verified only after publishing: the Argo CD sync from GitHub and the GitHub Actions runs (see the README "Status" section).
Not verifiable locally: the Karpenter manifests (no EKS) beyond schema reading. `terminationGracePeriod` on a NodePool
was not in the docs the agent checked, so it is flagged in `karpenter/README.md`.
