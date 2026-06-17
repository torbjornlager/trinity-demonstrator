:- module(parallel, [
       parallel/1
   ]).

/** <module> Parallel Conjunction Behaviour (layer 2)

Runs a list of goals concurrently — one monitored actor per goal — and
succeeds once all of them have succeeded. It fails fast: as soon as any
goal fails, the remaining actors are torn down and `parallel/1` fails.
Built directly on the layer-0 actor primitives.

@see server_actor.pl, supervisor_actor.pl and statechart_actor.pl for
     the other reusable actor behaviours.
*/

:- use_module(actors).

:- meta_predicate parallel(+).


parallel(Goals) :-
    maplist(par_solve, Goals, Pids),
    maplist(par_yield(Pids), Pids, Goals).


par_solve(Goal, Pid) :-
    self(Self),
    spawn((call(Goal), Self ! Pid-Goal), Pid, [
        monitor(true)
    ]).

par_yield(Pids, Pid, Goal) :-
    receive({
        Pid-Goal ->
            receive({
                down(_, Pid, true) ->
                    true
            }) ;
        down(_, _, false) ->
            tidy_up_all(Pids),
            !, fail ;
        down(_, _, exception(E)) ->
            tidy_up_all(Pids),
            throw(E)
    }).



tidy_up_all(Pids) :-
    maplist(tidy_up, Pids).

tidy_up(Pid) :-
    demonitor(Pid),
    exit(Pid, kill),
    drain_mailbox(Pid).

drain_mailbox(Pid) :-
    receive({
        Pid-_ ->
            drain_mailbox(Pid) ;
        down(_, Pid, _) ->
            drain_mailbox(Pid)
    }, [timeout(0)]).
