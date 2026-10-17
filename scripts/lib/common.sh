# Shared helpers for numbered scripts. Sourced, not executed.

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Block until at least $1 nodes are Ready (server + agents).
wait_for_nodes() {
  want=$1
  i=0
  while :; do
    ready=$(kubectl get nodes --no-headers 2>/tmp/kubectl.err | awk '$2 == "Ready"' | wc -l | tr -d ' ')
    [ "$ready" -ge "$want" ] && break
    i=$((i + 1))
    # Progress every 30s, with the real kubectl error if the API is not reachable yet.
    if [ $((i % 6)) -eq 0 ]; then
      echo "  $ready/$want nodes Ready ($(head -c 200 /tmp/kubectl.err 2>/dev/null))"
    fi
    [ "$i" -le 120 ] || die "fewer than $want Ready nodes after 10 minutes; run: docker compose logs server agent-1"
    sleep 5
  done
  echo "  $ready nodes Ready"
}
