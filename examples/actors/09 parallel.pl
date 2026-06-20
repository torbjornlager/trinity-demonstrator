%%  parallel(+Goals)
%
%   Runs all Goals concurrently and succeeds only if every goal succeeds.
%   Fails or throws immediately if any goal fails or raises an error.
%
%	@param	Goals - list of goals to execute in parallel
%	@author Torbjörn Lager

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
            fail ;
        down(_, _, exception(E)) ->
            tidy_up_all(Pids),
            throw(E)
    }).
    
    
%%  first_solution(+Solution, +Goals)
%
%   Spawns all Goals in parallel and binds Solution to the result of whichever
%   goal succeeds first, killing the remaining actors.
%
%	@param	Solution - unified with the first successful result
%	@param	Goals - list of goals to race in parallel
%	@author Torbjörn Lager

first_solution(Solution, Goals) :-
    maplist(first_solve(Solution), Goals, Pids),
    wait_first(Pids, Solution).

first_solve(Solution, Goal, Pid) :-
    self(Self),
    spawn((call(Goal), Self ! Pid-Solution), Pid, [
        monitor(true)
    ]).

wait_first([], _) :- !, fail.
wait_first(Pids, Solution) :-
    receive({
        _ - Solution ->
            tidy_up_all(Pids) ;
        down(_, Pid, false) ->
            select(Pid, Pids, Rest),
            wait_first(Rest, Solution) ;
        down(_, _, exception(Error)) ->
            tidy_up_all(Pids),
            throw(Error)
    }).


%%  Utility predicate
%

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
    }, [
        timeout(0)
    ]).


/** <examples>

?- time(parallel([(X=a,sleep(1)),(Y=b,sleep(3)),(Z=c,sleep(2))])).
?- time(parallel([(X=a,sleep(1)),(Y=b,fail),(Z=c,sleep(2))])).
?- time(parallel([(X=a,sleep(1)),(Y=b,sleep(a)),(Z=c,sleep(2))])).
    
?- time(first_solution(X, [(sleep(2),X=a),(sleep(1),X=b)])).

*/
