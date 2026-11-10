#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$root"

image=trinity-eclipse-n7:eclipse-node-dev
local_dir="$root/.trinity/n7-local"
dist="$local_dir/eclipse-dist"
deps="$root/.trinity/deps"
conformance="$deps/trinity-conformance"
runner="$conformance/runner/n7_packaged.py"
swi_load="$deps/swi-prolog-node/load.pl"

for file in "$dist/eclipse_basic.tgz" "$runner" "$conformance/runner/validate_reports.py" "$swi_load"; do
    if [ ! -r "$file" ]; then
        printf 'Missing local N7 prerequisite: %s\n' "$file" >&2
        exit 1
    fi
done

node_bin=${N7_NODE:-}
if [ -z "$node_bin" ]; then
    nvm_node="${NVM_DIR:-${HOME:-}/.nvm}/versions/node/v22.23.4/bin/node"
    if [ -x "$nvm_node" ]; then
        node_bin="$nvm_node"
    else
        node_bin=node
    fi
fi
if ! "$node_bin" -e 'require("node:assert/strict")' >/dev/null 2>&1; then
    printf 'Install Node.js 22 or set N7_NODE to its executable.\n' >&2
    exit 1
fi
if ! command -v swipl >/dev/null 2>&1; then
    printf 'Put swipl on PATH for the local conformance peer.\n' >&2
    exit 1
fi

https_python=${N7_ACTOR_PYTHON:-python3}
set -- --image "$image" --shell
if [ -n "${N7_ACTOR_PYTHON:-}" ]; then
    if ! "$https_python" -c 'import wsproto' >/dev/null 2>&1; then
        printf 'Set N7_ACTOR_PYTHON to a Python executable with the N7 ACTOR dependencies installed.\n' >&2
        exit 1
    fi
    set -- "$@" --advertise-actor --actor-core "$conformance/runner/run.py"
fi

python3 tools/setup_swi.py --validate

printf '\nBuilding local N7 image: %s\n' "$image"
docker buildx build --load --platform linux/arm64 --build-context "eclipse_dist=$dist" \
    -f Deployment/Dockerfile.eclipse-n7 -t "$image" .

reports=$(mktemp -d "$local_dir/conformance.XXXXXX")
if [ -n "${N7_ACTOR_PYTHON:-}" ]; then
    set -- "$@" --actor-report "$reports/actor-https.json"
fi

printf '\nChecking local HTTPS for the compact pilot and full shell\n'
"$https_python" tools/test_n7_https.py "$@"

printf '\nRunning local N7 conformance. Reports: %s\n' "$reports"
python3 "$runner" --demonstrator "$root" --swi-load "$swi_load" \
    --image "$image" --allow-fixture-peers --output "$reports"
if [ -n "${N7_ACTOR_PYTHON:-}" ]; then
    python3 - "$reports/provenance.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
provenance = json.loads(path.read_text())
provenance["runs"].append({"label": "actor-https", "report": "actor-https.json"})
path.write_text(json.dumps(provenance, indent=2) + "\n")
PY
fi
python3 "$conformance/runner/validate_reports.py" "$reports"

printf '\nChecking the demonstrator node catalog\n'
"$node_bin" tools/test-node-catalog.cjs

printf '\nN7 build, HTTPS, conformance, and catalog checks passed. Reports: %s\n' "$reports"
