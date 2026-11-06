#!/usr/bin/env bash
# Tiered test runner.  Each tier runs in a FRESH SWI-Prolog process so
# that layer-honesty assertions (`\+ current_module(...)`) are meaningful.
#
# Usage:
#   ./tools/test.sh            # run all tiers
#   ./tools/test.sh T0 T2      # run selected tiers
#   SWIPL=/path/to/swipl ./tools/test.sh
#   TEST_TIER_TIMEOUT_SECONDS=600 ./tools/test.sh T4
set -u
cd "$(dirname "$0")/.."
DEMONSTRATOR_ROOT="$PWD"
WATCHDOG="$DEMONSTRATOR_ROOT/tools/ci_timeout.py"

SWIPL="${SWIPL:-swipl}"
SELECT="$*"
for tier in "$@"; do
    case "$tier" in
        LINT|TEXT|T0|T1|T2|T3|T4|T5|T1_NATIVE|T1_INTEGRATION|T3_NATIVE|T3_INTEGRATION|T4_NATIVE|T4_INTEGRATION|DEMONSTRATOR|DISCOVERY|WASM|SERVICE_TEXT|MODEL|MODEL_SXML|JEV|LINDA) ;;
        *) echo "Unknown test tier: $tier" >&2; exit 2 ;;
    esac
done
FAILED=0
TEST_TIER_TIMEOUT_SECONDS="${TEST_TIER_TIMEOUT_SECONDS:-360}"
if ! python3 -c 'import math,sys; n=float(sys.argv[1]); sys.exit(0 if math.isfinite(n) and n > 0 else 2)' "$TEST_TIER_TIMEOUT_SECONDS"; then
    echo "TEST_TIER_TIMEOUT_SECONDS must be a positive finite number" >&2
    exit 2
fi

# Setup validation is mandatory for native, browser and service tests alike.
# Values are emitted as shell-quoted assignments by our local validation tool.
SETUP=$(python3 tools/setup_swi.py --shell) || exit 2
eval "$SETUP"
export TRINITY_PINNED_SWI_ROOT WP_ASSET_ROOT WP_WASM_SOURCE_DIR SWI_WASM_PACKAGE_ROOT
python3 tools/pinned_swi.py --native-root "$TRINITY_PINNED_SWI_ROOT" \
    --check --check-tests >/dev/null || exit 2
BOOTSTRAP="$DEMONSTRATOR_ROOT/tools/native_test_bootstrap.pl"

