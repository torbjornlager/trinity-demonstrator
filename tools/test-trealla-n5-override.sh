#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE_COMPOSE=$REPO_ROOT/Deployment/compose.yaml
TREALLA_COMPOSE=$REPO_ROOT/Deployment/compose.trealla-n5.yaml
SMOKE_PROJECT=trealla_n5_override_smoke_$$

export OAUTH2_PROXY_CLIENT_ID=dummy
export OAUTH2_PROXY_CLIENT_SECRET=dummy
export OAUTH2_PROXY_COOKIE_SECRET=dummy
export OAUTH2_PROXY_GITHUB_USERS=owner
export WP_N5_OWNER=owner@example.test
export WP_TREALLA_N5_ADMIN_TOKEN=0123456789abcdef0123456789abcdef

cleanup() {
    docker compose -p "$SMOKE_PROJECT" -f "$BASE_COMPOSE" \
        -f "$TREALLA_COMPOSE" --env-file /dev/null \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'docker is required for the Trealla N5 override smoke test' >&2
    exit 2
}

docker compose -p "$SMOKE_PROJECT" -f "$BASE_COMPOSE" \
    -f "$TREALLA_COMPOSE" --env-file /dev/null config --quiet

# The alternate image build runs `caddy validate` against the assembled
# configuration, including the N5 API/UI route split.
docker compose -p "$SMOKE_PROJECT" -f "$BASE_COMPOSE" \
    -f "$TREALLA_COMPOSE" --env-file /dev/null build caddy

docker compose -p "$SMOKE_PROJECT" -f "$BASE_COMPOSE" \
    -f "$TREALLA_COMPOSE" --env-file /dev/null \
    up --detach --build --no-deps --wait wp_n5

SMOKE_NETWORK=${SMOKE_PROJECT}_wp_net
NODE_INFO=$(docker run --rm --network "$SMOKE_NETWORK" caddy:2.8.4-alpine \
    wget --header='X-Web-Prolog-User: owner@example.test' \
      -qO- http://wp_n5:3060/node_info)
printf '%s' "$NODE_INFO" | grep -Fq '"self_url":"https:\/\/n5.elfenbenstornet.se"'
printf '%s' "$NODE_INFO" | grep -Fq '"profile":"actor"'
printf '%s' "$NODE_INFO" | \
    grep -Fq '"tutorial_sections":["local_actor","toplevels","distributed_actor"]'

ANSWER=$(docker run --rm --network "$SMOKE_NETWORK" caddy:2.8.4-alpine \
    wget --header='X-Web-Prolog-User: owner@example.test' \
      -qO- 'http://wp_n5:3060/call?goal=member(X%2C%5Ba%2Cb%5D)&format=json&limit=1')
printf '%s' "$ANSWER" | grep -Fq '"type":"success"'
printf '%s' "$ANSWER" | grep -Fq '"X":"a"'

printf '%s\n' 'Trealla N5 override smoke test: ok'
