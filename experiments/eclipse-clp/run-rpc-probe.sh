#!/bin/sh
set -eu

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
runtime_dir=$(cd "${1:?Usage: run-rpc-probe.sh RUNTIME_DIR [SWI_NODE_URI]}" && pwd -P)
node_uri=${2:-http://host.docker.internal:8091}

tar -C "$source_dir" -cf - stateless_rpc.ecl probe_eclipse_rpc.ecl |
    docker run --rm -i --platform linux/arm64 \
        --mount "type=bind,source=$runtime_dir,target=/eclipse,readonly" \
        -e ECLIPSEDIR=/eclipse -e LD_LIBRARY_PATH=/eclipse/lib/aarch64_linux \
        -e "RPC_PROBE_NODE=$node_uri" debian:bookworm-slim sh -ec '
            mkdir /tmp/src
            tar -xf - -C /tmp/src
            cd /tmp/src
            exec timeout 30s /eclipse/lib/aarch64_linux/eclipse.exe \
                -D /eclipse -b probe_eclipse_rpc.ecl \
                -e "getenv(\"RPC_PROBE_NODE\", Node), probe_eclipse_rpc:run(Node)"
        '
