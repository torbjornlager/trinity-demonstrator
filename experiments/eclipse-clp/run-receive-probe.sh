#!/bin/sh
set -eu

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
runtime_source=${1:-"$HOME/Downloads/eclipse_basic.tgz"}
if [ -d "$runtime_source" ]; then
    runtime_dir=$runtime_source
else
    runtime_dir=$(mktemp -d /tmp/eclipse-actor.XXXXXX)
    trap 'rm -rf "$runtime_dir"' EXIT
    tar -xzf "$runtime_source" -C "$runtime_dir"
fi
runtime_dir=$(cd "$runtime_dir" && pwd -P)

tar -C "$source_dir" -cf - actors.ecl toplevel_actors.ecl receive_probe.ecl \
    web_prolog_library.ecl portable_arithmetic.ecl solution_buffer.ecl \
    chunked_solutions.ecl findnsols_probe.ecl |
    docker run --rm -i --platform linux/arm64 \
        --mount "type=bind,source=$runtime_dir,target=/eclipse,readonly" \
        -e ECLIPSEDIR=/eclipse -e LD_LIBRARY_PATH=/eclipse/lib/aarch64_linux \
        debian:bookworm-slim sh -ec '
            mkdir /tmp/src
            tar -xf - -C /tmp/src
            cd /tmp/src
            exec timeout 30s /eclipse/lib/aarch64_linux/eclipse.exe \
                -D /eclipse -b receive_probe.ecl -e receive_probe:run
        '
