# Karpenter GPU inference (Part 5a)

Files: `gpu-ec2nodeclass.yaml` (EC2NodeClass) and `gpu-nodepools.yaml` (two NodePools).
Render discovery tags with `CLUSTER_NAME=<cluster> envsubst < gpu-ec2nodeclass.yaml | kubectl apply -f -`.

**Spot vs on-demand for inference.** Spot GPU capacity is often 60–70% cheaper, which matters
because GPU instances dominate inference cost. The cost of spot is interruption: a reclaim
gives about two minutes of notice, and a long generation can be cut off. So the design
takes spot for capacity, but keeps interruptions bounded: the GPU taint limits the workload,
`terminationGracePeriod` gives in-flight requests time to finish during a drain, and
`WhenEmpty` consolidation means a node is never repacked while it is serving. On-demand is the
fallback (weight 10) for when spot is unavailable. Production inference should also cap the
spot share with a PodDisruptionBudget and set request timeouts below the drain window.
