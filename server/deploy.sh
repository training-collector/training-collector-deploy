#!/bin/sh
# Runs on the server for every rollout from GitHub Actions. It is the forced command of the
# deploy key in ~deploy/.ssh/authorized_keys, so that key can do nothing else.
#
#   ssh deploy@server <service>   rolls out one service. The workflow sends its user name and
#                                 its short-lived GITHUB_TOKEN on stdin: the private image is
#                                 pulled with them, and nothing is stored on the server.
#   ssh deploy@server config      applies this repository: compose file, nginx, scripts.
set -eu

cd "$(dirname "$0")/.."
exec 9>/tmp/training-collector-deploy.lock
flock 9

# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-${1:-}}
target=${1:-}
services="backend bot auth-bot frontend admin-frontend"

case " $services " in
    *" $target "*)
        read -r user || true
        read -r token || true
        if [ -z "${user:-}" ] || [ -z "${token:-}" ]; then echo "Send the registry user and token on stdin" >&2; exit 2; fi
        DOCKER_CONFIG=$(mktemp -d)
        export DOCKER_CONFIG
        trap 'rm -rf "$DOCKER_CONFIG"' EXIT
        printf '%s' "$token" | docker login ghcr.io --username "$user" --password-stdin > /dev/null
        docker compose pull --quiet "$target"
        docker logout ghcr.io > /dev/null
        # The stack's own services (database, proxy) are started if they are not running yet.
        docker compose up -d --wait --wait-timeout 180 db proxy certbot backup
        docker compose up -d --no-deps --wait --wait-timeout 180 "$target"
        ;;
    config)
        git fetch --quiet origin main
        git reset --quiet --hard origin/main
        # Services whose image has not been rolled out yet are left for their own workflow.
        ready=""
        for service in $services; do
            image=$(docker compose config --images "$service")
            if docker image inspect "$image" > /dev/null 2>&1; then ready="$ready $service"; fi
        done
        # shellcheck disable=SC2086
        docker compose up -d --remove-orphans --wait --wait-timeout 300 db proxy certbot backup $ready
        ;;
    *)
        echo "Usage: <$(echo "$services" | tr ' ' '|')|config>" >&2
        exit 2
        ;;
esac
docker image prune -f > /dev/null
echo "Deployed $target"
