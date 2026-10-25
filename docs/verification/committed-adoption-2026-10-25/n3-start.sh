#!/bin/sh
set -eu
python3 /Users/torbjorn.lager/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/verify.py
cd /Users/torbjorn.lager/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/demonstrator
unset SWI_HOME_DIR SWIPL_HOME_DIR WP_NATIVE_MODE WP_NATIVE_STATE
export WP_EXPERIMENTAL_TEXT=portable-text-0.2
export WP_ASSET_ROOT=/Users/torbjorn.lager/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/demonstrator
export WP_WASM_SOURCE_DIR=/Users/torbjorn.lager/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/demonstrator/.trinity/browser-prolog-00751ced7df8e4f5
exec /Users/torbjorn.lager/.local/share/trinity-runtimes/swi-current/bin/swipl -f none -q -s /Users/torbjorn.lager/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/start_local_node.pl -- n3
