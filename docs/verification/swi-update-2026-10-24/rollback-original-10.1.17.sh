#!/bin/sh
set -eu
cd /Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator
export SWI_HOME_DIR=/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-installed-update-2026-10-23/swipl-10.1.17.framework/Resources/swipl
export WP_ASSET_ROOT=/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator
export WP_WASM_SOURCE_DIR=/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/wasm
exec /Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/bin/swipl -q -s /Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/start_compatible_node.pl -- n3
