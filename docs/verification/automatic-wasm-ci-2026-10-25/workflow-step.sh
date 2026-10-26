set -euo pipefail
results="$RUNNER_TEMP/wasm-ci-results"
mkdir -p "$results"
printf 'Commit: %s\n' "$GITHUB_SHA" > "$results/versions.log"
node --version >> "$results/versions.log"
"$SWIPL" --version >> "$results/versions.log"
cat "$results/versions.log"
python3 tools/ci_timeout.py 360 -- bash tools/test.sh WASM 2>&1 | tee "$results/WASM.log"
