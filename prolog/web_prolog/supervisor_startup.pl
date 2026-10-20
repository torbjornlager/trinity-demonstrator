:- module(supervisor_startup,
          [with_startup_scope/1, start_child/4, remember_monitor/2,
           stop_children/1, cleanup_children/1]).

/** <module> Provisional children during supervisor startup

The journal owns only the current startup, dynamic-addition or replacement attempt.
Copies of specifications are for rollback; live state and variable sharing are
not replaced by journal copies. Successful attempts release their journal.
*/
:- use_module(actors).
:- use_module(library(gensym)).
:- meta_predicate with_startup_scope(0).
:- multifile actors:hook_admit_spawn/3.

% Runs in the creating thread before activation, so even a spawn which throws
% after creating its thread remains in this attempt's journal.
actors:hook_admit_spawn(LocalPid, _, _) :-
    nb_current('$sup_starting_child', Key-Spec),
    actors:canonical_pid(LocalPid, Pid),
    supervisor_startup:record_child(Key, Pid, Spec).

with_startup_scope(Goal) :-
    gensym('$supervisor_startup_', Key),
    save('$sup_startup_scope', Saved),
    setup_call_cleanup(
        (nb_setval(Key, []), nb_setval('$sup_startup_scope', Key)),
        catch((once(Goal) -> nb_setval(Key, []) ; fail), Error,
              (rollback(Key), throw(Error))),
        finish_scope(Key, Saved)).

save(Name, Saved) :-
    (nb_current(Name, Value) -> Saved=some(Value); Saved=none).
restore(Name, some(Value)) :- nb_setval(Name, Value).
restore(Name, none) :- nb_delete(Name).
finish_scope(Key, Saved) :-
    setup_call_cleanup(true, rollback(Key),
        (nb_delete(Key), restore('$sup_startup_scope', Saved))).

start_child(Spec, Start, Id, Pid) :-
    (   nb_current('$sup_startup_scope', Key)
    ->  save('$sup_starting_child', Saved),
        setup_call_cleanup(nb_setval('$sup_starting_child', Key-Spec),
            setup_call_cleanup(
                (supervisor_actor:do_spawn_child(Start, Id, Pid),
                 remember_created_child(Key, Pid, Spec)),
                true, true),
            restore('$sup_starting_child', Saved))
    ;   supervisor_actor:do_spawn_child(Start, Id, Pid)
    ).

% Local admission records before activation. Acknowledged remote creation has
% no local admission hook, so retain its returned pid before releasing the
% signal-protected creation handoff too. Unknown remote outcomes stay separate.
remember_created_child(Key, Pid, Spec) :-
    nb_getval(Key, Children),
    (memberchk(owned(Pid, _, _), Children) -> true; record_child(Key, Pid, Spec)).

record_child(Key, Pid, Spec) :-
    nb_getval(Key, Children),
    nb_setval(Key, [owned(Pid, Spec, none)|Children]).
remember_monitor(Pid, Ref) :-
    (   nb_current('$sup_startup_scope', Key), nb_current(Key, Children),
        selectchk(owned(Pid, Spec, none), Children, Rest)
    ->  nb_setval(Key, [owned(Pid, Spec, some(Ref))|Rest])
    ;   true
    ).

% Keep the primary startup outcome. A cleanup failure must not prevent trying
% the remaining children. A committed actor exit retains parent-link teardown
% and must not wait for notifications sent to its dying mailbox.
rollback(Key) :-
    nb_getval(Key, Children), rollback_children(Key, Children).
rollback_children(_, []).
rollback_children(Key, [Child|Rest]) :-
    catch((rollback_child(Child) -> true ; true), Error, cleanup_error(Error)),
    nb_setval(Key, Rest),
    rollback_children(Key, Rest).

rollback_child(owned(_, _, Monitor)) :-
    actor_terminating, !,
    remove_monitor(Monitor).
rollback_child(owned(Pid, spec(_, Start, _, Shutdown, _), Monitor)) :-
    remove_monitor(Monitor),
    setup_call_cleanup(monitor(Pid, CleanupRef),
        (self(Self), retractall(actors:link(Self, Pid)),
         catch(shutdown(Pid, Shutdown, Start, CleanupRef), Error,
               (catch(force_stop(Pid, Shutdown, CleanupRef), CleanupError, cleanup_error(CleanupError)), throw(Error)))),
        demonitor(CleanupRef, [flush])).

remove_monitor(none).
remove_monitor(some(Ref)) :- demonitor(Ref, [flush]).

shutdown(Pid, brutal_kill, _, Ref) :- !,
    exit(Pid, kill), wait_down(Pid, Ref).
shutdown(Pid, Policy, Start, Ref) :-
    (   supervisor_actor:request_stop(Pid, Start, StopRef)
    ->  (   Policy == infinity
        ->  wait_down(Pid, Ref)
        ;   receive({down(Pid, Ref, _) -> true}, [timeout(Policy), on_timeout(fail)])
        ->  true
        ;   exit(Pid, shutdown), wait_down(Pid, Ref)
        ),
        supervisor_actor:flush_stop_reply(StopRef)
    ;   exit(Pid, shutdown), wait_down(Pid, Ref)
    ).
wait_down(Pid, Ref) :- receive({down(Pid, Ref, _) -> true}).
force_stop(Pid, Policy, Ref) :-
    (Policy == brutal_kill -> exit(Pid, kill); exit(Pid, shutdown)),
    wait_down(Pid, Ref).

cleanup_error(Error) :- actors:guard_control_exception(Error), !, throw(Error).
cleanup_error(_).

% Successful group restarts retain forward stopping order. Their old pids may
% already be retired when a later replacement fails; fresh private monitors
% let failure cleanup handle both live and retired entries without consuming
% application down messages or waiting on a previously consumed notification.
stop_children([]).
stop_children([ch(_, undefined, _)|Rest]) :- !, stop_children(Rest).
stop_children([ch(_, Pid, Spec)|Rest]) :-
    rollback_child(owned(Pid, Spec, none)), stop_children(Rest).

cleanup_children(Children) :-
    reverse(Children, Reverse), cleanup_children_(Reverse).
cleanup_children_([]).
cleanup_children_([ch(_, Pid, Spec)|Rest]) :-
    (   Pid == undefined
    ->  true
    ;   catch((rollback_child(owned(Pid, Spec, none)) -> true ; true),
              Error, cleanup_error(Error))
    ),
    cleanup_children_(Rest).
