#!/bin/sh
set -eu
: "${N5_CONNECTIONS_PER_CLIENT:=16}"
: "${N5_CONNECTIONS_TOTAL:=32}"
for value in "$N5_CONNECTIONS_PER_CLIENT" "$N5_CONNECTIONS_TOTAL"; do
    case "$value" in ''|*[!0-9]*|0|0*) echo "N5 admission limits require positive decimal integers" >&2; exit 2;; esac
done
export N5_CONNECTIONS_PER_CLIENT N5_CONNECTIONS_TOTAL
envsubst '${N5_CONNECTIONS_PER_CLIENT} ${N5_CONNECTIONS_TOTAL}' \
    < /etc/nginx/nginx.conf.template > /tmp/nginx.conf
nginx -t -c /tmp/nginx.conf
exec nginx -c /tmp/nginx.conf -g 'daemon off;'
