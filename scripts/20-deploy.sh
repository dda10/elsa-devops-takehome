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

log "waiting for Argo CD to sync $IMAGE_TAG and report Healthy"
# A fresh Application can briefly report Healthy before its first sync, so require the
# synced revision to be HEAD as well. The first deploy also pulls the image onto several
# nodes, which can take minutes on a slow link, hence the generous deadline.
i=0
while :; do
  state=$(kubectl -n argocd get application quote-api \
    -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}' 2>/dev/null || true)
  [ "$state" = "Synced Healthy $IMAGE_TAG" ] && break
  i=$((i + 1))
  [ "$i" -le 180 ] || die "Application not Synced+Healthy at $IMAGE_TAG after 30 minutes (state: $state); see: kubectl -n argocd describe application quote-api"
  [ $((i % 6)) -eq 0 ] && echo "  ... $state"
  sleep 10
done
echo "Application is Synced and Healthy"
kubectl -n "$NS" rollout status deployment/quote-api --timeout=900s
kubectl -n "$NS" rollout status deployment/quote-api-on-demand --timeout=900s

log "placement (spot-preferred pool on spot, anchor on on-demand, nothing on GPU)"
kubectl -n "$NS" get pods -o wide -L app.kubernetes.io/component

log "in-cluster check through Traefik"
curl -fsS http://server/api/quote
echo
