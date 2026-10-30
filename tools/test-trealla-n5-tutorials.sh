#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFORMANCE_ROOT=${TRINITY_CONFORMANCE_ROOT:-$REPO_ROOT/../trinity-conformance}
BASE_COMPOSE=$REPO_ROOT/Deployment/compose.yaml
TREALLA_COMPOSE=$REPO_ROOT/Deployment/compose.trealla-n5.yaml
TEST_COMPOSE=$REPO_ROOT/Deployment/compose.trealla-n5-test.yaml
TEST_PROJECT=trealla_n5_tutorials_$$
TEST_PORT=${TREALLA_N5_TEST_PORT:-13060}

export OAUTH2_PROXY_CLIENT_ID=dummy
export OAUTH2_PROXY_CLIENT_SECRET=dummy
export OAUTH2_PROXY_COOKIE_SECRET=dummy
export OAUTH2_PROXY_GITHUB_USERS=owner
export WP_N5_OWNER=owner@example.test
export WP_TREALLA_N5_ADMIN_TOKEN=0123456789abcdef0123456789abcdef
export TREALLA_N5_TEST_PORT=$TEST_PORT

cleanup() {
    docker compose -p "$TEST_PROJECT" -f "$BASE_COMPOSE" \
        -f "$TREALLA_COMPOSE" -f "$TEST_COMPOSE" --env-file /dev/null \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'docker is required for the Trealla N5 tutorial test' >&2
    exit 2
}
command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' 'python3 is required for the Trealla N5 tutorial test' >&2
    exit 2
}
test -f "$CONFORMANCE_ROOT/runner/run.py" || {
    printf '%s\n' "Trinity conformance checkout not found: $CONFORMANCE_ROOT" >&2
    printf '%s\n' 'Set TRINITY_CONFORMANCE_ROOT to its checkout.' >&2
    exit 2
}

docker compose -p "$TEST_PROJECT" -f "$BASE_COMPOSE" \
    -f "$TREALLA_COMPOSE" -f "$TEST_COMPOSE" --env-file /dev/null \
    up --detach --build --no-deps --wait wp_n3 wp_n5

python3 "$CONFORMANCE_ROOT/runner/run.py" \
    --manifest "$CONFORMANCE_ROOT/cases/demonstrator-tutorials-0.1.json" \
    --ws-url "ws://127.0.0.1:$TEST_PORT/ws" \
    --origin https://n5.elfenbenstornet.se \
    --header 'X-Web-Prolog-User: owner@example.test' \
    --advertised-profile actor \
    --candidate trealla-n5 \
    --timeout 15

python3 "$REPO_ROOT/tools/test_n5_sources.py" \
    --conformance-root "$CONFORMANCE_ROOT" \
    --ws-url "ws://127.0.0.1:$TEST_PORT/ws" \
    --header 'X-Web-Prolog-User: owner@example.test'
