#!/bin/sh
# Runs on the server for every rollout from GitHub Actions. It is the forced command of the
# deploy key in ~deploy/.ssh/authorized_keys, so that key can do nothing else.
# Usage over SSH: ssh deploy@server <service>   where <service> is a compose service or "config".
set -eu

cd "$(dirname "$0")/.."
exec 9>/tmp/training-collector-deploy.lock
flock 9

# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-${1:-}}
target=${1:-}

case "$target" in
    backend|bot|auth-bot|frontend|admin-frontend)
        docker compose pull --quiet "$target"
        docker compose up -d --no-deps --wait --wait-timeout 180 "$target"
        ;;
    config)
        git fetch --quiet origin main
        git reset --quiet --hard origin/main
        docker compose pull --quiet
        docker compose up -d --remove-orphans --wait --wait-timeout 300
        ;;
    *)
        echo "Usage: <backend|bot|auth-bot|frontend|admin-frontend|config>" >&2
        exit 2
        ;;
esac
docker image prune -f > /dev/null
echo "Deployed $target"
