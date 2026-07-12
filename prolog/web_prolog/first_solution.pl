:- module(first_solution, [
    first_solution/2,
    first_solution/3
]).

:- op(1000, xfy, if).

/** <module> First successful actor goal

Runs alternative goals concurrently in monitored worker actors, returns the
first successful solution, and cleans up every remaining worker without
leaving result or monitor messages in the caller's mailbox.
*/

:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists), [memberchk/2, selectchk/3]).
:- use_module(library(option)).
:- use_module(actors, [
    spawn/3,
    self/1,
    send/2,
    receive/1
]).
:- use_module(worker_cleanup, [tidy_up_all/1]).

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
%       Rethrow the first solver exception, or keep waiting. Default stop.

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
    maplist(first_solve(Solution), Goals, Pids),
    wait_first(Pids, Solution, OnFail, OnError).


valid_first_solution_option(on_fail(_)) :- !.
valid_first_solution_option(on_error(_)) :- !.
valid_first_solution_option(Option) :-
    throw(error(domain_error(first_solution_option, Option),
                context(first_solution:first_solution/3,
                        'expected on_fail/1 or on_error/1'))).


qualify_goal(Module, Goal, Module:Goal).


first_solve(Solution, Goal, Pid) :-
    self(Self),
    spawn(first_worker(Self, Pid, Solution, Goal), Pid, [
        monitor(true)
    ]).


%  Private framework entry point.  The public node sandbox validates Goal
%  through first_solution/2-3's safe_meta declarations before spawning it.
first_worker(Self, Pid, Solution, Goal) :-
    call(Goal),
    send(Self, Pid-Solution).


wait_first([], _, _, _) :-
    !,
    fail.
wait_first(Pids, Solution, OnFail, OnError) :-
    receive({
        Winner-Solution
                if memberchk(Winner, Pids) ->
            tidy_up_all(Pids) ;
        down(_, FailedPid, false)
                if memberchk(FailedPid, Pids) ->
            (   OnFail == continue
            ->  selectchk(FailedPid, Pids, Rest),
                wait_first(Rest, Solution, OnFail, OnError)
            ;   tidy_up_all(Pids),
                !,
                fail
            ) ;
        down(_, FailedPid, exception(Error))
                if memberchk(FailedPid, Pids) ->
            (   OnError == continue
            ->  selectchk(FailedPid, Pids, Rest),
                wait_first(Rest, Solution, OnFail, OnError)
            ;   tidy_up_all(Pids),
                throw(Error)
            )
    }).
