:- module(wp_composition, []).

/** <module> The composition spine (plan §2.3)

The single hook_start_body chain: every local spawn prepares a private
module via isolation, with the initialized/start_error handshake
preserved.  Loaded by the umbrella (library(web_prolog)) and by
node_glue, so exactly one clause exists no matter which entry point
composed the system.

Tier files T1–T3 define their own equivalent clause instead of loading
this one: below the umbrella, the tier file *is* the composition layer.
*/

:- use_module(actors, []).
:- use_module(isolation, []).

:- multifile actors:hook_start_body/6.
%  Forward the whole contract — including the handshake closures the
%  core constructed — to isolation.  No knowledge of the protocol
%  lives here; the signatures match argument for argument.
actors:hook_start_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
    isolation:spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner).
