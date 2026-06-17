:- module(web_prolog, []).

/** <module> Web Prolog for SWI-Prolog — the full composition

Loading library(web_prolog) gives you the complete Web Prolog system,
with syntax and semantics exactly as in the trinity-demonstrator:

  - Erlang-style actors (spawn/send/receive, links, monitors,
    registration, actor I/O),
  - per-actor isolated modules with load_text/1, load_list/1,
    load_uri/1, load_predicates/1, consult_load_list, listing_private,
  - toplevel query actors (the pengine protocol),
  - behaviours: generic servers, supervisors, statechart actors,
    parallel/1,
  - distribution: Id@Node pids, remote spawn/send/monitor/link,
    rpc/2-3, promise/3-4, yield/2-3,
  - the node server: ?- node(Port). serves ISOBASE /call, ISOTOPE
    sessions, and the ACTOR WebSocket, with profiles, sandboxing,
    auth, and limits.

The layers compose through multifile hooks and are independently
loadable — see the per-layer libraries:

  - library(web_prolog/actors): stand-alone actor core, full
    SWI-Prolog available, no sandbox, no further dependencies.
  - library(web_prolog/isolation), library(web_prolog/toplevel_actors),
    the behaviours, library(web_prolog/distribution),
    library(web_prolog/rpc): each usable without the layers above.

The composition spine (the hook that wires isolation into every local
spawn) is loaded here via web_prolog/composition.
*/

:- reexport(web_prolog/actor_api).
:- reexport(web_prolog/toplevel_actors).
:- reexport(web_prolog/server_actor).
:- reexport(web_prolog/supervisor_actor).
:- reexport(web_prolog/statechart_actor).
:- reexport(web_prolog/parallel).
:- reexport(web_prolog/node).
:- use_module(web_prolog/composition, []).
