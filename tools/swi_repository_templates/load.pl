/** <file> load.pl

Convenience loader for interactive exploration.

Usage:

  `swipl load.pl`

Loads the full layered Web Prolog system (library(web_prolog)): actors,
isolation, toplevel query actors, behaviours, distribution, rpc, and
the node server.  Start a node with ?- node(3060).
*/

:- prolog_load_context(directory, ThisDir),
   atom_concat(ThisDir, '/prolog', LibDir),
   assertz(user:file_search_path(library, LibDir)).

:- use_module(library(web_prolog)).
