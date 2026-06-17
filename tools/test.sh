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
FAILED=0

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
        if ! "$SWIPL" -q -s "$file" -g "$goal" -t halt; then
            echo "!!! Tier $name FAILED"
            FAILED=1
        fi
    else
        echo "=== Tier $name: pending ($file does not exist yet) ==="
    fi
}

if selected LINT; then
    echo "=== Tier LINT (layering: imports only point downward) ==="
    if ! python3 tools/generate_dependency_graph.py --check; then
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

exit $FAILED
