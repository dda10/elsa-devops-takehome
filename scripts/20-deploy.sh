#!/bin/sh
# 20 — Install Argo CD and deploy quote-api through an Argo CD Application that
# syncs this repo's Helm chart. No manual `helm install` of the app.
# Requires: the commit is pushed to GitHub, and the GHCR image for HEAD exists and is public.
set -eu
. /scripts/lib/common.sh

ARGOCD_CHART_VERSION=10.10.5
NS=quote-api

git config --global --add safe.directory /workspace

# Image tag = the commit being deployed, never "latest".
IMAGE_TAG=$(git -C /workspace rev-parse HEAD)
# Argo CD clones over HTTPS, so normalise an SSH origin to https.
REPO_URL=$(git -C /workspace remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##').git
[ -n "$REPO_URL" ] || die "no git origin remote"
# CI pushes ghcr.io/<owner>/<repo> (lowercase), so derive the image path from the same origin.
IMAGE_REPOSITORY=ghcr.io/$(echo "$REPO_URL" | sed -e 's#^https://github.com/##' -e 's#\.git$##' | tr '[:upper:]' '[:lower:]')
echo "repo:      $REPO_URL"
echo "image:     $IMAGE_REPOSITORY:$IMAGE_TAG"

log "installing Argo CD $ARGOCD_CHART_VERSION"
# OCI chart: 3s vs ~30s to download the classic repo index.
helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --wait --timeout 10m

log "applying the quote-api Application"
sed -e "s#__REPO_URL__#$REPO_URL#" -e "s#__IMAGE_REPOSITORY__#$IMAGE_REPOSITORY#" -e "s#__IMAGE_TAG__#$IMAGE_TAG#" \
  /workspace/deploy/argocd/application.yaml | kubectl apply -f -

log "waiting for Argo CD to sync and report Healthy"
kubectl -n argocd wait application/quote-api \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
kubectl -n "$NS" rollout status deployment/quote-api --timeout=300s
kubectl -n "$NS" rollout status deployment/quote-api-on-demand --timeout=300s

log "placement (spot-preferred pool on spot, anchor on on-demand, nothing on GPU)"
kubectl -n "$NS" get pods -o wide -L app.kubernetes.io/component

log "in-cluster check through Traefik"
curl -fsS http://server/api/quote
echo
