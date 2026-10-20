:- module(test_worker_ownership_cleanup, []).

:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module('../../../prolog/web_prolog/worker_cleanup.pl', []).
:- use_module(library(plunit)).

:- dynamic retirement_probe/3.
:- multifile actors:hook_stop/1, actors:hook_pid_retired/1.

% Registered after node_glue: pause after the node's pre-retirement work,
% then report completion after its ownership reclamation. Private host queues
% make both boundaries deterministic without consuming any actor messages.
actors:hook_stop(Pid) :-
    test_worker_ownership_cleanup:retirement_probe(Pid, Events, Gate),
    thread_send_message(Events, stopping),
    thread_get_message(Gate, release).
actors:hook_pid_retired(Pid) :-
    test_worker_ownership_cleanup:retirement_probe(Pid, Events, _),
    thread_send_message(Events, retired).

:- meta_predicate with_paused_retirement(1).
with_paused_retirement(Goal) :-
    setup_call_cleanup(
        (message_queue_create(Events), message_queue_create(Gate)),
        with_owner_context(principal{id:"retirement-owner", capabilities:[execute], unknown:false},
          retirement_probe, local,
          setup_call_cleanup(
            start_paused_actor(Events, Gate, Pid),
            (await_retirement(Events), call(Goal, Pid)),
            finish_paused_actor(Events, Gate, Pid))),
        (message_queue_destroy(Gate), message_queue_destroy(Events))).

start_paused_actor(Events, Gate, Pid) :-
    spawn(thread_get_message(Gate, finish), Pid),
    assertz(retirement_probe(Pid, Events, Gate)),
    thread_send_message(Gate, finish).

await_retirement(Events) :-
    (thread_get_message(Events, stopping, [timeout(3)]) -> true;
     throw(missing_retirement_barrier)).

finish_paused_actor(Events, Gate, Pid) :-
    thread_send_message(Gate, release),
    (thread_get_message(Events, retired, [timeout(3)]) -> true;
     throw(missing_retirement_completion)),
    retractall(retirement_probe(Pid, _, _)),
    assertion(\+ actors:resolve_actor_thread(Pid, _)),
    assertion(\+ node_lifetime:actor_owner(Pid, _)),
    assertion(\+ node_lifetime:cpu_sample(Pid, _)),
    assertion(\+ node_lifetime:mailbox_count(Pid, _)),
    % A redundant stop remains harmless after retirement too.
    exit(Pid, kill).

check_retiring_actor(Pid) :-
    assertion(actors:resolve_actor_thread(Pid, _)),
    assertion(node_lifetime:actor_owner(Pid, _)),
    assertion(node_lifetime:cpu_sample(Pid, _)),
    % The same still-resolvable worker remains protected from another owner.
    with_owner_context(principal{id:"retirement-outsider", capabilities:[execute], unknown:false},
        outsider, local, catch(exit(Pid, kill), Error, true)),
    assertion(nonvar(Error)),
    assertion(Error = error(permission_error(exit, actor, Pid), _)),
    % This public stop used to raise the ownership error in this exact window.
    exit(Pid, kill).

:- begin_tests(worker_ownership_cleanup).

test(ownership_survives_until_pid_retirement) :-
    with_paused_retirement(check_retiring_actor).

test(worker_scope_preserves_original_exception) :-
    with_owner_context(principal{id:"scope-owner", capabilities:[execute], unknown:false},
      scope_probe, local,
      (Scope = workers([]),
       catch(worker_cleanup:with_worker_scope(Scope,
          (worker_cleanup:spawn_worker(Scope, true, _), throw(original_worker_scope_error))),
          Error, true),
       assertion(Error == original_worker_scope_error),
       assertion(Scope == workers([])))).

:- end_tests(worker_ownership_cleanup).
