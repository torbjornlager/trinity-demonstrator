#!/bin/sh

# SPDX-License-Identifier: MIT
# Based on trealla-port/Deployment/entrypoint.sh; retain maintenance draining.

set -u

TPL=${TPL:-/opt/trealla/tpl}
START_FILE=/app/Deployment/start_node.pl
OWNER_START_FILE=/app/owner_start/start_n5_linda.pl
GRACE=${WP_DRAIN_GRACE_SECONDS:-10}

case "$GRACE" in
    ''|*[!0-9]*) printf '%s\n' 'WP_DRAIN_GRACE_SECONDS must be a non-negative integer' >&2; exit 2 ;;
esac

child_pid=
draining=0

drain() {
    [ "$draining" -eq 0 ] || return
    draining=1
    printf '%s\n' "Entering maintenance mode; draining for ${GRACE}s."
    "$TPL" -g "use_module('$START_FILE'),deployment_start:request_maintenance,halt" \
        >/dev/null 2>&1 || true
    sleep "$GRACE"
    if [ -n "$child_pid" ]; then
        kill -TERM "$child_pid" 2>/dev/null || true
    fi
}

trap drain TERM INT

mkdir -p /state
"$TPL" -g "use_module('$OWNER_START_FILE'),n5_linda_start:start_node" &
child_pid=$!
wait "$child_pid"
status=$?
trap - TERM INT
exit "$status"
