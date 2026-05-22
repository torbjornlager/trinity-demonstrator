/*  Failure-path test for the cross-node exit kill route.

    Verifies that when actor:exit/2 is called for a remote pid on an
    unreachable node, the send failure is captured as a structured
    `remote_exit_failed` event via node_log:log_event/1 instead of being
    silently dropped (the orphan-actor scenario described in
    safe_remote_kill_send/4's docstring).
*/

:- use_module('../actor.pl').
:- use_module('../node_log.pl').

:- use_module(library(plunit)).

:- begin_tests(actor_remote_exit_failure).

collect_failure_events(Events) :-
    findall(E,
            ( node_log:node_log_event(_Scope, _Seq, E),
              get_dict(event_type, E, "remote_exit_failed")
            ),
            Events).

test(unreachable_node_emits_remote_exit_failed,
     [setup(node_log:clear_log_scope(global))]) :-
    %  Port 1 on loopback is reliably refused; the inter-node WebSocket
    %  open will throw, exercising the retry+log path.
    catch(actor:exit(fake_pid@'http://127.0.0.1:1/', killed), _, true),
    collect_failure_events(Events),
    Events \== [],
    %  At least one event should be marked terminal (the retry also failed).
    ( member(E, Events), get_dict(terminal, E, true) -> true
    ; throw(no_terminal_event_logged(Events))
    ).

:- end_tests(actor_remote_exit_failure).
