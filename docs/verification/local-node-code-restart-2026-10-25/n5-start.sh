#!/bin/sh
set -eu
cd /Users/torbjorn.lager/.local/share/trinity-local-nodes/code-restart-2026-10-25/trealla-active-source
runtime=${TRINITY_TREALLA_RUNTIME:-/Users/torbjorn.lager/Documents/GitHub/trealla-port/.build/trealla-current}
export TPL_LIBRARY_PATH="$runtime/library"
exec "$runtime/tpl" -g 'use_module(actors),use_module(actor_api),use_module(web_prolog),use_module(distribution),consult('"'"'Deployment/shared_db_common.pl'"'"'),consult('"'"'Deployment/shared_db_actor_common.pl'"'"'),web_prolog:web_prolog_node(3062,[bind_address('"'"'127.0.0.1'"'"'),node_url('"'"'http://localhost:3060'"'"'),profile(actor),sandbox(blacklist),auth(open),ws_allowed_origins(['"'"'http://localhost:3053'"'"','"'"'http://localhost:3060'"'"','"'"'http://127.0.0.1:3053'"'"','"'"'http://127.0.0.1:3060'"'"']),tutorial_sections([all]),load_shared_db_file('"'"'Deployment/shared_db_common.pl'"'"'),load_shared_db_file('"'"'Deployment/shared_db_actor_common.pl'"'"')]),thread_get_message(stop)'
