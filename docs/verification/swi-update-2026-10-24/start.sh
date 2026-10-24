#!/bin/sh
set -eu
cd /Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator
runtime=${TRINITY_SWI_RUNTIME:-/Users/torbjorn.lager/.local/share/trinity-runtimes/swi-current}
unset SWI_HOME_DIR SWIPL_HOME_DIR
exec "$runtime/bin/swipl" -f none -q -s /Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/start_local_node.pl -- n3
