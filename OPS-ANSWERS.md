# Part 7 — Ops questions

## 1. EKS 1.33 → 1.35, zero downtime

EKS upgrades one minor version at a time, so run the sequence twice: 1.33 → 1.34 → 1.35.

**Order**
1. **Preflight.** Scan for deprecated APIs (`pluto` or `kubent` against the live cluster). Check addon compatibility
   with `aws eks describe-addon-versions`. Audit PodDisruptionBudgets (`kubectl get pdb -A`) so none block drains.
2. **Control plane.** Upgrade 1.33 → 1.34, validate, then 1.35. The control plane stays available during the upgrade.
3. **Addons.** Upgrade vpc-cni first (it owns pod networking), then CoreDNS and kube-proxy, then the EBS/EFS CSI drivers.
   Check DNS and pod-to-pod traffic after each.
4. **Nodes.** Roll nodes rather than upgrading in place. Managed node groups: rolling update with `maxUnavailable`.
   Karpenter: bump the AMI alias so nodes drift and get replaced under their disruption budgets. On-demand pool first, then spot.
5. **Verify.** Synthetic check through the ingress, error rate, and HPA behaviour.

**Top 3 risks**
- **vpc-cni or CoreDNS regression** breaks networking cluster-wide. Mitigation: upgrade addons in staging first, with the same config.
- **PDBs or single-replica workloads** stall a drain, or a forced drain causes an outage. Mitigation: audit before starting.
- **Deprecated APIs in manifests or charts** fail to reconcile after the control plane moves. Mitigation: the preflight scan, and a
  staging cluster on 1.35 running the same GitOps state.

## 2. Alert storms from spot reclaims, without missing real failures

Separate *expected* node loss from *unexpected* loss, and route each differently.

- **Use the reason signal.** A spot reclaim sends a two-minute interruption notice. Karpenter's interruption queue
  puts the `karpenter.sh/disrupted` taint on the node. Inhibit `KubeNodeUnreachable` for nodes with that signal in the last ~5 minutes.
- **Page on impact, not on nodes.** Page on "replicas below minimum" or "pods not Ready for 10 min" per workload.
  A single unreachable node is a ticket unless a workload is affected.
- **Use `for:` durations.** Warn after 2–3 minutes on spot pools and 5 minutes on on-demand.
- **Catch unexpected loss directly.** Alert when ready nodes in a pool fall below the desired floor (`kube_node_info` against the
  pool's expected count). This still fires when per-node alerts are suppressed.
- **Test it.** Part 2's reclaim drill should page nobody. Killing an on-demand node by hand should page.

## 3. Mobile LCP 5s behind Cloudflare: is HTML caching working?

Check from the edge inward, with a real request each time.

1. **Edge status.** `curl -sI https://<site>/ -A '<mobile UA>'` and read `cf-cache-status`. `HIT` or `REVALIDATED` is good.
   `DYNAMIC` means the response was not cacheable. Repeat requests that stay `MISS` or `BYPASS` mean the cache is not storing it.
2. **Headers that stop caching.** `Set-Cookie` on the HTML (Cloudflare does not cache those by default). `Cache-Control: private`,
   `no-store`, or `no-cache` from the origin. `Vary: User-Agent`, which splits or disables caching for mobile.
3. **Cache key.** Tracking parameters (`utm_*`, `gclid`) make a new cache entry per URL. Ignore them in the cache key.
4. **Cache Rules.** Look for a broad bypass expression, or one that matches the mobile hostname. Compare with the Terraform in the repo.
5. **Origin.** Request the origin directly and measure TTFB. If the origin is slow even when the edge caches, the bottleneck is the origin.
6. **Lab vs field.** Compare the Chrome UX report with the Lighthouse run, and find the LCP element. If the HTML is cached and the LCP
   element is an unoptimised hero image, caching is not the problem.

Expected result: removing the cookie or the cache-key noise gives `cf-cache-status: HIT` for most mobile requests. Verify with the header,
not the score.

## 4. Application secrets on EKS

**A. External Secrets Operator (ESO) + AWS Secrets Manager.** Secrets live in Secrets Manager. ESO syncs them to Kubernetes Secrets
using EKS Pod Identity. Nothing sensitive is in git. Rotation happens once, in Secrets Manager.

**B. Sealed Secrets or SOPS in git.** Secrets are encrypted in the repo. The cluster holds the key (Sealed Secrets) or KMS decrypts (SOPS).
No external service, and works offline once synced.

| | ESO + Secrets Manager | Sealed Secrets / SOPS |
|---|---|---|
| Source of truth | AWS, one place for all clusters | Git, encrypted |
| Rotation | Change once, every cluster syncs | Re-encrypt and commit per cluster |
| Audit | CloudTrail on every read | Git history (who changed it, not who read it) |
| Blast radius | IAM scoped per namespace or path | Anyone with repo write and key access |

**Pick: ESO + Secrets Manager.** Multiple production clusters need one place to rotate, one read audit trail, and per-cluster IAM
boundaries. Sealed Secrets would mean managing a key in every cluster and re-encrypting for every rotation. Also enable KMS envelope encryption
for Secrets at rest, and scope ESO's IAM role per namespace rather than letting it read everything.
