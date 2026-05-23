/** <file> load.pl

Convenience loader for interactive exploration.

Usage:

  `swipl load.pl`

After loading, all core modules are available in the REPL.
*/

:- prolog_load_context(directory, ThisDir),
   atom_concat(ThisDir, '/src', SrcDir),
   assertz(user:file_search_path(library, SrcDir)).

:- use_module(library(actor)).
:- use_module(library(toplevel_actor)).
:- use_module(library(server_actor)).
:- use_module(library(parallel)).
:- use_module(library(supervisor_actor)).
:- use_module(library(statechart_actor)).
:- use_module(library(node)).
