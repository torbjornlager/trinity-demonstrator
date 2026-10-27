#!/usr/bin/env bash
# Tiered test runner.  Each tier runs in a FRESH SWI-Prolog process so
# that layer-honesty assertions (`\+ current_module(...)`) are meaningful.
#
# Usage:
#   ./tools/test.sh            # run all tiers
#   ./tools/test.sh T0 T2      # run selected tiers
#   SWIPL=/path/to/swipl ./tools/test.sh
set -u
cd "$(dirname "$0")/.."

SWIPL="${SWIPL:-swipl}"
SELECT="$*"
for tier in "$@"; do
    case "$tier" in
        LINT|T0|T1|T2|T3|T4|T5|T1_NATIVE|T1_INTEGRATION|T3_NATIVE|T3_INTEGRATION|T4_NATIVE|T4_INTEGRATION|WASM|SERVICE_TEXT|MODEL|MODEL_SXML|JEV) ;;
        *) echo "Unknown test tier: $tier" >&2; exit 2 ;;
    esac
done
FAILED=0

# Setup validation is mandatory for native, browser and service tests alike.
# Values are emitted as shell-quoted assignments by our local validation tool.
SETUP=$(python3 tools/setup_swi.py --shell) || exit 2
eval "$SETUP"
export TRINITY_PINNED_SWI_ROOT WP_ASSET_ROOT WP_WASM_SOURCE_DIR
BOOTSTRAP=tools/native_test_bootstrap.pl

selected () {
    [ -z "$SELECT" ] && return 0
    case " $SELECT " in
        (*" $1 "*) return 0 ;;
        (*)        return 1 ;;
    esac
}

run_tier () {
    local name="$1" file="$2" goal="$3"
    selected "$name" || return 0
    if [ -f "$file" ]; then
        echo "=== Tier $name ($file) ==="
        if ! "$SWIPL" -f none -q -s "$BOOTSTRAP" -s "$file" -g "$goal" -t halt; then
            echo "!!! Tier $name FAILED"
            FAILED=1
        fi
    else
        echo "!!! Tier $name: missing $file"
        FAILED=1
    fi
}

if selected LINT; then
    echo "=== Tier LINT (layering: imports only point downward) ==="
    if ! python3 "$TRINITY_PINNED_SWI_ROOT/tools/generate_dependency_graph.py" --check; then
        echo "!!! Tier LINT FAILED"
        FAILED=1
    fi
fi

run_tier T0     tests/tiers/t0_actors.pl     run_tier
run_tier T1     tests/tiers/t1_isolation.pl  run_tier
run_tier T2     tests/tiers/t2_toplevel.pl   run_tier
run_tier T3     tests/tiers/t3_behaviours.pl run_tier
run_tier T4     tests/tiers/t4_node.pl       run_tier
run_tier T5     tests/tiers/t5_interop.pl    run_tier

# Split-layout gates are opt-in; the default tiers above still run every test.
if [ -n "$SELECT" ]; then
    run_tier T1_NATIVE tests/tiers/t1_isolation.pl run_native
    run_tier T1_INTEGRATION tests/tiers/t1_isolation.pl run_integration
    run_tier T3_NATIVE tests/tiers/t3_behaviours.pl run_native
    run_tier T3_INTEGRATION tests/tiers/t3_behaviours.pl run_integration
    run_tier T4_NATIVE tests/tiers/t4_node.pl run_native
    run_tier T4_INTEGRATION tests/tiers/t4_node.pl run_integration
fi

run_wasm () {
    selected WASM || return 0

    echo "=== Tier WASM (statechart port + browser bridge smoke tests) ==="
    if ! python3 tools/check_statechart_wasm_equivalence.py; then
        echo "!!! Tier WASM equivalence guard FAILED"
        FAILED=1
    fi
    if ! "$SWIPL" -f none -q -s "$BOOTSTRAP" -s tests/test_statechart_wasm.pl -g test_statechart_wasm -t halt; then
        echo "!!! Tier WASM statechart tests FAILED"
        FAILED=1
    fi
    if ! node tests/wasm/swi_wasm_actor_worker_smoke.js; then
        echo "!!! Tier WASM worker smoke FAILED"
        FAILED=1
    fi
    if ! node tests/wasm/swi_wasm_rpc_bridge_smoke.js; then
        echo "!!! Tier WASM RPC bridge smoke FAILED"
        FAILED=1
    fi
    if ! node tests/wasm/swi_wasm_standalone.js; then
        echo "!!! Tier WASM standalone host FAILED"
        FAILED=1
    fi
    if ! node tests/wasm/swi_wasm_contracts.js; then
        echo "!!! Tier WASM semantic contracts FAILED"
        FAILED=1
    fi
}

run_wasm

run_tier SERVICE_TEXT tests/service_text_tests.pl 'run_tests([service_text,service_text_owner_options])'
run_tier MODEL tests/model_service_tests.pl run_tests
run_tier MODEL_SXML tests/model_statechart_tests.pl 'run_tests(model_statechart)'
run_tier JEV tests/jev_tests.pl 'run_tests(jev)'

exit $FAILED
