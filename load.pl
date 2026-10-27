/** <file> load.pl

Convenience loader for interactive exploration.

Usage:

  `swipl load.pl`

Prepare once with `python3 tools/setup_swi.py --native-root /path/to/swi-prolog-node`.
Only the pinned swi-prolog-node dependency is supported.

Loads the full layered Web Prolog system (library(web_prolog)): actors,
isolation, toplevel query actors, behaviours, distribution, rpc, and
the node server.  Start a node with ?- node(3060).
*/

:- use_module(demonstrator_startup, []).
:- ( catch(demonstrator_startup:load_native(user), Error,
           (print_message(error,Error),halt(2))) -> true ; halt(2) ).