# Resolve executable and setup paths before native tiers change directories.
SWIPL_PATH=$(command -v "$SWIPL") || {
    echo "SWI-Prolog executable not found: $SWIPL" >&2
    exit 2
}
case "$SWIPL_PATH" in
    /*) SWIPL="$SWIPL_PATH" ;;
    *) SWIPL="$DEMONSTRATOR_ROOT/$SWIPL_PATH" ;;
esac
case "${WP_NATIVE_STATE:-}" in
    ''|/*) ;;
    *) export WP_NATIVE_STATE="$DEMONSTRATOR_ROOT/$WP_NATIVE_STATE" ;;
esac

# Fail before entering any tiers on runtimes with the protected-wait bug.
python3 tools/ci_timeout.py "$TEST_TIER_TIMEOUT_SECONDS" -- \
    "$SWIPL" -f none -q -s demonstrator_startup.pl \
    -g 'catch(demonstrator_startup:check_runtime,E,(print_message(error,E),halt(2)))' \
    -t halt || exit 2

run_bounded () {
    local name="$1" status
    shift
    python3 "$WATCHDOG" "$TEST_TIER_TIMEOUT_SECONDS" -- "$@"
    status=$?
    if [ "$status" -eq 124 ]; then
        echo "!!! Tier $name timed out after ${TEST_TIER_TIMEOUT_SECONDS}s" >&2
    fi
    return "$status"
}

selected () {
    [ -z "$SELECT" ] && return 0
    case " $SELECT " in
        (*" $1 "*) return 0 ;;
        (*)        return 1 ;;
    esac
}

run_tier () {
    local name="$1" file="$2" goal="$3" directory="${4:-$DEMONSTRATOR_ROOT}"
    selected "$name" || return 0
    if [ -f "$file" ]; then
        echo "=== Tier $name ($file) ==="
        if ! (cd "$directory" && run_bounded "$name" "$SWIPL" -f none -q \
            -s "$BOOTSTRAP" -s "$file" \
            -g "thread_self(TestThread),thread_statistics(TestThread,errors,0),($goal)" -t halt); then
            echo "!!! Tier $name FAILED"
            FAILED=1
        fi
    else
        echo "!!! Tier $name: missing $file"
        FAILED=1
    fi
}

run_native_tier () {
    run_tier "$1" "$TRINITY_PINNED_SWI_ROOT/tests/tiers/$2" "$3" "$TRINITY_PINNED_SWI_ROOT"
}

if selected LINT; then
    echo "=== Tier LINT (layering: imports only point downward) ==="
    if ! run_bounded LINT python3 "$TRINITY_PINNED_SWI_ROOT/tools/generate_dependency_graph.py" --check; then
        echo "!!! Tier LINT FAILED"
        FAILED=1
    fi
fi

run_native_tier TEXT node/portable_text_tests.pl run_tests
run_native_tier T0 t0_actors.pl run_tier
run_native_tier T1 t1_isolation.pl run_tier
run_native_tier T2 t2_toplevel.pl run_tier
run_native_tier T3 t3_behaviours.pl run_tier
# The upstream full T4 also includes two colocated-layout checks. The pinned
# runtime is external here, so run its exhaustive native + asset selections.
if selected T4; then
    # Separate processes preserve both results, including after a timeout.
    run_tier T4 "$TRINITY_PINNED_SWI_ROOT/tests/tiers/t4_node.pl" run_native "$TRINITY_PINNED_SWI_ROOT"
    run_tier T4 "$TRINITY_PINNED_SWI_ROOT/tests/tiers/t4_node.pl" run_integration "$TRINITY_PINNED_SWI_ROOT"
fi
run_native_tier T5 t5_interop.pl run_tier

# Split-layout gates are opt-in; the default tiers above still run every test.
if [ -n "$SELECT" ]; then
    run_native_tier T1_NATIVE t1_isolation.pl run_native
    run_native_tier T1_INTEGRATION t1_isolation.pl run_integration
    run_native_tier T3_NATIVE t3_behaviours.pl run_native
    run_native_tier T3_INTEGRATION t3_behaviours.pl run_integration
    run_native_tier T4_NATIVE t4_node.pl run_native
    run_native_tier T4_INTEGRATION t4_node.pl run_integration
fi

run_tier DEMONSTRATOR "$DEMONSTRATOR_ROOT/tests/demonstrator_integration_tests.pl" demonstrator_integration_tests:run

run_tier DISCOVERY "$DEMONSTRATOR_ROOT/tests/discovery_reliability_tests.pl" discovery_reliability_tests:run
if selected DISCOVERY; then
    echo "=== Tier DISCOVERY (browser query round trips) ==="
    if ! run_bounded DISCOVERY node tools/test-discovery-query.cjs; then
        echo "!!! Tier DISCOVERY query checks FAILED"
        FAILED=1
    fi
fi

wasm_checks () {
    local FAILED=0
    echo "=== Tier WASM (statechart port + browser bridge smoke tests) ==="
    if ! node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("WASM tests require Node.js 22 or newer"); process.exit(2); }'; then
        return 2
    fi
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
    if ! node tests/wasm/terminal_streaming_smoke.cjs; then
        echo "!!! Tier WASM terminal streaming smoke FAILED"
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
    return "$FAILED"
}

if selected WASM; then
    export SWIPL BOOTSTRAP
    export -f wasm_checks
    if ! run_bounded WASM bash -c wasm_checks; then
        echo "!!! Tier WASM FAILED"
        FAILED=1
    fi
fi

run_tier SERVICE_TEXT tests/service_text_tests.pl 'run_tests([service_text,service_text_owner_options])'
run_tier LINDA tests/linda_tests.pl 'run_tests(linda)'
run_tier MODEL tests/model_service_tests.pl run_tests
run_tier MODEL_SXML tests/model_statechart_tests.pl 'run_tests(model_statechart)'
run_tier JEV tests/jev_tests.pl 'run_tests(jev)'

exit $FAILED
