#!/bin/sh
set -eu
: "${N6_CALLS_PER_MINUTE:=120}"
: "${N6_CALL_BURST:=60}"
: "${N6_CONNECTIONS_PER_CLIENT:=16}"
: "${N6_CONNECTIONS_TOTAL:=32}"
for value in "$N6_CALLS_PER_MINUTE" "$N6_CALL_BURST" "$N6_CONNECTIONS_PER_CLIENT" "$N6_CONNECTIONS_TOTAL"; do
    case "$value" in ''|*[!0-9]*|0|0*) echo "N6 admission limits require positive decimal integers" >&2; exit 2;; esac
done
export N6_CALLS_PER_MINUTE N6_CALL_BURST N6_CONNECTIONS_PER_CLIENT N6_CONNECTIONS_TOTAL
# Substitute only operator knobs; leave nginx's request variables intact.
envsubst '${N6_CALLS_PER_MINUTE} ${N6_CALL_BURST} ${N6_CONNECTIONS_PER_CLIENT} ${N6_CONNECTIONS_TOTAL}' \
    < /etc/nginx/nginx.conf.template > /tmp/nginx.conf
nginx -t -c /tmp/nginx.conf
exec nginx -c /tmp/nginx.conf -g 'daemon off;'
