#!/usr/bin/env sh
# Host driver: makes sure the stack is up, then runs every numbered script inside
# the toolbox container in order. Stops at the first failing script.
# All kubectl calls happen inside the toolbox, against the local k3s cluster only;
# nothing here touches the host's ~/.kube/config.
set -eu
cd "$(dirname "$0")/.."

docker compose up -d

for script in scripts/[0-9][0-9]-*.sh; do
  name=$(basename "$script")
  echo ""
  echo "########## $name"
  # Run via the shebang: most scripts are POSIX sh, 60-loadtest.sh needs bash.
  docker compose exec -T toolbox "/scripts/$name"
done

echo ""
echo "########## host check"
curl -fsS http://localhost:8080/api/quote
echo ""
echo "ALL DONE"
