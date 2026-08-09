:- module(parallel, [
       parallel/1
   ]).

:- op(1000, xfy, if).

/** <module> Parallel Conjunction Behaviour (layer 2)

Runs a list of goals concurrently — one monitored actor per goal — and
succeeds once all of them have succeeded. It fails fast: as soon as any
goal fails, the remaining actors are torn down and `parallel/1` fails.
If several workers fail or throw, the first abnormal `down/3` observed by
the caller determines the result.  Thus multiple faults are intentionally
scheduling-dependent rather than selected by goal-list position.
Built directly on the layer-0 actor primitives.

@see server_actor.pl, supervisor_actor.pl and statechart_actor.pl for
     the other reusable actor behaviours.
*/

:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists), [memberchk/2]).
:- use_module(actors, [
    spawn/3,
    self/1,
    send/2,
    receive/1
]).
:- use_module(worker_cleanup, [tidy_up_all/1]).
:- use_module(control_guard, []).

:- multifile isolation:prepare_module/3.

:- meta_predicate parallel(:).


%  Make the adopted ACTOR generic visible in every prepared actor module.
isolation:prepare_module(Module, _GoalModule, _Options) :-
    add_import_module(Module, parallel, start).


parallel(QualifiedGoals) :-
    strip_module(QualifiedGoals, Module, Goals0),
    must_be(list, Goals0),
    maplist(qualify_goal(Module), Goals0, Goals),
    maplist(par_solve, Goals, Pids),
    maplist(par_yield(Pids), Pids, Goals).


qualify_goal(Module, Goal0, Module:Goal) :-
    control_guard:rewrite_goal(Module, Goal0, Goal).


par_solve(Goal, Pid) :-
    self(Self),
    spawn(par_worker(Self, Pid, Goal), Pid, [
        monitor(true)
    ]).


%  Private framework entry point.  The public node sandbox validates Goal
%  through parallel/1's safe_meta declaration before this worker is spawned.
par_worker(Self, Pid, Goal) :-
    call(Goal),
    send(Self, Pid-Goal).

par_yield(Pids, Pid, Goal) :-
    receive({
        Pid-Goal ->
            receive({
                down(Pid, _, true) ->
                    true
            }) ;
        down(FailedPid, _, false)
                if memberchk(FailedPid, Pids) ->
            tidy_up_all(Pids),
            !, fail ;
        down(FailedPid, _, exception(E))
                if memberchk(FailedPid, Pids) ->
            tidy_up_all(Pids),
            throw(E)
    }).
