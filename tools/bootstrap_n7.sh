#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$root"

deps=.trinity/deps
native="$deps/swi-prolog-node"
browser="$deps/swi-wasm-node"
conformance="$deps/trinity-conformance"
conformance_revision=15cfacebd4625d891f0ecea9c551edcc70678bd9
dist=.trinity/n7-local/eclipse-dist
archive="$dist/eclipse_basic.tgz"
archive_sha256=7599e154cca23b5601ed133df2f0481c43baf115b8cd6d7757795729d815e0d5

mkdir -p "$deps" "$dist"
scratch="$deps/.n7-bootstrap"
if ! mkdir "$scratch"; then
    printf 'If no N7 bootstrap is running, remove %s and retry.\n' "$scratch" >&2
    exit 1
fi
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

# Publish each checkout only after a successful fetch so setup can be retried.
if [ ! -e "$native" ]; then
    python3 tools/fetch_swi.py --destination "$scratch/swi-prolog-node"
    mv "$scratch/swi-prolog-node" "$native"
fi
if [ ! -e "$browser" ]; then
    python3 tools/fetch_browser.py --destination "$scratch/swi-wasm-node"
    mv "$scratch/swi-wasm-node" "$browser"
fi
if [ ! -e "$conformance" ]; then
    checkout="$scratch/trinity-conformance"
    git init --quiet "$checkout"
    git -C "$checkout" fetch --depth=1 --no-tags \
        https://github.com/torbjornlager/trinity-conformance.git "$conformance_revision"
    git -C "$checkout" checkout --quiet --detach "$conformance_revision"
    mv "$checkout" "$conformance"
fi
checked_revision=$(git -C "$conformance" rev-parse HEAD)
tracked_changes=$(git -C "$conformance" status --porcelain --untracked-files=no)
if [ "$checked_revision" != "$conformance_revision" ] || [ -n "$tracked_changes" ]; then
    printf 'Expected a clean conformance checkout at %s in %s.\n' "$conformance_revision" "$conformance" >&2
    exit 1
fi

download="$archive"
if [ ! -e "$archive" ]; then
    download="$scratch/eclipse_basic.tgz"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --output "$download" \
        https://eclipseclp.org/Distribution/Builds/7.2_13/aarch64_linux/eclipse_basic.tgz
fi
printf '%s  %s\n' "$archive_sha256" "$download" | shasum -a 256 -c
if [ "$download" != "$archive" ]; then
    mv "$download" "$archive"
fi

export WP_NATIVE_STATE="$root/.trinity/native-swi.json"
python3 tools/setup_swi.py --native-root "$native" --browser-root "$browser"
./tools/check_n7.sh
