:- module(worker_cleanup, [
    tidy_up_all/1,
    worker_error/3,
    with_worker_scope/2,
    spawn_worker/3,
    close_worker_scope/1,
    release_worker_scope/1,
    release_worker/2
]).

/** <module> Cleanup for generic worker actors

Shared, race-free cleanup for actor-based predicate generics.  Waiting for a
private cleanup monitor before draining establishes a mailbox ordering
barrier: result and monitor messages sent before worker termination can no
longer arrive after the zero-time drain. The shared worker_error/3 helper
preserves exception terms and classifies other unexplained worker exits.
*/

:- use_module(library(apply)).
:- use_module(library(lists), [reverse/2, selectchk/3]).
:- use_module(actors, [
    spawn/3,
    actor_terminating/0,
    monitor/2,
    demonitor/2,
    exit/2,
    receive/1,
    receive/2
]).


:- meta_predicate with_worker_scope(-, 0), spawn_worker(+, 0, -).

%!  with_worker_scope(-Scope, :Goal) is nondet.
%
%   Own every successfully started worker until explicit cleanup or release.
%   The mutable record survives failure and exception unwinding during startup.
with_worker_scope(Scope, Goal) :-
    % Handle exceptions before unwinding this scope, so signal-triggered
    % cleanup completes before the original exception is propagated. The
    % finalizer covers failure and cuts and is harmless after early cleanup.
    setup_call_cleanup(Scope = workers([]),
        catch(Goal, Error, (close_worker_scope(Scope), throw(Error))),
        close_worker_scope(Scope)).

%!  spawn_worker(+Scope, :Goal, -Pid) is det.
%
%   Protect one creation and its ownership record together. The surrounding
%   startup loop and result wait remain interruptible.
spawn_worker(Scope, Goal, Pid) :-
    setup_call_cleanup(
        (spawn(Goal, Pid, [monitor(true)]),
         arg(1, Scope, Pids), nb_setarg(1, Scope, [Pid|Pids])),
        true, true).

%!  close_worker_scope(+Scope) is det.
%
%   Clear ownership only after termination barriers and drains complete.
%   If early cleanup is interrupted, the enclosing handler/finalizer retries
%   it using the still-owned pids; cleanup itself remains interruptible.
close_worker_scope(Scope) :-
    arg(1, Scope, Reversed), reverse(Reversed, Pids),
    (actor_terminating -> maplist(stop_worker_on_exit, Pids)
    ; tidy_up_all(Pids)),
    release_worker_scope(Scope).

% A committed actor exit must not wait for messages to its dying mailbox.
% Retain the normal containment path; request stops and withdraw our monitors.
stop_worker_on_exit(Pid) :- demonitor(Pid), exit(Pid, kill).

%!  release_worker(+Scope, +Pid) is det.
%
%   A consumed termination notice discharges this worker's ownership. Do not
%   install fresh cleanup monitors on workers whose outcome is already settled.
release_worker(Scope, Pid) :-
    arg(1, Scope, Pids0), selectchk(Pid, Pids0, Pids),
    nb_setarg(1, Scope, Pids).

%!  release_worker_scope(+Scope) is det.
%
%   Used after parallel/1 has collected every result and termination notice.
release_worker_scope(Scope) :- nb_setarg(1, Scope, []).


%!  tidy_up_all(+Pids) is det.

tidy_up_all(Pids) :-
    maplist(tidy_up, Pids).


tidy_up(Pid) :-
    demonitor(Pid, [flush]),
    monitor(Pid, CleanupRef),
    exit(Pid, kill),
    receive({
        down(Pid, CleanupRef, _) -> true
    }),
    drain_mailbox(Pid).


drain_mailbox(Pid) :-
    receive({
        Pid-_ ->
            drain_mailbox(Pid) ;
        down(Pid, _, _) ->
            drain_mailbox(Pid)
    }, [timeout(0)]).


%!  worker_error(+Pid, +Reason, -Error) is det.
%
%   Preserve a worker exception; report other unexplained exits explicitly.
worker_error(Pid, Reason, Error) :-
    (   nonvar(Reason), Reason = exception(E)
    ->  Error = E
    ;   Error = worker_exit(Pid, Reason)
    ).
