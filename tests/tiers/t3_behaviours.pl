/*  Tier T3: layers 0-2b — actors + isolation + toplevel_actors +
    behaviours (server_actor, server, supervisor_actor, parallel,
    statechart_*), with the composition glue.

    The behaviour suites are the demonstrator's own test files, loaded
    from adapted copies in tests/tiers/behaviours/ whose only changes
    are import paths (src/actor.pl -> prolog/web_prolog/actors.pl and
    friends), the fixture-directory resolution (the copies live two
    levels deeper), and one condition/1 gate that named legacy modules.
*/

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/isolation.pl').
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module(library(plunit)).

%  Composition glue (single chain, as the umbrella will define it).
actors:hook_start_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
    isolation:spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner).

%  The behaviour suites (loaded after the glue so spawns made during
%  load-time initialization, if any, already isolate properly).
%  supervisor_actor_tests is a module (empty import list avoids its
%  run_tests/0 clashing with plunit's); the others are user-space
%  files like in the demonstrator.
:- ensure_loaded('behaviours/server_actor_tests.pl').
:- use_module('behaviours/supervisor_actor_tests.pl', []).
:- ensure_loaded('behaviours/parallel_tests.pl').
:- ensure_loaded('behaviours/statechart_actor_tests.pl').

run_tier :-
    layer_honesty,
    run_tests([ server_actor,
                supervisor,
                parallel,
                statechart_profile,
                statechart_profile_runtime,
                statechart_profile_semantics
              ]),
    ensure_mailbox_empty.

layer_honesty :-
    forall(member(M, [ distribution,
                       node,
                       actor,                 % legacy src/actor.pl
                       toplevel_actor,        % legacy src/toplevel_actor.pl
                       node_controller,
                       node_session,
                       remote_protocol,
                       pid_utils,
                       public_goal_guard,
                       websocket
                     ]),
           (   current_module(M)
           ->  throw(layer_violation(module_loaded(M)))
           ;   true
           )).

ensure_mailbox_empty :-
    receive({
        Msg ->
            throw(error(unexpected_message_in_shell(Msg),
                       context(ensure_mailbox_empty/0,
                               'shell mailbox not empty after tests')))
    },[
        timeout(0)
    ]).
