/** <file> load.pl

Convenience loader for interactive exploration.

Usage:

  `swipl load.pl`

After loading, all core modules are available in the REPL.
*/

:- use_module(actor).
:- use_module(toplevel_actor).
:- use_module(server_actor).
:- use_module(parallel).
:- use_module(supervisor_actor).
:- use_module(statechart_actor).
:- use_module(node).
