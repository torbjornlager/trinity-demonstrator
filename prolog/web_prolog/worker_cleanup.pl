:- module(worker_cleanup, [
    tidy_up_all/1,
    worker_error/3
]).

/** <module> Cleanup for generic worker actors

Shared, race-free cleanup for actor-based predicate generics.  Waiting for a
private cleanup monitor before draining establishes a mailbox ordering
barrier: result and monitor messages sent before worker termination can no
longer arrive after the zero-time drain. The shared worker_error/3 helper
preserves exception terms and classifies other unexplained worker exits.
*/

:- use_module(library(apply)).
:- use_module(actors, [
    monitor/2,
    demonitor/2,
    exit/2,
    receive/1,
    receive/2
]).


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
