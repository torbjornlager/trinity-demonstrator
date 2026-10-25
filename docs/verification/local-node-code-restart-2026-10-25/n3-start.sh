#!/bin/sh
set -eu
cd /Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator
unset SWI_HOME_DIR SWIPL_HOME_DIR WP_EXPERIMENTAL_TEXT WP_NATIVE_MODE WP_NATIVE_STATE
export WP_ASSET_ROOT=/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator
export WP_WASM_SOURCE_DIR=/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/.trinity/browser-prolog-96b4bf2da0848881
exec /Users/torbjorn.lager/.local/share/trinity-runtimes/swi-current/bin/swipl -f none -q -s /Users/torbjorn.lager/.local/share/trinity-local-nodes/code-restart-2026-10-25/n3-active/start_local_node.pl -- n3
