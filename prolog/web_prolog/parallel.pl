:- module(parallel, [
       parallel/1
   ]).

:- op(1000, xfy, if).

/** <module> Parallel Conjunction Behaviour (layer 2)

Runs a list of goals concurrently — one monitored actor per goal — and
succeeds once all of them have succeeded. It fails fast: as soon as any
goal fails, the remaining actors are torn down and `parallel/1` fails.
Workers return only their goal-variable templates, avoiding a copy of each
complete instantiated goal. Compatible bindings shared between goals are
combined; incompatible bindings make the conjunction fail.
If several workers fail or throw, the first abnormal `down/3` observed by
the caller determines the result.  Thus multiple faults are intentionally
scheduling-dependent rather than selected by goal-list position.
An exit without a result is reported as worker_exit(Pid, Reason), unless
it represents ordinary failure or an exception (which retain their outcomes).
A normal down for a later worker waits until its result is collected. Once a
result is accepted, the down only confirms termination, regardless of reason.
Built directly on the layer-0 actor primitives.

@see server_actor.pl, supervisor_actor.pl and statechart_actor.pl for
     the other reusable actor behaviours.
*/

:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists), [memberchk/2]).
:- use_module(actors, [
    self/1,
    send/2,
    receive/1
]).
:- use_module(worker_cleanup, [with_worker_scope/2, spawn_worker/3, close_worker_scope/1,
                             release_worker_scope/1, release_worker/2, worker_error/3]).
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
    maplist(goal_template, Goals, Templates),
    with_worker_scope(Scope,
        (maplist(par_solve(Scope), Goals, Templates, Pids),
         maplist(par_yield(Scope, Pids), Pids, Templates),
         release_worker_scope(Scope))).


qualify_goal(Module, Goal0, Module:Goal) :-
    control_guard:rewrite_goal(Module, Goal0, Goal).


goal_template(Goal, Template) :-
    term_variables(Goal, Template).


par_solve(Scope, Goal, Template, Pid) :-
    self(Self),
    spawn_worker(Scope, par_worker(Self, Pid, Goal, Template), Pid).


%  Private framework entry point.  The public node sandbox validates Goal
%  through parallel/1's safe_meta declaration before this worker is spawned.
par_worker(Self, Pid, Goal, Template) :-
    call(Goal),
    send(Self, Pid-Template).

% Unscoped collector entry for independently owned workers.
par_yield(Pids, Pid, Template) :-
    reverse(Pids, Reversed),
    par_yield(workers(Reversed), Pids, Pid, Template).

par_yield(Scope, Pids, Pid, Template) :-
    receive({
        Pid-Answer ->
            (   Template = Answer
            ->  receive({
                    % The accepted result establishes success. This down
                    % only confirms termination, whatever its reason.
                    down(Pid, _, _) ->
                        release_worker(Scope, Pid)
                })
            ;   close_worker_scope(Scope),
                !,
                fail
            ) ;
        down(FailedPid, _, false)
                if known_worker(FailedPid, Pids) ->
            close_worker_scope(Scope),
            !, fail ;
        down(FailedPid, _, Reason)
                if (known_worker(FailedPid, Pids),
                    (Reason \== true ; FailedPid == Pid)) ->
            % A later worker's normal down may precede the current result.
            % Leave it deferred until that worker's result is collected.
            close_worker_scope(Scope),
            worker_error(FailedPid, Reason, Error),
            throw(Error)
    }).


%   A guard must test a worker pid, not bind it: a message carrying an
%   unbound pid could otherwise be accepted as coming from a real worker.
known_worker(Pid, Pids) :-
    ground(Pid),
    memberchk(Pid, Pids).
