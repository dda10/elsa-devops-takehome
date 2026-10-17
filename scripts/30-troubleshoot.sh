#!/bin/sh
# 30 — Part 3: apply the fixed workloads and run the provided verifier.
# The broken original is kept as troubleshoot/broken-app.yaml for reference.
set -eu

kubectl apply -f /workspace/troubleshoot/fixed-app.yaml
sh /workspace/troubleshoot/verify.sh
