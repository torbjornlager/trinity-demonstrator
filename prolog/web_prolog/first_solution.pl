:- module(first_solution, [
    first_solution/2,
    first_solution/3
]).

:- op(1000, xfy, if).

/** <module> First successful actor goal

Runs alternative goals concurrently in monitored worker actors, returns the
first successful solution, and cleans up every remaining worker without
leaving result or monitor messages in the caller's mailbox. The selected
reply is consumed and workers are cleaned up before output unification;
a conflicting output fails rather than selecting another worker.
*/

:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists), [memberchk/2, selectchk/3]).
:- use_module(library(option)).
:- use_module(actors, [
    self/1,
    send/2,
    receive/1
]).
:- use_module(worker_cleanup, [with_worker_scope/2, spawn_worker/3,
                             close_worker_scope/1, release_worker/2, worker_error/3]).
:- use_module(control_guard, []).

:- multifile isolation:prepare_module/3.

:- meta_predicate
    first_solution(?, :),
    first_solution(?, :, +).


%  Make the adopted ACTOR generic visible in every prepared actor module.
isolation:prepare_module(Module, _GoalModule, _Options) :-
    add_import_module(Module, first_solution, start).


%!  first_solution(-Solution, :Goals) is semidet.
%!  first_solution(-Solution, :Goals, +Options) is semidet.
%
%   Return the first Solution produced by Goals.  Options:
%
%     - on_fail(stop|continue)
%       Stop on the first failed solver, or keep waiting. Default continue.
%     - on_error(stop|continue)
%       Throw the first solver error, or keep waiting. Default stop.
%       Exceptions keep their terms; other unexplained exits, including true,
%       become worker_exit(Pid, Reason).

first_solution(Solution, QualifiedGoals) :-
    first_solution_(Solution, QualifiedGoals, [
        on_fail(continue),
        on_error(stop)
    ]).

first_solution(Solution, QualifiedGoals, Options) :-
    first_solution_(Solution, QualifiedGoals, Options).


first_solution_(Solution, QualifiedGoals, Options) :-
    must_be(list, Options),
    maplist(valid_first_solution_option, Options),
    option(on_fail(OnFail), Options, continue),
    option(on_error(OnError), Options, stop),
    must_be(oneof([stop, continue]), OnFail),
    must_be(oneof([stop, continue]), OnError),
    strip_module(QualifiedGoals, Module, Goals0),
    must_be(list, Goals0),
    maplist(qualify_goal(Module), Goals0, Goals),
    with_worker_scope(Scope,
        (maplist(first_solve(Scope, Solution), Goals, Pids),
         wait_first(Scope, Pids, Solution, OnFail, OnError))).


valid_first_solution_option(on_fail(_)) :- !.
valid_first_solution_option(on_error(_)) :- !.
valid_first_solution_option(Option) :-
    throw(error(domain_error(first_solution_option, Option),
                context(first_solution:first_solution/3,
                        'expected on_fail/1 or on_error/1'))).


qualify_goal(Module, Goal0, Module:Goal) :-
    control_guard:rewrite_goal(Module, Goal0, Goal).


first_solve(Scope, Solution, Goal, Pid) :-
    self(Self),
    spawn_worker(Scope, first_worker(Self, Pid, Solution, Goal), Pid).


%  Private framework entry point.  The public node sandbox validates Goal
%  through first_solution/2-3's safe_meta declarations before spawning it.
first_worker(Self, Pid, Solution, Goal) :-
    call(Goal),
    send(Self, Pid-Solution).


% Unscoped collector entry for independently owned workers.
wait_first(Pids, Solution, OnFail, OnError) :-
    reverse(Pids, Reversed),
    wait_first(workers(Reversed), Pids, Solution, OnFail, OnError).

wait_first(_, [], _, _, _) :-
    !,
    fail.
wait_first(Scope, Pids, Solution, OnFail, OnError) :-
    receive({
        Winner-Reply
                if known_worker(Winner, Pids) ->
            % Selection commits to this worker. Clean up before a conflicting
            % caller output can make unification fail.
            close_worker_scope(Scope),
            Solution = Reply ;
        down(FailedPid, _, false)
                if known_worker(FailedPid, Pids) ->
            (   OnFail == continue
            ->  release_worker(Scope, FailedPid),
                selectchk(FailedPid, Pids, Rest),
                wait_first(Scope, Rest, Solution, OnFail, OnError)
            ;   close_worker_scope(Scope),
                !,
                fail
            ) ;
        down(FailedPid, _, Reason)
                if known_worker(FailedPid, Pids) ->
            (   OnError == continue
            ->  release_worker(Scope, FailedPid),
                selectchk(FailedPid, Pids, Rest),
                wait_first(Scope, Rest, Solution, OnFail, OnError)
            ;   close_worker_scope(Scope),
                worker_error(FailedPid, Reason, Error),
                throw(Error)
            )
    }).


%   A guard must test a worker pid, not bind it: a message carrying an
%   unbound pid could otherwise be accepted as coming from a real worker.
known_worker(Pid, Pids) :-
    ground(Pid),
    memberchk(Pid, Pids).
